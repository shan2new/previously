import SwiftUI

// Schedule — the next thing to watch, then an agenda (25 Sep 2026).
//
// "We need to Overhaul the Schedule Screen completely for this new awesome UX" (owner). Three
// directions were photographed on the owner's own calendar and the owner chose TONIGHT — then
// "tonight still feels cluttered": 20-pt day banners over one or two rows each, every upcoming line
// in amber, and an empty "Today" heading under a card that already said tonight. What it is now:
//
//   · ONE card for the next thing to watch (`pickHero`, `ScheduleTonightCard`): the newest drop of
//     today's or yesterday's you have not seen ("OUT NOW"), else today's next airing ("TONIGHT AT
//     7:30 PM"), else the next day's first ("SUNDAY AT 4:30 PM") — the app's one temporal ladder.
//     Its row leaves the agenda, so no show is printed twice in a row;
//   · under it the agenda with THE DATE RIDING THE ROW (`ScheduleAgendaRow`, the 7 Sep anatomy): the
//     day printed once, in the first row's date column, amber only on today; the show's face and
//     name; "Episode 14 · 4:30 PM" in grey; the state ladder's slot. No day banners and no rules — a
//     day's break is space. A month is named only where the feed crosses into one;
//   · the past ABOVE today, the feed landing on the card; past the window, LATER — each quiet show's
//     next dated airing.
//
// The calendar is the month grid behind the bar's glyph (`ScheduleMonthGrid`); there is no rail.
// The only write here is the mark on an airing that has aired.
struct ScheduleView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String, _ focus: EpisodeFocus?) -> Void
    var onAddShow: () -> Void = {}
    /// This tab is the one on screen (`RootView`'s selection, once the surface is ready). A VISIT
    /// begins when it turns true — the arrival plays once per visit (`ScheduleLit.swift`).
    var active: Bool = true
    /// The bar's scroll-away state, owned by `MainTabView` (the tab bar rides it).
    var rootChrome = RootChromeState()
    @Environment(LaunchHandoff.self) private var launch: LaunchHandoff?

    // MARK: - State

    @State private var typeFilter: MediaFilter = ScheduleView.debugTypeFilter
    @State private var unwatchedOnly = ScheduleView.debugUnwatchedOnly
    /// A day the reader picked on the grid that has nothing on it. It is drawn as a row that says
    /// "Nothing scheduled" so the pick lands somewhere — every day in the window is a target.
    @State private var pinnedEmptyDay: Int? = nil

    /// `-scheduleFilter anime|tv` and `-scheduleHideWatched 1` (DEBUG): open with a filter already
    /// applied, so the chip row and the filtered feed can be captured without driving the menu.
    private static var debugTypeFilter: MediaFilter {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "scheduleFilter") {
        case "anime": return .anime
        case "tv": return .tv
        default: return .all
        }
        #else
        return .all
        #endif
    }

    private static var debugUnwatchedOnly: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "scheduleHideWatched")
        #else
        return false
        #endif
    }
    /// Immediate visual state for the ladder. Real writes update the model optimistically; this
    /// also lets the DEBUG three-state fixture be interacted with without changing the account it
    /// is derived from.
    @State private var watchedOverrides: [String: Bool] = [:]
    @State private var prompt: FranchiseDetailView.WritePrompt?
    /// The card the reader just marked keeps its place until they leave the screen: the card moves
    /// on to the next thing to watch on the next visit, not under the finger that marked this one.
    @State private var heldHero: String? = nil
    /// The day at the top of the feed — what the calendar highlights. Reported by the system
    /// (`onScrollTargetVisibilityChange`), never measured by hand.
    @State private var selectedDay = 0
    /// The day the feed is showing, recorded during the scroll and read only when it stops — so
    /// the calendar's highlight never moves while the feed is moving (6 Sep).
    @State private var readingDay = 0
    /// Any day inside the month the calendar is showing, as an offset from today.
    @State private var monthAnchor = 0
    /// Whether the calendar is down. At rest it is NOT: the screen's whole point is that it has no
    /// date chrome until the reader asks for one.
    @State private var monthOpen = ScheduleDebug.monthOpen
    /// Once a finger has moved the feed it belongs to the reader; the landing stops correcting.
    @State private var userScrolled = false
    @State private var viewportH: CGFloat = 720
    /// Where the chrome band (the bar + any filter chips) ends, in screen space — the height its
    /// canvas ground is drawn at. MEASURED, not composed: the chips come and go, and the ground is
    /// a background, so it never feeds back into the band's own layout.
    @State private var chromeBottom: CGFloat = ThemeMetrics.topChromeHeight
    @State private var box = DerivedBox()
    /// This visit's arrival has begun (the rows and the card's words rise).
    @State private var arrived = false
    /// Where the landing day's block sits in the feed's content (the height of everything above
    /// it), and how many times the landing has been re-run for it this visit.
    @State private var landingTop: CGFloat = -1
    @State private var relands = 0

    private var now: Int64 { appModel.nowMinute }

    // MARK: - Geometry

    private enum Metrics {
        /// A day's break: the space above its first row (the rows' own padding adds to it). The
        /// only thing between two days — no banner, no rule.
        static let dayGap: CGFloat = ThemeSpace.x3
        /// How far past today a Later date may be, in days: the date column prints no year.
        static let laterReach = 365
    }

    // MARK: - Identity

    /// Every scroll target in the feed maps back to a day, so the position the system reports —
    /// whichever day or row happens to be at the top — names the day the calendar should show.
    enum AgendaID: Hashable {
        case day(Int)
        case row(Int, String)

        var day: Int {
            switch self {
            case .day(let d), .row(let d, _): return d
            }
        }
    }

    // MARK: - Feed

    /// One row on the calendar. A date-only part that drops several episodes on one day is ONE
    /// row ("Episodes 5–8"), not eight identical ones.
    struct Row: Identifiable {
        let franchise: Franchise
        let part: FranchisePart
        /// First and last episode number the row covers; equal for a single episode.
        let episodes: ClosedRange<Int>
        let at: Int64
        let aired: Bool
        let dateOnly: Bool
        var episode: Int { episodes.upperBound }
        var id: String { "\(franchise.id)/\(part.mediaId)/\(episode)" }
        var watched: Bool { aired && part.progress >= episode }
    }

    struct Day: Identifiable {
        let id: Int
        let noon: Int64
        let rows: [Row]
        var isToday: Bool { id == 0 }
        var isEmpty: Bool { rows.isEmpty }
        var count: Int { rows.count }
    }

    /// Everything the screen derives from the feed, computed ONCE per (feed, filter). The box is
    /// a reference so a cache fill inside a body read never invalidates the view.
    private struct Derived {
        var all: [Day] = []
        var earlier: [Day] = []
        /// Today and everything after it that carries something. TODAY IS ALWAYS IN HERE, empty
        /// or not — it is the feed's anchor, and the feed always opens on it (`land`). There is
        /// deliberately no "landing day" to go with it: the one this used to compute was the
        /// first NON-EMPTY day ≥ 0, and on a day with nothing scheduled the agenda opened on a
        /// future day and hid the "Today" button.
        var ahead: [Day] = []
        /// Today has rows, but the active filter is hiding all of them — so the empty-today line
        /// says "No episodes" (there are some; you filtered them) rather than "Nothing scheduled".
        var todayFiltered = false
        var counts: [Int: Int] = [:]
        /// Days with something still to come or still to watch — the grid's accent dots.
        var live: Set<Int> = []
        /// Past the window: each show's next dated airing, one row per show (`laterRows`), filtered.
        var later: [Row] = []
        /// The Later rows per day offset, for the month grid.
        var laterCounts: [Int: Int] = [:]
        var allEmpty = true
        var shownEmpty = true
        var feedKey: [Int] = []
        /// `-scheduleDemoStates 1`: the id of the one aired row drawn as UNWATCHED, so the three
        /// states can be photographed together. The test account has none of its own — both past
        /// airings are watched — and a ladder cannot be judged with a rung missing.
        var demoUnwatched: String? = nil
        /// ...and one drawn WATCHED, so the third rung shows even when every aired row is unwatched
        /// (review i4: capture 12 was capture 10 again).
        var demoWatched: String? = nil
    }

    private struct DerivedKey: Equatable {
        let feed: AppModel.ScheduleFeedKey
        let type: MediaFilter
        let unwatched: Bool
    }

    @MainActor private final class DerivedBox {
        var key: DerivedKey?
        var value = Derived()
    }

    private var derived: Derived {
        let key = DerivedKey(feed: appModel.scheduleFeedKey, type: typeFilter, unwatched: unwatchedOnly)
        if box.key == key { return box.value }
        let value = computeDerived()
        box.key = key
        box.value = value
        return value
    }

    private func computeDerived() -> Derived {
        let raw = appModel.scheduleDays
        let all = raw.map { Day(id: $0.id, noon: $0.noon, rows: rows(for: $0)) }
        let shown = all.map { Day(id: $0.id, noon: $0.noon, rows: $0.rows.filter(passes)) }
        var out = Derived()
        out.all = all
        let later = laterRows(after: raw)
        out.later = later.filter(passes)
        // The Later group's days answer on the calendar too — known, dotted, and a tap lands on
        // the row (`laterGroup` gives each day's first row the day's scroll id).
        for r in out.later {
            let d = laterDay(r)
            out.laterCounts[d, default: 0] += 1
        }
        out.allEmpty = all.allSatisfy(\.isEmpty) && later.isEmpty
        out.shownEmpty = shown.allSatisfy(\.isEmpty) && out.later.isEmpty
        out.earlier = shown.filter { $0.id < 0 && !$0.isEmpty }
        // `|| $0.id == 0`: today survives its own emptiness. `AppModel.buildScheduleDays` keeps
        // an empty today in the feed on purpose, as the anchor; dropping it here threw that away.
        out.ahead = shown.filter { $0.id >= 0 && (!$0.isEmpty || $0.id == 0) }
        out.todayFiltered = (shown.first { $0.id == 0 }?.isEmpty ?? true)
            && !(all.first { $0.id == 0 }?.isEmpty ?? true)
        out.counts = Dictionary(shown.map { ($0.id, $0.count) }, uniquingKeysWith: { a, _ in a })
        out.live = Set(shown.filter { $0.rows.contains { !$0.watched } }.map(\.id))
        out.feedKey = (out.earlier + out.ahead).map { $0.id * 1000 + $0.count } + [1_000_000 + out.later.count]
        if ScheduleDebug.demoStates {
            // The two most recent aired rows, so both sit near the landing: the last unwatched,
            // the one before it watched.
            let rows = out.earlier.flatMap(\.rows)
            out.demoUnwatched = rows.last?.id
            out.demoWatched = rows.dropLast().last?.id
        }
        return out
    }

    /// Groups a date-only part's same-day episodes into one row; everything else is one row each.
    private func rows(for day: AppModel.ScheduleDay) -> [Row] {
        var out: [Row] = []
        var dropIndex: [Int: Int] = [:]   // mediaId → index in `out`, for date-only parts only
        for e in day.entries {
            if e.dateOnly, let i = dropIndex[e.part.mediaId] {
                let r = out[i]
                out[i] = Row(franchise: r.franchise, part: r.part,
                             episodes: min(r.episodes.lowerBound, e.episode)...max(r.episodes.upperBound, e.episode),
                             at: r.at, aired: r.aired, dateOnly: true)
                continue
            }
            out.append(Row(franchise: e.franchise, part: e.part, episodes: e.episode...e.episode,
                           at: e.at, aired: e.aired, dateOnly: e.dateOnly))
            if e.dateOnly { dropIndex[e.part.mediaId] = out.count - 1 }
        }
        return out
    }

    /// LATER — each tracked show's next dated airing past the window, one row per show, for the
    /// shows the window goes quiet on: nothing still to come inside it. Bleach's Episode 8 aired
    /// on the 18th and Episode 9 is not until 19 Oct, and the feed could not say so — it ended on
    /// the break. A show with something still ahead inside the window is left out: its next
    /// episode past the edge would be the same show again, a week on, and this is a list of shows,
    /// not episodes. Every part is walked, as `buildScheduleDays` walks them, so a season whose
    /// dated premiere lies past the window has its row. No new data: the catalogue's own next slot
    /// is the one fact that reaches past the server's `airings`.
    private func laterRows(after raw: [AppModel.ScheduleDay]) -> [Row] {
        let todayKey = Formatting.localDayKey(appModel.scheduleTodayNoon)
        let waiting = Set(raw.flatMap(\.entries).filter { !$0.aired }.map(\.franchise.id))
        var out: [Row] = []
        // A PLANNED show contributes its dated premiere too — the one date a bookmark carries,
        // and the one its premiere alert fires for (iteration 2: the alert rang for a Seven Havens
        // premiere the calendar never showed). Only the premiere: Planned is not a weekly habit.
        for f in appModel.library where (f.tracksAirings || f.effectiveStatus == .planned) && !waiting.contains(f.id) {
            let planned = !f.tracksAirings
            var best: (part: FranchisePart, slot: Airing)?
            for part in f.parts where !planned || part.isUpcoming {
                for slot in knownSlots(of: part) where !planned || slot.episode == 1 {
                    let offset = Int((f.dayKey(of: slot.at) - todayKey) / Formatting.D)
                    guard offset > AppModel.scheduleAhead, offset < Metrics.laterReach else { continue }
                    // The soonest, and the lowest episode of a drop that shares its instant.
                    if let b = best, (b.slot.at, b.slot.episode) <= (slot.at, slot.episode) { continue }
                    best = (part, slot)
                }
            }
            guard let best else { continue }
            out.append(Row(franchise: f, part: best.part, episodes: best.slot.episode...best.slot.episode,
                           at: best.slot.at, aired: false, dateOnly: f.timeAnchor.isDateOnly))
        }
        return out.sorted { $0.at != $1.at ? $0.at < $1.at : $0.franchise.title < $1.franchise.title }
    }

    /// Every dated slot the app holds for a part: the calendar's (`scheduleAirings` — the server's
    /// `airings`, which reach 15 days ahead), plus the catalogue's own next slot, the one fact past
    /// them (AniList's next broadcast after a cour break, TMDB's next air date). That slot counts
    /// only with its episode known, by `scheduleAirings`' own rule: a dated season announcement is
    /// not automatically Episode 1.
    private func knownSlots(of part: FranchisePart) -> [Airing] {
        var out = part.scheduleAirings
        guard let next = part.nextAiringAt, next > 0 else { return out }
        let ep = part.nextEpisodeNumber ?? (part.isReleasing && part.airedEpisodes > 0 ? part.airedEpisodes + 1 : 0)
        if ep > 0, !out.contains(where: { $0.episode == ep }) { out.append(Airing(episode: ep, at: next)) }
        return out
    }

    private func passes(_ r: Row) -> Bool {
        switch typeFilter {
        case .all: break
        case .anime: if r.franchise.source != .anilist { return false }
        case .tv: if r.franchise.source != .tmdb { return false }
        }
        if unwatchedOnly && r.watched { return false }
        return true
    }

    private var filterActive: Bool { typeFilter != .all || unwatchedOnly }

    /// The screen is showing a whole-surface state rather than a feed.
    private var showsWholeScreenState: Bool {
        if appModel.loading && appModel.library.isEmpty { return true }
        if appModel.libraryEmpty { return true }
        let d = derived
        return d.allEmpty || (d.shownEmpty && filterActive)
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
            ThemeColor.canvas.ignoresSafeArea()
            ScrollView {
                // NOT pinned: a pinned header has to occlude the rows passing under it, which means
                // an opaque plate — and there is no header any more; the date rides the row.
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .scrollTargetLayout()
                .coordinateSpace(.named(Self.feedSpace))
                // The bar's scroll probe (`RootChromeState`). Only a READER's scroll moves the bar
                // (its phase, below): the landing on today is the app's scroll, with the past days
                // above it, and must not open the screen with its bars gone.
                .rootChromeProbe(rootChrome, rest: ThemeMetrics.topSafeInset + FeedMetrics.headerRow)
                // A user-requested layout change (a filter) is what `uiSnappy` is for, and it
                // belongs on the thing that re-lays out.
                .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: derived.feedKey)
                .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: pinnedEmptyDay)
                // The stale strip arrives on the 30-minute clock while the feed is being read;
                // it used to snap in and push every row down unannounced.
                .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion),
                           value: appModel.staleSince(.exactAiring) != nil)
            }
            // NOT bound to a `ScrollPosition`. An id-bound position is sticky: the anchored view is
            // re-pinned to the top on every layout change, so a row's own press-scale moved the
            // feed 28 pt under the finger and the tap arrived as a cancelled scroll. The two
            // programmatic scrolls (a grid tap, "Today") are one-shot.
            .safeAreaInset(edge: .top, spacing: 0) { chrome(proxy) }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { viewportH = $0 })
            // Nothing may come to rest under the tab bar. A scroll-content MARGIN, not padding:
            // padding inside a stack shorter than the viewport changes no layout at all.
            .tabBarContentMargin()
            .laneClearance(appModel)
            .scrollIndicators(.hidden)
            // The moment a finger touches the feed it belongs to the reader.
            .onScrollPhaseChange { _, phase in
                rootChrome.phase(phase)
                if phase == .interacting { userScrolled = true }
                // At rest, the calendar's selection moves to the day that was read — and only at
                // rest: every automatic movement of a date control while the feed was moving was
                // read as "bouncing" (five rounds of it, 6 Sep).
                if phase == .idle, readingDay != selectedDay {
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) {
                        selectedDay = readingDay
                        // The calendar follows the feed across a month boundary, so opening it
                        // never shows a month the reader has scrolled away from.
                        monthAnchor = readingDay
                    }
                }
            }
            // The system says which targets are on screen; the earliest day among them is the one
            // at the top. No coordinate spaces, no pin-line arithmetic.
            .onScrollTargetVisibilityChange(idType: AgendaID.self, threshold: 0.2) { ids in
                // Only RECORDED here; the calendar's selection reads it when the feed comes to
                // rest (see above).
                guard let day = ids.map(\.day).min() else { return }
                // The Later group's ids reach past the window; the grid stays on the window's
                // own months rather than turning to a month of disabled days.
                readingDay = min(day, AppModel.scheduleAhead)
            }
            // The calendar OVERLAYS the feed (Google Calendar's month dropdown), it does not push
            // it: 500 pt of grid inserted above a lazy stack threw the reader's place three
            // screens down and back again on every toggle. Last in the stack, so it is above the
            // feed; it hangs from the chrome band's bottom edge, so it reads as coming out of the
            // bar.
            calendarOverlay(proxy)
            }
        // The bar is the page's own (4 Oct — see `chrome`): the system's is hidden, and says so (a
        // pop from a page that shows one otherwise leaves its height in the top inset).
        .toolbar(.hidden, for: .navigationBar)
        .chromeScrollEdgeHidden(.top)
        .previouslyRefreshable { await appModel.reload() }
        .task { await ScheduleReminders.shared.refresh() }
        // The feed opens on TODAY — the card — with the past above it, whenever the feed's
        // identity changes and the reader has not taken the wheel. Once more a beat later: the
        // first pass can run before the lazy stack has laid out the days above today, and land
        // short.
        .onChange(of: derived.feedKey, initial: true) { _, _ in land(proxy) }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            land(proxy)
        }
        // The landing HOLDS until the reader touches the feed. Anything that
        // changes the height above the landing day after the landing — a stale strip arriving or
        // leaving, the library refreshing under a cached copy, the lazy stack measuring the days
        // above for real — used to leave the card's top (and its moment) under the bar.
        .onChange(of: landingTop) { _, _ in reland(proxy) }
        .onChange(of: visiting, initial: true) { _, on in visit(on) }
        // A card the reader marked stays until they leave; the next visit opens on what is next.
        .onDisappear { heldHero = nil }
        // The title stays for VoiceOver and for the back button of what this root pushes.
        .navigationTitle(Copy.Schedule.title)
        // The way back to today is in the bar: it returns the moment there is somewhere to go back
        // from, even with the bar scrolled away.
        .onChange(of: awayFromToday) { _, away in
            if away { rootChrome.reveal() }
        }
        // An alert, not a popover pinned under the bar 180 pt from the ring (interactive review):
        // a batch changes a number the user did not type, and it always offers Cancel.
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
               presenting: prompt) { p in
            if p.destructive {
                Button(p.confirm, role: .destructive) { p.perform() }
            } else {
                Button(p.confirm) { p.perform() }
            }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
        }
    }

    /// The reader is somewhere other than today. Measured against TODAY (day 0), which is always
    /// in the feed — never against "the first day that carries something".
    private var awayFromToday: Bool { selectedDay != 0 }

    // MARK: - Scrolling

    /// The feed opens on today — the card, or today's rows, or its "Nothing scheduled" — with the
    /// past above it. Un-animated. An unwatched drop from yesterday is ON the card (`pickHero`),
    /// which is why the landing no longer steps back to yesterday for it.
    private func land(_ proxy: ScrollViewProxy) {
        guard !userScrolled, !appModel.library.isEmpty, !showsWholeScreenState else { return }
        var t = Transaction()
        t.disablesAnimations = true
        let target = landingDay
        withTransaction(t) { proxy.scrollTo(AgendaID.day(target), anchor: .top) }
        if selectedDay != target { selectedDay = target }
        readingDay = target
        // The calendar opens on the month the feed landed in.
        monthAnchor = target
    }

    /// The day the feed lands on: today — or, for a capture, `-scheduleCaptureDay`'s day, or under
    /// `-scheduleDemoStates` the day of the row drawn WATCHED, so the capture holds all three rungs
    /// (the watched one sat above the landing, review i4/i5).
    private var landingDay: Int {
        let d = derived
        let demoDay: Int? = ScheduleDebug.demoStates
            ? d.earlier.first(where: { day in day.rows.contains { $0.id == d.demoWatched } })?.id : nil
        return ScheduleDebug.captureDay.flatMap { day in
            d.all.contains(where: { $0.id == day }) || d.laterCounts[day] != nil ? day : nil
        } ?? demoDay ?? 0
    }

    /// The landing day's block moved in the content before the reader touched the feed — land
    /// again. Bounded, so a layout that never settles cannot hold the feed hostage. (Before this, a
    /// first visit drew the past days and jumped to today ~130 ms later.)
    private func reland(_ proxy: ScrollViewProxy) {
        guard !userScrolled, relands < 8 else { return }
        relands += 1
        land(proxy)
    }

    // MARK: - The visit

    nonisolated static let feedSpace = "schedule.feed"

    /// A visit: this tab on screen, with the launch's ident gone or going — so a launch straight
    /// into Schedule plays its arrival as the app emerges, not under the ident.
    private var visiting: Bool { active && (launch?.emerging ?? true) }

    /// The arrival, once per visit: a beat for the landing to settle, then the card's words and the
    /// rows rise. Between visits everything goes back to its start, unseen. Under Reduce Motion it
    /// is simply there.
    private func visit(_ on: Bool) {
        guard on else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { arrived = false }
            return
        }
        relands = 0
        if reduceMotion {
            arrived = true
            return
        }
        // One frame: the hidden state is committed first (on a first visit the rows are made in
        // this pass), so the arrival animates from it rather than being folded into it. Waiting
        // longer left the card without its words and the agenda empty — a loading beat.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard visiting, !arrived else { return }
            PerfProbe.mark("schedule-arrival")
            arrived = true
        }
    }

    /// A grid tap: the feed lands on that day. A day with nothing on it gets a row drawn for the
    /// purpose (`pinnedEmptyDay`) a beat before the scroll, so there is something to land on.
    private func pick(_ offset: Int, count: Int, proxy: ScrollViewProxy) {
        // A day whose one airing is on the card draws nothing of its own: land on the card.
        if offset != 0, count == 1, let hero = pickHero(derived), hero.day == offset {
            scroll(to: .day(0), day: 0, proxy: proxy)
            return
        }
        // A LATER day is never pinned as an empty day: its row already carries the day's scroll
        // id, and a pinned twin took the id from it (review i5, F10). The merged counts at the
        // call sites say it is not empty; this guards any caller that forgets.
        if count == 0 && offset != 0 && derived.laterCounts[offset] == nil {
            pinnedEmptyDay = offset
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                scroll(to: .day(offset), day: offset, proxy: proxy)
            }
        } else {
            scroll(to: .day(offset), day: offset, proxy: proxy)
        }
    }

    private func scroll(to id: AgendaID, day: Int, proxy: ScrollViewProxy) {
        userScrolled = true
        selectedDay = day
        readingDay = day
        // The calendar follows an explicit move as well as a scroll, so pressing Today with the
        // grid open does not leave it on a month the feed has left.
        monthAnchor = day
        withAnimation(ThemeMotion.pick(ThemeMotion.uiReveal, reduceMotion: reduceMotion)) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// Back to today.
    private func goToToday(_ proxy: ScrollViewProxy) {
        scroll(to: .day(0), day: 0, proxy: proxy)
    }

    // MARK: - The calendar

    /// The grid, a scrim, and the rules for getting out of it. Mounted only while it is down —
    /// a held-at-zero-opacity overlay over a scrolling feed is a composited layer per frame.
    @ViewBuilder
    private func calendarOverlay(_ proxy: ScrollViewProxy) -> some View {
        if monthOpen {
            ZStack(alignment: .top) {
                // Anywhere off the grid closes it, as a menu does. The feed under it steps BACK,
                // light enough that the day the grid is about to take you to still reads.
                // From under the band: the bar stays in the light, and its switch closes the grid.
                Color.black.opacity(0.45)
                    .padding(.top, bandHeight)
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
                    .contentShape(Rectangle())
                    .onTapGesture { toggleCalendar() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                ScheduleMonthGrid(todayNoon: appModel.scheduleTodayNoon,
                                  counts: derived.counts.merging(derived.laterCounts) { a, _ in a },
                                  live: derived.live.union(derived.laterCounts.keys), selected: selectedDay,
                                  window: AppModel.scheduleBack...AppModel.scheduleAhead,
                                  extraDays: Set(derived.laterCounts.keys),
                                  monthAnchor: $monthAnchor,
                                  maxHeight: max(260, viewportH - ThemeMetrics.tabBarClearance)) { day in
                    // A pick closes the calendar. Leaving it down over the day it just took you to
                    // means the answer is hidden behind the question.
                    toggleCalendar()
                    pick(day, count: derived.counts[day] ?? derived.laterCounts[day] ?? 0, proxy: proxy)
                }
                // GLASS over the feed, not a flat grey slab: the panel is chrome that floats. The
                // canvas veil under the material (the hardened bar's `chromeBarOpacity`) keeps the
                // numerals legible over busy art.
                .background(ThemeColor.canvas.opacity(ThemeMetrics.chromeBarOpacity),
                            in: RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous))
                .glassChrome(in: RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
                    .strokeBorder(ThemeColor.stroke, lineWidth: 1))
                .shadow(.card)
                .padding(.horizontal, ThemeSpace.x3)
                .padding(.top, bandHeight + ThemeSpace.x1)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            .zIndex(2)
        }
    }

    private func toggleCalendar() {
        // The grid hangs from the bar: the bar is there when it opens.
        rootChrome.reveal()
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
            monthOpen.toggle()
        }
    }

    /// The band's height under the status band (the bar's row, and the filter chips when there
    /// are any) — what the calendar hangs under.
    private var bandHeight: CGFloat { max(FeedMetrics.headerRow, chromeBottom - ThemeMetrics.topSafeInset) }

    // MARK: - Chrome

    /// The band under the title: the active filters as removable tokens, and otherwise nothing —
    /// there is no date chrome at rest. Opaque canvas, flush with the feed, as Today's bar is.
    ///
    /// The BAR is here too (4 Oct, "the top and bottom header and nav are there even when
    /// scrolling", owner): the title, the way back to today, the calendar's switch and the filter,
    /// as the page's own row — the system bar it replaced could not leave with the scroll. The whole
    /// band slides by the row's height (`RootChromeSlide`), so an active filter's chips stay under
    /// the clock when the row has gone.
    private func chrome(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RootHeaderRow(title: Copy.Schedule.title, chrome: rootChrome) {
                // The way back once the reader has scrolled away from today. Ink, not amber: a
                // command.
                if awayFromToday {
                    Button(Copy.Schedule.today) { goToToday(proxy) }
                        .buttonStyle(.plain)
                        .type(ThemeType.listAction)
                        .foregroundStyle(ThemeColor.interactive)
                        .frame(minHeight: FeedMetrics.actionHitHeight)
                        .contentShape(Rectangle())
                        .accessibilityLabel(Copy.Schedule.scrollToToday)
                        .accessibilityHint(Copy.Schedule.scrollToTodayHint)
                        .transition(.opacity)
                }
            } trailing: {
                // The calendar's switch. A TAP, not a pull — this screen already owns the pull
                // gesture for refresh. ONE glyph in both states, tinted when the grid is down: a
                // control that changes its symbol on press reads as a different control.
                RootHeaderGlyph(systemName: "calendar",
                                tint: monthOpen ? ThemeColor.accent : ThemeColor.textPrimary) { toggleCalendar() }
                    .accessibilityLabel(Copy.Schedule.calendar)
                    .accessibilityValue(monthOpen ? Copy.Schedule.calendarShown : Copy.Schedule.calendarHidden)
                filterMenu
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
                    .contentShape(Rectangle())
            }
            filterChips
        }
        // Only the filter chips can give this band height, so only they earn its padding.
        .padding(.bottom, filterActive ? ThemeSpace.x2 : 0)
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: filterActive)
        // Drawn at a STATED height, bottom-aligned, so a short band never lets the feed print
        // through the status bar (6 Sep).
        .background(alignment: .bottom) {
            ThemeColor.canvas
                .frame(height: max(chromeBottom, ThemeMetrics.topChromeHeight))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxY },
                          action: { chromeBottom = $0 })
        .modifier(RootChromeSlide(chrome: rootChrome))
    }

    private var filterMenu: some View {
        Menu {
            Section(Copy.Filter.source) {
                Picker(Copy.Filter.source, selection: sourceBinding) {
                    Text(Copy.Filter.all).tag(MediaFilter.all)
                    Text(Copy.Filter.anime).tag(MediaFilter.anime)
                    Text(Copy.Filter.tv).tag(MediaFilter.tv)
                }
                .pickerStyle(.inline)
            }
            Toggle(Copy.Filter.hideWatched, isOn: hideWatchedBinding)
        } label: {
            AppGlyph(systemName: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .tint(filterActive ? ThemeColor.accent : ThemeColor.textPrimary)
        .accessibilityLabel(Copy.Filter.filter)
        .accessibilityValue(filterValue)
    }

    private var filterValue: String {
        var bits: [String] = []
        if typeFilter != .all { bits.append(typeFilter.chipLabel) }
        if unwatchedOnly { bits.append(Copy.Filter.hideWatched) }
        return bits.isEmpty ? Copy.Filter.off : bits.joined(separator: ", ")
    }

    // The haptic fires from the MUTATION, not from an observer, so one transaction is one haptic.
    private var sourceBinding: Binding<MediaFilter> {
        Binding(get: { typeFilter }, set: { typeFilter = $0 })
    }

    private var hideWatchedBinding: Binding<Bool> {
        Binding(get: { unwatchedOnly }, set: { unwatchedOnly = $0 })
    }

    /// The removable tokens for whatever is filtering the feed — in the CHROME, so a reader who
    /// filters, leaves and comes back is never shown a schedule that merely looks thin.
    @ViewBuilder
    private var filterChips: some View {
        if filterActive {
            HStack(spacing: ThemeSpace.x2) {
                if typeFilter != .all { filterChip(typeFilter.chipLabel) { typeFilter = .all } }
                if unwatchedOnly { filterChip(Copy.Filter.hideWatched) { unwatchedOnly = false } }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x2)
            .transition(.opacity)
        }
    }

    private func filterChip(_ text: String, clear: @escaping () -> Void) -> some View {
        Button {
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) { clear() }
        } label: {
            FilterChipLabel(text: text)
        }
        .buttonStyle(FilterChipStyle())
        .accessibilityLabel(Copy.Accessibility.removeFilter(text))
    }

    // MARK: - Content (state matrix)

    /// A whole-screen state sits in the middle of the content area, centred against the tab
    /// bar's VISUAL height.
    private func centred<V: View>(@ViewBuilder _ state: () -> V) -> some View {
        state()
            .padding(.horizontal, ThemeMetrics.gutter)
            .centredState(contentH: viewportH)
    }

    @ViewBuilder
    private func content() -> some View {
        if appModel.loading && appModel.library.isEmpty {
            // Through the gate every other root uses: no skeleton before 240 ms, so a fast
            // answer never flashes structure. (The feed stays a lazy stack, so the gate holds
            // the skeleton alone and the swap rides the stack's own `feedKey` animation.)
            SkeletonGate(isLoading: true) { feedSkeleton } content: { EmptyView() }
        } else if appModel.loadError && appModel.libraryEmpty {
            centred {
                EmptyState(SyncCenter.shared.isOnline ? .serverNoCache : .offlineNoData,
                           prominence: .major,
                           primary: { Task { await appModel.reload() } })
            }
        } else if appModel.libraryEmpty {
            centred {
                EmptyState(.emptySchedule, prominence: .major, artwork: .flapCalendar,
                           primary: onAddShow)
            }
        } else {
            if appModel.sectionFailed {
                InlineNotice(Copy.Notice.schedule) { Task { await appModel.reload() } }
                    .padding(.horizontal, ThemeMetrics.gutter).padding(.top, ThemeMetrics.labelGap)
            } else if let since = appModel.staleSince(.exactAiring) {
                StaleStrip(since: since, now: now)
                    .padding(.horizontal, ThemeMetrics.gutter).padding(.top, ThemeMetrics.labelGap)
            }
            let d = derived
            if d.allEmpty {
                centred { EmptyState(.nothingScheduled, prominence: .major) }
            } else if d.shownEmpty && filterActive {
                centred {
                    EmptyState(.noScheduleMatches, prominence: .major, primary: {
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                            typeFilter = .all; unwatchedOnly = false
                        }
                    })
                }
            } else {
                // The past, then today (the card), then what is ahead — one agenda, no fold. The
                // feed lands on today (`land`); the calendar's cells are the way back.
                let hero = pickHero(d)
                let counting = countdownRow(d, hero: hero)
                let drawn = blocks(d, hero: hero)
                ForEach(drawn) { b in dayBlock(b, counting: counting) }
                laterGroup(d.later, order: (drawn.last?.order ?? 0) + (drawn.last?.rows.count ?? 0))
            }
        }
    }

    /// The loading state in the screen's own anatomy — the card, then rows (the date, a face, two
    /// lines) — so the swap lands in place.
    private var feedSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock(height: nil, radius: ThemeRadius.card)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.top, ThemeSpace.x3)
                .padding(.bottom, ThemeSpace.x3)
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: ThemeSpace.x3) {
                    VStack(spacing: ThemeSpace.x1) {
                        SkeletonLine(width: 24, height: 9)
                        SkeletonLine(width: 20, height: 16)
                    }
                    .frame(width: 38)
                    .opacity(i == 1 ? 0 : 1)
                    SkeletonBlock(width: AgendaMetrics.avatar, height: AgendaMetrics.avatar, radius: AgendaMetrics.avatar / 2)
                    VStack(alignment: .leading, spacing: ThemeSpace.x1) {
                        SkeletonLine(width: 132, height: 13)
                        SkeletonLine(width: 96, height: 11)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, AgendaMetrics.leading)
                .padding(.vertical, AgendaMetrics.vertical)
                .padding(.top, i == 2 ? Metrics.dayGap : 0)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Days

    /// The feed's days: the past, today (always), everything ahead that carries something — and
    /// the one empty day the reader picked on the grid, drawn as a row that says "Nothing
    /// scheduled" so the pick lands somewhere instead of doing nothing.
    private func daysToDraw(_ d: Derived) -> [Day] {
        var days = d.earlier + d.ahead
        if let pinned = pinnedEmptyDay, pinned != 0, !days.contains(where: { $0.id == pinned }) {
            let noon = appModel.scheduleTodayNoon + Int64(pinned) * Formatting.D
            days.append(Day(id: pinned, noon: noon, rows: []))
            days.sort { $0.id < $1.id }
        }
        return days
    }

    /// The next thing to watch, and the day its row comes from.
    private struct Hero {
        let row: Row
        let day: Int
        /// What the moment is: "Out now", "Tonight at 7:30 PM", "Sunday at 4:30 PM".
        let eyebrow: String
    }

    /// One day as the feed draws it, decided in one pass so the month crossings and the card's row
    /// agree with each other.
    private struct DayBlock: Identifiable {
        let day: Day
        /// The day's rows, less the one on the card.
        let rows: [Row]
        /// The card — today's block only.
        let hero: Hero?
        /// The month this day opens, where the feed crosses into one: "October".
        var month: String?
        /// Today, or a picked day, with nothing on it says so beside its date.
        let empty: String?
        /// The arrival, counted from the landing day down the feed: this block's first row's place
        /// (the card is 0).
        var order = 0
        var id: Int { day.id }
        /// The day's one airing is on the card: nothing of its own to draw.
        var isBlank: Bool { rows.isEmpty && hero == nil && empty == nil }
    }

    /// The card's pick: the newest drop of today's, then yesterday's, that you have not seen
    /// ("Out now" — it is the next thing to WATCH); else today's next airing; else the next day's
    /// first. A card the reader just marked holds (`heldHero`). Nothing past the window: Later is
    /// not next.
    private func pickHero(_ d: Derived) -> Hero? {
        if let held = heldHero {
            for day in d.earlier + d.ahead {
                if let r = day.rows.first(where: { $0.id == held }) { return hero(r, day: day.id) }
            }
        }
        let today = d.ahead.first { $0.isToday }
        let yesterday = d.earlier.first { $0.id == -1 }
        for day in [today, yesterday] {
            if let day, let r = day.rows.last(where: { $0.aired && !facts($0).state.isWatched }) {
                return hero(r, day: day.id)
            }
        }
        if let r = today?.rows.first(where: { !$0.aired }) { return hero(r, day: 0) }
        if let next = d.ahead.first(where: { $0.id > 0 && !$0.isEmpty }), let r = next.rows.first {
            return hero(r, day: next.id)
        }
        return nil
    }

    private func hero(_ r: Row, day: Int) -> Hero {
        Hero(row: r, day: day, eyebrow: r.aired ? Copy.Schedule.outNow : moment(r))
    }

    /// When an airing is, as the card's eyebrow says it: the app's one ladder (`TemporalCopy.airs`
    /// — "Airs in 27 min", "Tomorrow at 4:30 PM", "Sunday at 4:30 PM", a date-only "Sunday"), with
    /// an evening airing today said as tonight (`Formatting.isEvening`, the app's one definition).
    private func moment(_ r: Row) -> String {
        let f = r.franchise
        let delta = r.at - now
        if !r.dateOnly, delta >= 60 * Formatting.minuteMs,
           Formatting.dayDiff(ts: r.at, now: now, anchor: f.timeAnchor) == 0,
           Formatting.isEvening(hour: Formatting.localParts(r.at, anchor: f.timeAnchor).hour) {
            return Copy.Schedule.tonightAt(Formatting.fmtTime(r.at, anchor: f.timeAnchor))
        }
        return TemporalCopy.airs(at: r.at, now: now, source: f.source)
    }

    private func blocks(_ d: Derived, hero: Hero?) -> [DayBlock] {
        var out: [DayBlock] = []
        // A month is named where the feed crosses into one — and at the top, when the feed opens in
        // a month other than today's. The date column carries no month: "WED 30" then "SAT 3" said
        // nothing about October having begun (review i3).
        var month = Formatting.localParts(now).mo
        let landing = landingDay
        var order = 0
        for day in daysToDraw(d) {
            let rows = day.rows.filter { $0.id != hero?.row.id }
            let card = day.isToday ? hero : nil
            let empty: String? = rows.isEmpty && card == nil && (day.isToday || day.id == pinnedEmptyDay)
                ? (day.isToday && d.todayFiltered ? Copy.Schedule.noEpisodes : Copy.Schedule.nothingScheduled)
                : nil
            var block = DayBlock(day: day, rows: rows, hero: card, month: nil, empty: empty)
            if !block.isBlank {
                let m = Formatting.localParts(day.noon).mo
                if m != month { block.month = Formatting.formatted(day.noon, skeleton: "MMMM", anchor: .local) }
                month = m
                if day.id >= landing {
                    let lead = card == nil ? 0 : 1
                    block.order = order + lead
                    order += lead + rows.count + (empty == nil ? 0 : 1)
                }
            }
            out.append(block)
        }
        return out
    }

    // MARK: - The feed

    /// A day: the month it opens (only where the feed crosses into one), the card on today, then
    /// its rows — the date in the first row's column. The whole day is ONE child of the lazy feed
    /// with the day's id, so the grid and the "Today" button land on it, month and all.
    @ViewBuilder
    private func dayBlock(_ b: DayBlock, counting: String?) -> some View {
        if b.isBlank {
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
                .id(AgendaID.day(b.day.id))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let month = b.month {
                    ScheduleEyebrow(text: month)
                        .padding(.top, ThemeSpace.x6)
                        .padding(.bottom, ThemeSpace.x1)
                        .modifier(riseIn(b.order))
                }
                if let hero = b.hero {
                    heroCard(hero)
                        .padding(.top, ThemeSpace.x3)
                        .padding(.bottom, b.rows.isEmpty ? 0 : ThemeSpace.x3)
                }
                ForEach(Array(b.rows.enumerated()), id: \.element.id) { i, r in
                    agendaRow(r, date: i == 0 ? dateColumn(b.day) : nil, isToday: b.day.isToday,
                              order: b.order + i, counting: counting)
                }
                if let empty = b.empty {
                    let date = dateColumn(b.day)
                    ScheduleEmptyDayRow(weekday: date.top, numeral: date.numeral, isToday: b.day.isToday,
                                        text: empty,
                                        spoken: "\(Formatting.formatted(b.day.noon, skeleton: "EEEEdMMMM", anchor: .local)), \(empty)")
                        .modifier(riseIn(b.order))
                }
            }
            .padding(.top, b.hero == nil && b.month == nil ? Metrics.dayGap : 0)
            .background { landingProbe(b) }
            .id(AgendaID.day(b.day.id))
        }
    }

    // MARK: - The lit pieces

    /// Reports where the landing day's block sits in the feed (`reland`).
    @ViewBuilder
    private func landingProbe(_ b: DayBlock) -> some View {
        if b.day.id == landingDay {
            Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.feedSpace)).minY.rounded()
            } action: { y in
                if y != landingTop { landingTop = y }
            }
        }
    }

    /// A row rises in `order` beats after the visit began, the whole arrival ≤ 0.3 s.
    private func riseIn(_ order: Int) -> ScheduleRise {
        ScheduleRise(shown: arrived,
                     delay: min(Double(order) * ScheduleArrivalMetrics.rowStep, ScheduleArrivalMetrics.rowCap))
    }

    /// The row that counts down: today's next airing still to come — unless the card carries it (its
    /// moment says "Airs in 9 min", "Tonight at 7:30 PM") — or, under `-scheduleDemoCountdown`, the
    /// next airing on any day. A date-only airing has no clock to count to.
    private func countdownRow(_ d: Derived, hero: Hero?) -> String? {
        let pool = ScheduleDebug.demoCountdown
            ? d.ahead.flatMap(\.rows)
            : (d.ahead.first { $0.isToday }?.rows ?? [])
        guard let next = pool.first(where: { !$0.aired && !$0.dateOnly }), next.id != hero?.row.id else { return nil }
        return next.id
    }

    /// What a lit row wears: its show's colour under its face, and today's countdown.
    private func decor(_ r: Row, counting: Bool) -> ScheduleRowDecor {
        var d = ScheduleRowDecor()
        d.hueURL = r.franchise.portraitArt
        if counting { d.accentTail = Copy.Schedule.countdown(Formatting.fmtCountdown(target: r.at, now: now)) }
        return d
    }

    /// "FRI" over "25" — the day's weekday and numeral, for its first row's date column.
    private func dateColumn(_ day: Day) -> (top: String, numeral: String) {
        let p = Formatting.localParts(day.noon)
        return (Formatting.weekdayShort(p.wd), "\(p.d)")
    }

    /// LATER — past the window, each quiet show's next dated airing (or a Planned show's premiere),
    /// in the agenda's own row with the MONTH in the date column ("OCT" over "19"). Each row is a
    /// DIRECT child of the lazy feed, the day's first with the day's id, so the grid can land on
    /// it (review i3).
    @ViewBuilder
    private func laterGroup(_ rows: [Row], order: Int = 0) -> some View {
        if !rows.isEmpty {
            ScheduleEyebrow(text: Copy.Schedule.later)
                .padding(.top, ThemeSpace.x8)
                .padding(.bottom, ThemeSpace.x1)
                .modifier(riseIn(order))
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                let day = laterDay(r)
                let firstOfDay = i == 0 || laterDay(rows[i - 1]) != day
                let p = Formatting.localParts(r.at, anchor: r.franchise.timeAnchor)
                agendaRow(r, date: firstOfDay ? (monthShort(p.mo), "\(p.d)") : nil, isToday: false,
                          order: order + i)
                    .padding(.top, firstOfDay && i > 0 ? Metrics.dayGap : 0)
                    .id(firstOfDay ? AgendaID.day(day) : AgendaID.row(day, r.id))
            }
        }
    }

    /// A Later row's day, as an offset from today in its own calendar — the grid's key.
    private func laterDay(_ r: Row) -> Int {
        Formatting.dayDiff(ts: r.at, now: appModel.now, anchor: r.franchise.timeAnchor)
    }

    /// Built once: a `DateFormatter` per row per render was the cost of every scroll frame that
    /// re-evaluated the feed.
    private static let monthSymbols = DateFormatter().shortMonthSymbols ?? []

    private func monthShort(_ month: Int) -> String {
        let symbols = Self.monthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1].uppercased() : ""
    }

    // MARK: - Rows

    /// Everything a row needs, computed once, so the card and the row cannot disagree about an
    /// airing's state the way the pre-6-Sep card's three corners did.
    private struct RowFacts {
        let state: AiringState
        let time: String?
        let hasReminder: Bool
        let zoom: String
        /// The show is in the library and the episode has aired, so the ladder can mark it.
        let canToggle: Bool
    }

    private func facts(_ r: Row) -> RowFacts {
        let f = r.franchise
        // `-scheduleDemoStates`: one aired row is drawn as though it were still waiting, so the
        // ladder can be photographed with all three rungs.
        let demoUnseen = derived.demoUnwatched == r.id
        let demoSeen = derived.demoWatched == r.id
        let watched = watchedOverrides[r.id] ?? ((r.watched || demoSeen) && !demoUnseen)
        return RowFacts(state: !r.aired ? .upcoming : (watched ? .watched : .toWatch),
                        time: r.dateOnly ? nil : Formatting.fmtTime(r.at, anchor: f.timeAnchor),
                        hasReminder: !r.aired && ScheduleReminders.shared.has(mediaId: r.part.mediaId,
                                                                             episode: r.episode),
                        zoom: "sched/\(f.id)/\(r.episode)",
                        canToggle: r.aired && appModel.isInLibrary(f.id))
    }

    private func openAction(_ r: Row, _ x: RowFacts) -> () -> Void {
        { onOpenDetail(r.franchise.id, x.zoom,
                       EpisodeFocus(mediaId: r.part.mediaId, episode: r.episode)) }
    }

    private func agendaRow(_ r: Row, date: (top: String, numeral: String)?, isToday: Bool,
                           order: Int = 0, counting: String? = nil) -> some View {
        let f = r.franchise
        let x = facts(r)
        let count = max(1, r.episodes.upperBound - r.part.progress)
        // Today's next airing says how long is left where its clock was.
        let counts = counting != nil && counting == r.id
        let line = counts
            ? "\(episodeLine(r)) \u{00B7} \(Copy.Schedule.countdown(Formatting.fmtCountdown(target: r.at, now: now)))"
            : [episodeLine(r), x.time].compactMap { $0 }.joined(separator: " \u{00B7} ")
        return ScheduleAgendaRow(franchise: f, date: date, isToday: isToday, line: line, state: x.state,
                                 spoken: spoken(r, line: line, x),
                                 decor: decor(r, counting: counts),
                                 onOpen: openAction(r, x)) {
            AiringStateControl(state: x.state, episode: r.episode, committing: false, title: f.displayTitle,
                               batch: count > 1, count: count, canMark: x.canToggle) {
                toggleWatched(r, watched: x.state.isWatched)
            }
        }
        .franchiseQuickActions(appModel.isInLibrary(f.id) ? f : nil, appModel: appModel)
        .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: x.state.isWatched)
        .modifier(riseIn(order))
    }

    /// Every row says its date to VoiceOver — the date column is drawn on a day's first row only,
    /// and a row read on its own must not lose its day.
    private func spoken(_ r: Row, line: String, _ x: RowFacts) -> String {
        [Formatting.formatted(r.at, skeleton: "EEEEdMMMM", anchor: r.franchise.timeAnchor),
         r.franchise.title, line,
         x.hasReminder ? Copy.Schedule.reminderSet : nil,
         x.state.isWatched ? Copy.Action.watched : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The card, as Home's billboard's sibling (`ScheduleLitCard`).
    private func heroCard(_ h: Hero) -> some View {
        let r = h.row
        let f = r.franchise
        let x = facts(r)
        return ScheduleLitCard(franchise: f, eyebrow: h.eyebrow, line: heroLine(r), state: x.state,
                               canToggle: x.canToggle,
                               markLabel: x.state.isWatched ? Copy.Action.markEpisodeUnwatched(r.episode)
                                                            : Copy.Action.markEpisodeWatched(r.episode),
                               arrived: arrived,
                               onToggle: {
                                   heldHero = r.id
                                   toggleWatched(r, watched: x.state.isWatched)
                               },
                               onOpen: openAction(r, x))
            .franchiseQuickActions(appModel.isInLibrary(f.id) ? f : nil, appModel: appModel)
            .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: x.state.isWatched)
    }

    // MARK: - What a row says

    /// What VARIES down the feed: "Episode 14", "Episodes 5–8", "Season 2 premiere" — and the part
    /// only when it is not the one the reader is in (`namesPart`). A weekly show cannot leave its
    /// season inside the window, so on the rows the season is a constant, and it is dropped.
    private func episodeLine(_ r: Row) -> String {
        if r.part.kind == .movie || r.episodes.lowerBound == 1 {
            let count = r.episodes.count > 1 ? Copy.episodes(r.episodes.count) : nil
            return [Copy.Schedule.premiere(premiereName(r)), count].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        let episodes = r.episodes.count > 1
            ? Copy.Schedule.episodeRange(r.episodes.lowerBound, r.episodes.upperBound)
            : Copy.episode(r.episode)
        guard namesPart(r) else { return episodes }
        if r.episodes.count == 1 { return r.franchise.watchContext(part: r.part, episode: r.episode) }
        let label = Copy.compactPartLabel(r.part.canonicalLabel)
        return label.isEmpty ? episodes : "\(label) \u{00B7} \(episodes)"
    }

    /// The card stands alone, so it says the season with the episode ("Season 4 · Episode 21");
    /// a premiere or a drop in its own words.
    private func heroLine(_ r: Row) -> String {
        guard r.episodes.count == 1, r.part.kind != .movie, r.episodes.lowerBound > 1 else { return episodeLine(r) }
        return r.franchise.watchContext(part: r.part, episode: r.episode)
    }

    /// The row is from a part other than the one the user is in: an EXTRA airing beside the show (a
    /// spin-off, a side story, a special — off the story's spine), or a season other than the
    /// furthest one their progress has reached (Season 4 airing over a Season 3 backlog, or a new
    /// season not yet started). The furthest part with progress, not `resumePart`: one half-watched
    /// older season steers that, and would put the season back on every ordinary row of the one
    /// airing. A user with no progress at all is following what airs, so the airing part is theirs.
    private func namesPart(_ r: Row) -> Bool {
        let f = r.franchise
        guard f.parts.count > 1 else { return false }
        let spine = f.mainStoryEpisodicParts
        guard spine.contains(where: { $0.mediaId == r.part.mediaId }) else { return true }
        guard let current = spine.last(where: { $0.progress > 0 }) else { return false }
        return current.mediaId != r.part.mediaId
    }

    /// The part as its premiere names it: a film by its title; a season by its own compacted label
    /// ("Season 5: Hashira Training Arc" → "Season 5"); nothing on a show of one part, whose title
    /// on the row says it — the rule `Franchise.watchContext` follows.
    private func premiereName(_ r: Row) -> String {
        if r.part.kind == .movie { return r.part.canonicalLabel }
        return r.franchise.parts.count > 1 ? Copy.compactPartLabel(r.part.canonicalLabel) : ""
    }

    // MARK: - The mark (the only write)

    private func toggleWatched(_ r: Row, watched: Bool) {
        let part = r.part
        if watched {
            let target = max(0, r.episodes.lowerBound - 1)
            let count = max(1, part.progress - target)
            if count > 1 {
                prompt = .init(title: "Mark \(Copy.episodes(count)) as unwatched?",
                               message: Copy.Confirm.batchMarkMessage(from: part.progress, to: target),
                               confirm: "Mark \(Copy.episodes(count)) as unwatched",
                               destructive: true) {
                    setProgress(r, to: target, watched: false)
                }
            } else {
                setProgress(r, to: target, watched: false)
            }
            return
        }

        let target = r.episodes.upperBound
        let count = target - part.progress
        // The DEBUG state fixture may draw an already-watched row as waiting. Let its control
        // animate for visual QA, but do not send a no-op account write.
        if count <= 0 {
            withAnimation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion)) {
                watchedOverrides[r.id] = true
            }
        } else if count > 1 {
            prompt = .init(title: Copy.Confirm.batchMarkTitle(count),
                           message: Copy.Confirm.batchMarkMessage(from: part.progress, to: target),
                           confirm: Copy.Confirm.batchMarkConfirm(count)) {
                setProgress(r, to: target, watched: true)
            }
        } else {
            setProgress(r, to: target, watched: true)
        }
    }

    /// The control itself is the receipt: it fills or opens in place. No second success line is
    /// inserted under the row, and no redundant success toast competes with the next release.
    private func setProgress(_ r: Row, to target: Int, watched: Bool) {
        // A mark on a show filed Watched (a new season on the calendar) watches it again
        // (`AppModel.resume`) — the one case this control says anything beyond itself, on the lane.
        let prev = r.part.progress
        let shelvedAs = watched && target > prev ? appModel.resumableStatus(r.franchise, part: r.part) : nil
        withAnimation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion)) {
            watchedOverrides[r.id] = watched
            appModel.setProgress(franchiseId: r.franchise.id,
                                 mediaId: r.part.mediaId,
                                 episodes: target)
        }
        if shelvedAs != nil {
            var receipt = UndoState(mediaId: r.part.mediaId, franchiseId: r.franchise.id, prevProgress: prev,
                                    title: r.franchise.title, episode: target, count: max(1, target - prev))
            appModel.resume(shelvedAs, franchiseId: r.franchise.id, mediaId: r.part.mediaId,
                            prevProgress: prev, receipt: &receipt)
            if receipt.subtitle != nil { appModel.presentUndo(receipt) }
        }
    }
}
