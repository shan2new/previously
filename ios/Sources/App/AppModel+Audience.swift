import SwiftUI

// What the viewer watches — anime, TV, or both (4 Oct 2026).
//
// "TV-first folks don't have any interest in anime. Anime folks could echo the same. We are forcing
// 2 different audiences to see each other's suggestions. We need a user flag … that does a clean
// segregation so that this contract is not violated across our application" (owner).
//
// THE CONTRACT: everything the app SUGGESTS — For you, Suggested, Trending, Discover's shelves and
// genres, Search and its launchpad — is of the viewer's kind and nothing else. What they OWN is
// never hidden: the library, Home, Schedule and Following are their shows, whatever kind they are.
//
// It is the account's (`GET` / `PUT /me/preferences`, `audience`), so the server composes For you
// and the recommendations for it and defaults every catalogue route to it; the app keeps the same
// wall itself (`Audience.allows`) — against a response cached before the choice, an older server,
// or one whose answer has not caught up. A catalogue title is one kind or the other and never
// both (`Franchise.source`), which is what makes the wall clean.
//
// The app has had ONE Anime/TV scope for Discover and Search since August (`AppModel.mediaFilter`).
// A single audience fixes that scope: there is no All to return to and no control that offers one.

enum Audience: String, Codable, CaseIterable, Sendable {
    case anime, tv, both

    /// The scope this audience fixes Discover and Search to.
    var filter: MediaFilter {
        switch self {
        case .anime: .anime
        case .tv: .tv
        case .both: .all
        }
    }

    /// One kind only: the scope is fixed and every control that changes it is gone.
    var isSingle: Bool { self != .both }

    /// A suggestion from this catalogue may be shown.
    func allows(_ source: MediaSource) -> Bool {
        switch self {
        case .anime: source == .anilist
        case .tv: source == .tmdb
        case .both: true
        }
    }

    // MARK: The device's copy

    /// The account's choice as this device last knew it, so the first frame is already the
    /// viewer's — a launch must not open on the other audience's Trending and then correct itself.
    private struct LocalState: Codable { var choice: Audience?; var pending = false }

    @MainActor private static var state: LocalState {
        get {
            AccountLocalStore.shared.read("audience.json", owner: AccountLocalStore.shared.current)
                .flatMap { try? JSONDecoder().decode(LocalState.self, from: $0) } ?? LocalState()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            try? AccountLocalStore.shared.write(data, name: "audience.json", owner: AccountLocalStore.shared.current)
        }
    }

    @MainActor static var stored: Audience { state.choice ?? .both }
    @MainActor static var storedChosen: Bool { state.choice != nil }

    /// A choice made here that the server has not confirmed (offline, or unreachable).
    @MainActor static var pending: Bool {
        get { state.pending }
        set { var next = state; next.pending = newValue; state = next }
    }

    @MainActor
    static func store(_ value: Audience?) {
        if let value {
            var next = state
            next.choice = value
            state = next
        } else {
            AccountLocalStore.shared.remove("audience.json", owner: AccountLocalStore.shared.current)
        }
        // Discover's genre art leans the same way (`GenreArt.leaningKey`): illustration for anime,
        // photographs for TV. Both keeps whatever it last leaned to.
        if let value, value.isSingle {
            UserDefaults.standard.set(value == .tv ? GenreArt.Flavour.tv.rawValue : GenreArt.Flavour.anime.rawValue,
                                      forKey: GenreArt.leaningKey)
        }
    }
}

extension AppModel {
    /// The viewer's choice. Takes effect at once, everywhere: the scope is fixed, the lists already
    /// on screen lose the other kind, and For you, the recommendations and the chart are asked for
    /// again. The write is the account's; a failure keeps the choice here and retries
    /// (`syncAudience`) — the wall never waits for the network.
    func setAudience(_ value: Audience, announce: Bool = true) {
        let changed = value != audience || !audienceChosen
        audience = value
        audienceChosen = true
        audiencePromptDue = false
        Audience.store(value)
        Audience.pending = true
        applyAudience()
        guard changed else { return }
        if announce {
            FeedbackCoordinator.fire(.selection)
            showNotice(Copy.Watching.receipt(value))
        }
        Task { [weak self] in
            await self?.pushAudience()
            await self?.refreshForAudience()
        }
    }

    /// What follows from the audience, with no network: the one scope, and the lists in hand.
    private func applyAudience() {
        let filter = audience.filter
        if mediaFilter != filter { mediaFilter = filter }
        let chart = trending.filter { audience.allows($0.source) }
        if chart.count != trending.count { trending = chart }
        let results = searchResults.filter { audience.allows($0.source) }
        if results.count != searchResults.count { searchResults = results }
    }

    /// Everything composed for an audience, asked for again.
    private func refreshForAudience() async {
        refreshRecommendationsIfNeeded(force: true)
        await refreshTrending()
        await refreshFeed(.forYou)
    }

    private func pushAudience() async {
        guard !erasing else { return }
        let epoch = accountEpoch
        let owner = accountStorage
        let value = audience
        do {
            try await api.saveAudience(value)
            guard epoch == accountEpoch, !erasing, AccountLocalStore.shared.matches(owner) else { return }
            // Still the viewer's last word (they may have changed it while this was in flight).
            if value == audience { Audience.pending = false }
        } catch {
            // Kept here and sent again at the next launch or reconnect; nothing to say — the app
            // already behaves as chosen.
        }
    }

    /// At launch and on reconnect: a choice this device still owes the server is sent; otherwise
    /// the account's answer is adopted (it may have been changed on another device). An account
    /// that has never answered is asked, once.
    func syncAudience() async {
        guard !erasing else { return }
        if Audience.pending {
            await pushAudience()
            return
        }
        let epoch = accountEpoch
        let answer: Audience?
        do { answer = try await api.audience() } catch { return }
        guard epoch == accountEpoch else { return }
        if let answer {
            let changed = answer != audience
            audience = answer
            audienceChosen = true
            Audience.store(answer)
            applyAudience()
            if changed { await refreshForAudience() }
        } else if audienceChosen {
            // The server has no answer but this device does (chosen before the server could keep
            // it): the device's stands, and is sent.
            Audience.pending = true
            await pushAudience()
        } else {
            audiencePromptDue = true
        }
    }

    /// The choice to offer first: what the library already says — all anime, all TV — else both.
    var suggestedAudience: Audience {
        guard audienceChosen == false, !library.isEmpty else { return audience }
        if library.allSatisfy({ $0.source == .anilist }) { return .anime }
        if library.allSatisfy({ $0.source == .tmdb }) { return .tv }
        return .both
    }

    /// Sign-out: the next account answers for itself.
    func clearAudience() {
        Audience.store(nil)
        audience = .both
        audienceChosen = false
        audiencePromptDue = false
        mediaFilter = .all
    }
}
