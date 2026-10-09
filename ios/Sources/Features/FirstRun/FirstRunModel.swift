import SwiftUI

// First run's state (the flow is `FirstRunFlow`; who gets it and how its writes work are in
// `AppModel+FirstRun.swift`).
//
// Nothing is written until the picked shows have been placed: the picks and their answers live
// here, so Back inside the flow changes an answer rather than undoing a write. The one exception
// is the audience, which is the account's own setting and is saved the moment it is chosen — the
// lists that follow are asked for in its name.

@MainActor
@Observable
final class FirstRunModel {
    enum Step: Int, CaseIterable, Comparable {
        case audience, shows, place, lineup
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where the flow begins: a new account's whole run, or the picker alone (the empty Home's
    /// button, for an account that skipped it or arrived on another device).
    enum Entry { case account, shows }

    /// The picker's lists.
    enum ListKey: Hashable {
        case popular, airing
        case genre(String)
    }

    struct ListState {
        var items: [FranchiseSummary] = []
        var loading = false
        var failed = false
        var loaded = false
    }

    /// One line of the lineup: a picked show and the next thing that happens to it.
    struct LineupRow: Identifiable {
        enum When: Equatable {
            /// Something is out and unwatched.
            case now
            /// The next episode's air time.
            case at(Int64)
            /// Saved for later.
            case later
            /// Watched through.
            case done
        }
        let franchise: Franchise
        let when: When
        let detail: String
        var id: String { franchise.id }
    }

    let entry: Entry
    @ObservationIgnored private unowned let appModel: AppModel
    @ObservationIgnored private var api: APIClient { appModel.api }

    private(set) var step: Step
    /// The way the last change of step went — the transition's direction.
    private(set) var forward = true
    /// The audience card in hand on the first question (saved by Continue). The flow's ground
    /// takes its picture's light.
    var audienceChoice: Audience

    // MARK: The picker

    var list: ListKey = .popular {
        didSet { if list != oldValue { Task { await load(list) } } }
    }
    private(set) var lists: [ListKey: ListState] = [:]
    private(set) var genres: [DiscoverGenre] = []
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var results: [FranchiseSummary] = []
    private(set) var searching = false
    private(set) var searchFailed = false
    /// In the order they were picked.
    private(set) var picks: [FranchiseSummary] = []
    /// The full show behind each pick (its seasons and what has aired), fetched as it is picked:
    /// the next question needs it, and by then it is here.
    private(set) var details: [String: Franchise] = [:]
    /// Continue was tapped while a pick's details were still on their way.
    private(set) var preparing = false

    @ObservationIgnored private var detailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchSeq = 0

    // MARK: Where you are

    /// The picks there is something to ask about, in pick order.
    private(set) var queue: [Franchise] = []
    private(set) var placeIndex = 0
    private(set) var placements: [String: FirstRunPlacement] = [:]
    /// The colour of the show being asked about, for the flow's ground (`FirstRunGround`).
    var ambient: Color?

    // MARK: The lineup

    /// The writes are on their way (or done).
    private(set) var committing = false
    private(set) var committed = false
    /// Go to Home was tapped before the writes had all returned.
    private(set) var leaving = false
    /// A history was imported (`ImportView`): the lineup is the library's, not only the picks'.
    private(set) var imported = false

    init(appModel: AppModel, entry: Entry) {
        self.appModel = appModel
        self.entry = entry
        var first: Step = entry == .account && !appModel.audienceChosen ? .audience : .shows
        #if DEBUG
        // `-firstRunStep audience|shows` (a capture opens on a step; the later ones need picks).
        switch UserDefaults.standard.string(forKey: "firstRunStep") {
        case "audience": first = .audience
        case "shows": first = .shows
        default: break
        }
        #endif
        step = first
        audienceChoice = appModel.audienceChosen ? appModel.audience : appModel.suggestedAudience
    }

    // MARK: - Steps

    /// The steps this run shows, for the bar's segments.
    var steps: [Step] { entry == .account ? Step.allCases : [.shows, .place, .lineup] }

    /// How far along the bar is: whole steps done, plus the share of the questions answered.
    var progress: Double {
        let all = steps
        guard let at = all.firstIndex(of: step) else { return 0 }
        // A step in hand counts for a third of itself (a bar at zero on the first question reads
        // as nothing begun); the questions about each show fill the rest of theirs as they go.
        var done = Double(at) + 0.3
        if step == .place, !queue.isEmpty { done += 0.7 * Double(placeIndex) / Double(queue.count) }
        if step == .lineup { done = Double(all.count) }
        return done / Double(all.count)
    }

    var canGoBack: Bool {
        switch step {
        case .audience, .lineup: false
        case .shows: entry == .account
        case .place: true
        }
    }

    func back() {
        switch step {
        case .place where placeIndex > 0:
            go { placeIndex -= 1 }
        case .place:
            go(to: .shows, forward: false)
        case .shows where entry == .account:
            go(to: .audience, forward: false)
        default:
            break
        }
    }

    private func go(to next: Step, forward: Bool) {
        self.forward = forward
        withAnimation(ThemeMotion.uiSettle) { step = next }
    }

    private func go(_ change: () -> Void) {
        forward = false
        withAnimation(ThemeMotion.uiSettle) { change() }
    }

    // MARK: - What you watch

    /// The first question, answered: saved to the account at once (the lists that follow are the
    /// audience's), and on to the picker.
    func chose(_ audience: Audience) {
        let changed = audience != appModel.audience || !appModel.audienceChosen
        appModel.setAudience(audience, announce: false)
        if changed {
            // Lists fetched for another audience are not this one's.
            lists = [:]
            genres = []
            list = .popular
        }
        go(to: .shows, forward: true)
        Task { await prepareLists() }
    }

    // MARK: - The picker

    private var source: MediaSource? {
        switch appModel.audience {
        case .anime: .anilist
        case .tv: .tmdb
        case .both: nil
        }
    }

    /// The first list and the genre row, when the picker comes up.
    func prepareLists() async {
        async let first: Void = load(.popular)
        async let chips: Void = loadGenres()
        _ = await (first, chips)
    }

    private func loadGenres() async {
        guard genres.isEmpty else { return }
        // A failure leaves the row at Popular and Airing now: the picker works without genres.
        if let res = try? await api.discoverGenres(source: source) {
            genres = Array(res.genres.prefix(12))
        }
    }

    func load(_ key: ListKey, force: Bool = false) async {
        let state = lists[key] ?? ListState()
        guard force || (!state.loaded && !state.loading) else { return }
        lists[key, default: ListState()].loading = true
        lists[key, default: ListState()].failed = false
        let audience = appModel.audience
        do {
            let items: [FranchiseSummary]
            switch key {
            case .popular:
                // The best-known shows; a server that predates the route gives the chart instead.
                if let known = try? await api.starter(limit: 60), !known.isEmpty {
                    items = known
                } else {
                    items = try await api.trending(limit: 60)
                }
            case .airing:
                items = try await api.airingNow(limit: 60)
            case .genre(let genre):
                items = try await api.discoverGenre(key: genre, source: source, cursor: nil, limit: 48).franchises
            }
            // The answer is for the audience it was asked for.
            guard audience == appModel.audience else { return }
            var state = ListState()
            state.items = visible(items)
            state.loaded = true
            lists[key] = state
        } catch {
            guard !error.isCancellation else {
                lists[key, default: ListState()].loading = false
                return
            }
            lists[key, default: ListState()].loading = false
            lists[key, default: ListState()].failed = true
        }
    }

    /// The audience's wall, a poster to draw, and nothing the viewer already owns (the picker
    /// reached from an account with shows offers what is not theirs yet).
    private func visible(_ items: [FranchiseSummary]) -> [FranchiseSummary] {
        var seen = Set<String>()
        return items.filter {
            appModel.audience.allows($0.source) && $0.portraitArt != nil
                && !ownedBeforeRun.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    /// The library as the flow found it (the picks join it as they are placed).
    @ObservationIgnored private lazy var ownedBeforeRun: Set<String> = Set(appModel.library.map(\.id))

    /// What the grid shows: the search's answer while there is a query, else the chosen list.
    var searchingText: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchSeq += 1
        let seq = searchSeq
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            searching = false
            searchFailed = false
            return
        }
        // Busy from the keystroke (Search's own rule): raised only when the request goes out, the
        // 300 ms before it draw "No results" over the grid.
        searching = true
        searchFailed = false
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            do {
                let found: [FranchiseSummary] = try await self.api.search(query: text)
                guard seq == self.searchSeq else { return }
                self.results = self.visible(found)
                self.searching = false
            } catch {
                guard seq == self.searchSeq, !error.isCancellation else { return }
                self.results = []
                self.searching = false
                self.searchFailed = true
            }
        }
    }

    func isPicked(_ id: String) -> Bool { picks.contains { $0.id == id } }

    func toggle(_ item: FranchiseSummary) {
        if let index = picks.firstIndex(where: { $0.id == item.id }) {
            picks.remove(at: index)
            placements[item.id] = nil
            return
        }
        FeedbackCoordinator.fire(.selection)
        picks.append(item)
        fetchDetail(item.id)
    }

    private func fetchDetail(_ id: String) {
        guard details[id] == nil, detailTasks[id] == nil else { return }
        detailTasks[id] = Task { [weak self] in
            guard let self else { return }
            let show = try? await self.api.franchise(id: id, country: AppRegion.current)
            self.detailTasks[id] = nil
            if let show { self.details[id] = show }
        }
    }

    #if DEBUG
    /// `-firstRunPick N` (a capture): the first N of the list on screen, picked.
    func pickFirst(_ n: Int) {
        for item in (lists[list]?.items ?? []).prefix(n) where !isPicked(item.id) { toggle(item) }
    }
    #endif

    /// Continue: on to the questions about the picks — or, with nothing picked, out to the app.
    /// Returns false when the flow is over.
    @discardableResult
    func continueFromShows() async -> Bool {
        guard !picks.isEmpty else { return false }
        // The details of the last few picks may still be on their way: a short wait, then the
        // questions go ahead with what has arrived (a show with none is simply not asked about).
        if picks.contains(where: { details[$0.id] == nil }) {
            preparing = true
            let pending = picks.compactMap { detailTasks[$0.id] }
            let all = Task { for task in pending { await task.value } }
            let limit = Task { try? await Task.sleep(for: .seconds(4)); all.cancel() }
            await all.value
            limit.cancel()
            preparing = false
        }
        let now = appModel.now
        queue = picks.compactMap { details[$0.id] }.filter { Self.asks($0, now: now) }
        placeIndex = 0
        if queue.isEmpty {
            startLineup()
        } else {
            go(to: .place, forward: true)
        }
        return true
    }

    // MARK: - Where you are

    /// A show is asked about when it has something out to have watched.
    static func asks(_ f: Franchise, now: Int64) -> Bool {
        !WatchedBatch(franchise: f, now: now).parts.isEmpty
    }

    var current: Franchise? { queue.indices.contains(placeIndex) ? queue[placeIndex] : nil }

    func answer(_ placement: FirstRunPlacement) {
        guard let show = current else { return }
        placements[show.id] = placement
        if placeIndex + 1 < queue.count {
            forward = true
            withAnimation(ThemeMotion.uiSettle) { placeIndex += 1 }
        } else {
            startLineup()
        }
    }

    /// A history was brought in from the picker: straight to the lineup, with whatever was also
    /// picked by hand added as it would have been.
    func importFinished() {
        imported = true
        startLineup()
    }

    /// Skip: the questions not yet answered are left unasked (those shows are simply added).
    func skipRest() {
        startLineup()
    }

    // MARK: - The lineup

    private func startLineup() {
        go(to: .lineup, forward: true)
        commit()
    }

    /// Every pick, placed: drawn into the library at once, written four at a time.
    private func commit() {
        guard !committing, !committed else { return }
        committing = true
        // The one haptic of the run: the shows are added (the board comes alive on it).
        FeedbackCoordinator.fire(.success)
        let now = appModel.now
        let epoch = appModel.accountEpoch
        // Import has already placed these shows. A default placement from an earlier tap must
        // not turn Completed back into Planned when the viewer proceeds to the lineup.
        let owned = Set(appModel.library.map(\.id))
        let work = picks.filter { !owned.contains($0.id) }.map { pick in (pick, details[pick.id]) }
        // Drawn first, all of them, so the lineup (and Home beneath it) is whole before any
        // call returns.
        var writes: [(Franchise, FirstRunWrite, MutationStamp?)] = []
        var bare: [(FranchiseSummary, MutationStamp?)] = []
        for (pick, show) in work {
            if let show {
                let write = FirstRunWrite(show, placement: placements[show.id], now: now)
                do {
                    let stamp = try appModel.prepareBatchMutation(show, parts: write.parts, status: write.status)
                    appModel.insertPending(write.applied(to: show))
                    writes.append((show, write, stamp))
                } catch {
                    appModel.recordBatchFailure(franchiseId: show.id, title: show.title,
                        parts: write.parts, status: write.status, error: error)
                }
            } else {
                let stamp = MutationStamp.fresh(owner: appModel.accountStorage)
                let status: WatchStatus = pick.isReleasing ? .watching : .planned
                let intent = WriteIntent.subscribe(franchiseId: pick.id, title: pick.title, status: status.rawValue)
                do {
                    if try appModel.stageTrackingMutation(command: Copy.Action.add, title: pick.title, intent: intent, mutation: stamp) {
                        bare.append((pick, stamp))
                    }
                } catch {
                    appModel.fileFailure(command: Copy.Action.add, title: pick.title,
                        reason: Copy.Notice.reason(error), intent: intent, mutation: stamp) { [appModel] in
                            await appModel.placeFirstRunBareShow(pick, mutation: stamp)
                        }
                }
            }
        }
        // Four at a time: a long list of picks is not twenty requests at once.
        var jobs: [@MainActor () async -> Void] = writes.map { show, write, stamp in
            { [appModel] in
                guard epoch == appModel.accountEpoch else { return }
                _ = await appModel.placeFirstRunShow(show, write: write, mutation: stamp)
            }
        }
        // A pick whose details never arrived: followed by the plain add's rule.
        jobs += bare.map { pick, stamp in
            { [appModel] in
                guard epoch == appModel.accountEpoch else { return }
                await appModel.placeFirstRunBareShow(pick, mutation: stamp)
            }
        }
        Task { @MainActor [weak self] in
            var next = 0
            while next < jobs.count, epoch == self?.appModel.accountEpoch {
                let batch = jobs[next..<min(next + 4, jobs.count)].map { job in Task { @MainActor in await job() } }
                for task in batch { await task.value }
                next += 4
            }
            guard let self, epoch == self.appModel.accountEpoch else { return }
            await self.appModel.reload()
            guard epoch == self.appModel.accountEpoch else { return }
            self.committing = false
            self.committed = true
        }
    }

    /// Go to Home: at once when the writes are in; otherwise when they are, or after a short
    /// wait (they carry on, and a failure is filed in Sync status either way).
    func leave() async {
        guard !leaving else { return }
        leaving = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while committing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// The picks as the library now holds them, each with the next thing that happens to it:
    /// what is out first, then what airs soonest, then the rest.
    ///
    /// "Out" is HOME's answer, not a second reading of the parts: the billboard and Up next
    /// (`HomeCompose`) decide what a show's next episode to watch is, so the board and the page it
    /// lifts off cannot disagree. Read from the parts here, a finished Attack on Titan listed a
    /// side-story OVA as something to watch now.
    func lineup(now: Int64) -> [LineupRow] {
        let ids = Set(picks.map(\.id))
        let shows = imported ? appModel.library : appModel.library.filter { ids.contains($0.id) }
        let feed = HomeCompose.feed(appModel)
        var ready: [String: (part: FranchisePart, episode: Int)] = [:]
        for airing in feed.recent {
            ready[airing.entry.franchise.id] = (airing.entry.part, airing.entry.part.progress + 1)
        }
        for item in feed.queue { ready[item.franchise.id] = (item.part, item.episode) }
        if let hero = feed.hero, hero.canMark { ready[hero.franchise.id] = (hero.part, hero.episode) }
        func rank(_ when: LineupRow.When) -> Int64 {
            switch when {
            case .now: return 0
            case .at(let ts): return ts
            case .later: return .max - 1
            case .done: return .max
            }
        }
        return shows.map { Self.row($0, ready: ready[$0.id], now: now) }
            .sorted { a, b in
                let (ra, rb) = (rank(a.when), rank(b.when))
                return ra != rb ? ra < rb : a.franchise.title < b.franchise.title
            }
    }

    /// One show's line. `ready` is the episode Home offers to watch, when it offers one.
    static func row(_ f: Franchise, ready: (part: FranchisePart, episode: Int)?, now: Int64) -> LineupRow {
        let anchor = f.timeAnchor
        if f.effectiveStatus == .planned {
            return LineupRow(franchise: f, when: .later, detail: Copy.Status(.planned))
        }
        if let ready {
            // The season is named only where the show has more than one.
            let label = f.seasonPartsInOrder.count > 1 ? ready.part.canonicalLabel : ""
            return LineupRow(franchise: f, when: .now,
                             detail: Copy.watchContext(part: label, episode: ready.episode))
        }
        // Nothing to watch, with an episode on its way.
        if f.tracksAirings, let at = f.nextAiring(now: now) {
            let part = f.parts.first { $0.upcomingAiring(now: now, anchor: anchor) == at }
            let episode = part?.airings.first { $0.at == at }?.episode ?? part?.nextEpisodeNumber
            return LineupRow(franchise: f, when: .at(at),
                             detail: episode.map(Copy.episode) ?? Copy.Label.airing)
        }
        return LineupRow(franchise: f, when: .done,
                         detail: f.effectiveStatus == .completed ? Copy.Status(.completed) : Copy.Progress.caughtUp)
    }

    /// The show whose next episode an alert would announce: a Watching anime with a timed airing
    /// ahead (TV's dates carry no clock, so there is no moment to announce).
    func alertShow(now: Int64) -> Franchise? {
        let ids = Set(picks.map(\.id))
        return appModel.library
            .filter { (imported || ids.contains($0.id)) && $0.source == .anilist && $0.effectiveStatus == .watching }
            .compactMap { f in f.nextAiring(now: now).map { (f, $0) } }
            .min { $0.1 < $1.1 }?.0
    }
}
