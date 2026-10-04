import Foundation
import SwiftUI

// "Recommended for you" — the model half. The server ranks (docs/api-contract.md,
// `GET /me/recommendations`); this file fetches, keeps an offline copy, and carries the three
// things a person does with a recommendation: add it to Planned, say "Not interested" or
// "Already seen", and open it (materialising a show page the catalogue does not have yet).

extension AppModel {
    /// What Today draws, in the server's order: nothing hidden this session, nothing the library
    /// already holds (an add lands before the next list does).
    var visibleRecommendations: [RecommendationItem] { visibleRecommendations(in: recommendations) }

    /// The same rule over any list (the See-all screen's longer one).
    func visibleRecommendations(in list: [RecommendationItem]) -> [RecommendationItem] {
        list.filter { r in
            // The viewer's kind only (`Audience`): the server ranks for it; a list fetched before
            // the choice, or by an older server, is held to it here.
            guard audience.allows(r.source) else { return false }
            guard !hiddenRecommendationKeys.contains(r.key) else { return false }
            // One added from the shelf keeps its tile, ticked, until the next list.
            return addedRecommendationKeys.contains(r.key) || !isOwned(r)
        }
    }

    /// The See-all screen's list: up to 30, fetched when it opens. Nil (the shelf's list stands in)
    /// when it cannot load, or against a server that predates the endpoint.
    func longerRecommendations() async -> [RecommendationItem]? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "forYouDemo") { return RecommendationDemo.items(library: library, limit: 30) }
        #endif
        guard !isIsolated else { return nil }
        return try? await api.recommendations(limit: 30).items
    }

    /// The show page this title has — sent with it, or materialised on a tap this session.
    func showId(of r: RecommendationItem) -> String? { r.franchiseId ?? resolvedRecommendationIds[r.key] }

    /// Already in the library (added from the shelf, or elsewhere since the list was made).
    func isOwned(_ r: RecommendationItem) -> Bool { showId(of: r).map(isInLibrary) ?? false }

    /// The live recommendation for a show page, if the show is recommended and not yours — so
    /// the page can say WHY, however it was reached.
    func recommendation(forShow id: String) -> RecommendationItem? {
        visibleRecommendations.first { showId(of: $0) == id && !isInLibrary(id) }
    }

    /// The reason in the user's own words for their shows: each seed by the library's short name
    /// ("Re:ZERO"), the server's order kept.
    func spokenReason(_ r: RecommendationItem) -> RecommendationItem.Reason {
        let seeds = r.reason.seeds.map { seed in
            RecommendationItem.Seed(franchiseId: seed.franchiseId,
                                    title: franchise(id: seed.franchiseId)?.displayTitle ?? seed.title)
        }
        // A single show's verb is the one its row says TODAY, not the one the list was ranked
        // with: "Because you're watching Mushoku Tensei" sat beside every screen filing it as
        // Planned (review i5, N9). A paused or dropped show is a plain "Like".
        var kind = r.reason.kind
        if r.reason.count <= 1, kind != .world, let seed = seeds.first, let f = franchise(id: seed.franchiseId) {
            switch f.effectiveStatus {
            case .watching: kind = .watching
            case .completed: kind = .finished
            case .planned: kind = f.parts.contains { $0.progress > 0 } ? .started : .planned
            default: kind = .consensus
            }
        }
        return .init(kind: kind, seeds: seeds, count: r.reason.count)
    }

    /// The list is re-ranked against the library it was fetched for: a change of membership or
    /// status (an add, a finish) or six hours refetches it; anything else keeps the one on screen.
    /// Debounced, so a burst of writes asks once.
    func refreshRecommendationsIfNeeded(force: Bool = false) {
        guard !isIsolated else { return }
        // A title added FROM the shelf is not a change of taste the list must answer at once —
        // refetching then would pull its tile out from under the finger that added it.
        let key = library.reduce(into: Hasher()) { h, f in
            guard !addedRecommendationIds.contains(f.id) else { return }
            h.combine(f.id); h.combine(f.effectiveStatus.rawValue)
        }.finalize()
        // An EMPTY list is not an answer to keep for six hours — a first list comes back sooner.
        let staleAfter = recommendations.isEmpty ? Formatting.H / 3 : 6 * Formatting.H
        let stale = Int64.nowMs - recommendationsFetchedAt > staleAfter
        let first = recommendationsState == .idle
        guard force || stale || key != recommendationsLibraryKey || first else { return }
        recommendationsTask?.cancel()
        recommendationsTask = Task { [weak self] in
            // The FIRST list of a launch is not debounced: it is what the shelf's skeleton (and
            // the calm stage) waits on (review i5, U-N4). Bursts of writes are.
            try? await Task.sleep(for: .milliseconds(force || first ? 0 : 1500))
            guard !Task.isCancelled, let self else { return }
            await self.loadRecommendations(libraryKey: key)
        }
    }

    private func loadRecommendations(libraryKey: Int) async {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "forYouDemo") {
            recommendations = RecommendationDemo.items(library: library)
            recommendationsState = .loaded
            recommendationsFetchedAt = .nowMs
            recommendationsLibraryKey = libraryKey
            return
        }
        #endif
        do {
            // Sixteen for a shelf of twelve: hides and adds REFILL it from the rest instead of
            // shrinking it until the next list (review i5, F13).
            let res = try await api.recommendations(limit: 16)
            recommendations = res.items
            recommendationsState = .loaded
            UserDefaults.standard.removeObject(forKey: Self.unavailableKey)
            // The new list is the next refresh the added tiles were waiting for.
            addedRecommendationKeys = []
            addedRecommendationIds = []
            recommendationsFetchedAt = .nowMs
            recommendationsLibraryKey = libraryKey
            // A hidden key the server has now excluded no longer needs hiding here (the server
            // has the answer); one it still sends stays hidden until its feedback lands.
            hiddenRecommendationKeys.formIntersection(res.items.map(\.key))
            var state = Self.loadFeedbackState()
            state.hidden = Array(hiddenRecommendationKeys)
            Self.saveFeedbackState(state)
            flushFeedback()
            Self.persistRecommendations(res)
        } catch APIError.http(404, _) {
            // A server that predates the endpoint: no shelf, and no error either — and no
            // skeleton on the next launches either (it flashed four tiles and collapsed on every
            // launch against the 404, review i5, U-N4). Asked again after a day.
            recommendationsState = .unavailable
            recommendations = []
            UserDefaults.standard.set(Double(Int64.nowMs + 24 * Formatting.H), forKey: Self.unavailableKey)
        } catch {
            guard !error.isCancellation else { return }
            // The offline copy stays on screen; nothing is raised for a shelf of suggestions.
            if recommendations.isEmpty { recommendationsState = .failed }
        }
    }

    // MARK: The stage

    /// The day's billboard pick — one of the first three with a show page, rotated by the LOCAL
    /// day — kept for the whole day while the list still carries it, across launches and
    /// refetches (review i5, N7: the first launch of a day drew yesterday's cached pick and then
    /// swapped the whole stage for today's 1.5 s later; the rotation turned at UTC midnight).
    func stagedRecommendation(from ready: [RecommendationItem]) -> RecommendationItem? {
        guard !ready.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date(timeIntervalSince1970: TimeInterval(now) / 1000)) ?? 0
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.stageDayKey) == day,
           let key = defaults.string(forKey: Self.stageKey),
           let staged = ready.first(where: { $0.key == key }) {
            return staged
        }
        let pool = Array(ready.prefix(3))
        let pick = pool[day % pool.count]
        defaults.set(day, forKey: Self.stageDayKey)
        defaults.set(pick.key, forKey: Self.stageKey)
        return pick
    }

    nonisolated static let stageDayKey = "previously.forYouStageDay"
    nonisolated static let unavailableKey = "previously.recommendationsUnavailableUntil"

    /// The server answered 404 within the last day: draw no skeleton for a shelf that will not come.
    var recommendationsRecentlyUnavailable: Bool {
        UserDefaults.standard.double(forKey: Self.unavailableKey) > Double(Int64.nowMs)
    }
    nonisolated static let stageKey = "previously.forYouStageKey"

    // MARK: Actions

    /// "Add to Planned" — the tile's + and the billboard's capsule. A title with no show page is
    /// materialised first (`resolveFranchise`), then added with the app's one add receipt.
    func addRecommendation(_ r: RecommendationItem) {
        Task { [weak self] in
            guard let self, let id = await self.franchiseId(for: r) else { return }
            self.addedRecommendationIds.insert(id)
            self.addedRecommendationKeys.insert(r.key)
            self.addToLibrary(franchiseId: id, title: r.title, isReleasing: r.airing, status: .planned)
        }
    }

    /// "Not interested": gone at once, told on the lane with an Undo, learned by the server
    /// (`POST /me/recommendations/feedback`). The hide is REMEMBERED on the device and the
    /// feedback is kept until the server has it — in memory with a fire-and-forget request, a
    /// dismissal made offline (or whose request failed) was back on the next list, and every cold
    /// launch redrew it from the offline copy (review i5, N3).
    func hideRecommendation(_ r: RecommendationItem, seen: Bool) {
        let key = r.key
        withAnimation(ThemeMotion.uiGentle) { _ = hiddenRecommendationKeys.insert(key) }
        queueFeedback(key: key, kind: seen ? "seen" : "dismissed")
        presentUndo(UndoState(mediaId: nil, franchiseId: r.franchiseId, prevProgress: 0, title: r.title,
                              episode: 0,
                              customMessage: seen ? Copy.ForYou.markedSeen : Copy.ForYou.hidden) { [weak self] in
            guard let self else { return }
            withAnimation(ThemeMotion.uiGentle) { _ = self.hiddenRecommendationKeys.remove(key) }
            self.queueFeedback(key: key, kind: "undo")
        })
    }

    // MARK: Feedback that survives

    /// One pending answer per title — the newest word wins: an undo of a dismissal the server
    /// never received cancels it on the device instead of sending both.
    private func queueFeedback(key: String, kind: String) {
        var state = Self.loadFeedbackState()
        if kind == "undo", state.pending[key] != nil, state.pending[key] != "undo" {
            state.pending[key] = nil
        } else {
            state.pending[key] = kind
        }
        state.hidden = Array(hiddenRecommendationKeys)
        Self.saveFeedbackState(state)
        flushFeedback()
    }

    /// Sends what the server has not had yet; each answer leaves the queue only once it lands.
    func flushFeedback() {
        guard !isIsolated else { return }
        let pending = Self.loadFeedbackState().pending
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            for (key, kind) in pending {
                guard let self else { return }
                do {
                    if kind == "undo" {
                        try await self.api.removeRecommendationFeedback(key: key)
                    } else {
                        try await self.api.recommendationFeedback(key: key, kind: kind)
                    }
                    var state = Self.loadFeedbackState()
                    if state.pending[key] == kind { state.pending[key] = nil }
                    Self.saveFeedbackState(state)
                } catch {
                    // Kept for the next launch or the next successful list.
                }
            }
        }
    }

    struct FeedbackState: Codable {
        var hidden: [String] = []
        var pending: [String: String] = [:]
    }

    nonisolated private static let feedbackURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("recommendations-feedback.json")
    }()

    static func loadFeedbackState() -> FeedbackState {
        guard let data = try? Data(contentsOf: feedbackURL),
              let state = try? JSONDecoder().decode(FeedbackState.self, from: data) else { return FeedbackState() }
        return state
    }

    static func saveFeedbackState(_ state: FeedbackState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: feedbackURL, options: .atomic)
    }

    /// The franchise a tap opens: the show page the server already has, else one it materialises
    /// now (the tile shows the wait). Nil — with the "not in the catalogue" notice — when it can't.
    func franchiseId(for r: RecommendationItem) async -> String? {
        if let id = showId(of: r) { return id }
        // One materialisation per TITLE at a time — a tap on another title while one resolves
        // is its own (a second tap on the same one is the spinner already showing; review i5).
        guard !resolvingRecommendations.contains(r.key) else { return nil }
        resolvingRecommendations.insert(r.key)
        defer { resolvingRecommendations.remove(r.key) }
        do {
            let summary = try await api.resolveFranchise(source: r.source, externalId: r.externalId)
            resolvedRecommendationIds[r.key] = summary.id
            return summary.id
        } catch {
            showNotice(SyncCenter.shared.isOnline ? Copy.Notice.notInCatalogue : Copy.ForYou.offline)
            return nil
        }
    }

    // MARK: Offline copy

    nonisolated private static let recommendationsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recommendations-cache.json")
    }()

    /// The last list this device saw, so Today opens with its shelf, offline included — with the
    /// titles this device has hidden still hidden, and any feedback the server has not had sent.
    func loadCachedRecommendations() {
        guard recommendations.isEmpty, !isIsolated else { return }
        hiddenRecommendationKeys.formUnion(Self.loadFeedbackState().hidden)
        flushFeedback()
        Task { [weak self] in
            let url = Self.recommendationsURL
            let cached = await Task.detached(priority: .utility) { () -> RecommendationsResponse? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(RecommendationsResponse.self, from: data)
            }.value
            guard let self, let cached, self.recommendations.isEmpty else { return }
            self.recommendations = cached.items
            if self.recommendationsState == .idle { self.recommendationsState = .loaded }
        }
    }

    private static func persistRecommendations(_ res: RecommendationsResponse) {
        let url = recommendationsURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(res) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Sign-out: the list and its copy belong to the account that fetched them.
    func clearRecommendations() {
        recommendationsTask?.cancel()
        recommendations = []
        recommendationsState = .idle
        recommendationsFetchedAt = 0
        recommendationsLibraryKey = 0
        hiddenRecommendationKeys = []
        sessionStage = nil
        addedRecommendationKeys = []
        addedRecommendationIds = []
        resolvedRecommendationIds = [:]
        resolvingRecommendations = []
        try? FileManager.default.removeItem(at: Self.recommendationsURL)
        try? FileManager.default.removeItem(at: Self.feedbackURL)
        UserDefaults.standard.removeObject(forKey: Self.stageDayKey)
        UserDefaults.standard.removeObject(forKey: Self.stageKey)
    }
}

#if DEBUG
/// `-forYouDemo 1`: a list built on the device from the library's own "More like this" titles —
/// consensus across the library, nothing owned — so the shelf and the billboard can be captured
/// against a server that predates `/me/recommendations`. Never ranking: the server ranks.
@MainActor
enum RecommendationDemo {
    static func items(library: [Franchise], limit: Int = 12) -> [RecommendationItem] {
        let owned = Set(library.map(\.id))
        let ownedTitles = Set(library.map { $0.title.lowercased() })
        var votes: [String: (related: RelatedTitle, seeds: [Franchise])] = [:]
        for f in library where f.effectiveStatus != .dropped {
            for r in f.related {
                if let id = r.franchiseId, owned.contains(id) { continue }
                if ownedTitles.contains(r.title.lowercased()) { continue }
                let key = "\(r.source.rawValue):\(r.externalId)"
                var entry = votes[key] ?? (r, [])
                entry.seeds.append(f)
                votes[key] = entry
            }
        }
        let ranked = votes.sorted { a, b in
            if a.value.seeds.count != b.value.seeds.count { return a.value.seeds.count > b.value.seeds.count }
            return a.key < b.key
        }
        return ranked.prefix(limit).enumerated().compactMap { index, element in
            let (key, entry) = element
            let seeds = entry.seeds.prefix(2).map { ["franchiseId": $0.id, "title": $0.displayTitle] }
            let first = entry.seeds.first
            let kind: String = entry.seeds.count > 1 ? "consensus"
                : (first?.effectiveStatus == .completed ? "finished"
                   : first?.effectiveStatus == .watching ? "watching" : "planned")
            var dict: [String: Any] = [
                "key": key, "source": entry.related.source.rawValue, "externalId": entry.related.externalId,
                // One title on air, so the tile's "AIRING" tag can be photographed.
                "title": entry.related.title, "airing": index == 1, "genres": [], "score": Double(entry.seeds.count),
                "reason": ["kind": kind, "seeds": seeds, "count": entry.seeds.count],
            ]
            if let id = entry.related.franchiseId { dict["franchiseId"] = id }
            if let y = entry.related.year { dict["year"] = y }
            if let images = entry.related.images, let data = try? JSONEncoder().encode(images),
               let object = try? JSONSerialization.jsonObject(with: data) { dict["images"] = object }
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(RecommendationItem.self, from: data)
        }
    }
}
#endif
