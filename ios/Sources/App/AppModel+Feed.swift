import Foundation

// The Today feed — the model half (spec §1.6.2). It loads the two tabs from `GET /me/feed`,
// keeps an offline copy, memoises the rows the list draws and the stories the tray draws, and
// loads post pages. The server composes posts; this file never re-ranks, re-dates or invents one.
//
// The rules that shape it:
//   • the feed waits for the visit stamp (iD3) — `fresh` is ordered against `prev_opened_at`;
//   • an offline copy renders with no fresh marks (iD2);
//   • a 404 is an older server: a degraded feed, never a blank Today (iD8);
//   • composition runs in the memo, never in a body (§1.6.3).

/// The memo behind the feed's rows and stories (spec §1.6.3). Read through `feedRows(_:)`,
/// `freshPosts(_:)`, `storyReels` and `feedPost(id:)` only.
final class FeedDerivedCache {
    struct Key: Equatable {
        let tab: FeedTab
        let feed: Int            // feedVersion
        let library: Int         // libraryVersion (ownership, library copies for art)
        let minute: Int64        // nowMinute (stamps "2h", premiere words)
        let prevOpenedAt: Int64
        let recs: [String]       // visibleRecommendations.map(\.key)
        let trending: Int        // appModel.trending.count (empty-account module)
        let online: Bool         // SyncCenter.shared.isOnline (the offline notice)
        let hides: Int           // hidesVersion (mutes and hides from anywhere)
        let audience: Audience   // the viewer's kind (For you and its modules are held to it)
    }
    var rows: [FeedTab: (key: Key, rows: [FeedRow])] = [:]
    /// The fresh post models of a tab's current rows (the new-posts pill).
    var fresh: [FeedTab: [FeedPostModel]] = [:]
    var stories: (key: StoriesKey, value: [StoryReel])?
    /// Post id → model for the current rows of every composed tab (`feedPost(id:)`).
    var models: [String: FeedPostModel] = [:]
    var tabModels: [FeedTab: [String: FeedPostModel]] = [:]
}

/// What the story tray is derived from: the library, the minute and the path's cost. Not the mutes:
/// a reel is a library fact (the user's own episode), and a mute silences a show's NEWS only.
struct StoriesKey: Equatable {
    let library: Int
    let minute: Int64
    let constrained: Bool
}

/// The feed's offline copy (`Application Support/feed-cache.json`). Version 1; any other version
/// is ignored rather than half-read.
struct FeedCacheFile: Codable, Sendable {
    var version = 1
    var savedAt: Int64
    var following: FeedResponse?
    var forYou: FeedResponse?
    /// `GET /me/reminders`, as two lists (the response type has no memberwise initialiser).
    var reminderItems: [ReminderItem]?
    var reminderFranchises: [FeedFranchise]?
    var mutedShowIds: [String]
    var hiddenPostIds: [String]
    var storyViewed: [String: Int64]
    var activityUnread: Int
    var capabilities: FeedCapabilities
}

extension AppModel {
    /// A tab is re-fetched on a non-forced ask only after this long.
    nonisolated static let feedStaleAfter: Int64 = 2 * Formatting.minuteMs
    /// Post pages kept in memory.
    nonisolated static let postDetailLimit = 30

    // MARK: - Loading

    /// Loads one tab. Unless `force`, skipped while that tab is already loading and when a live
    /// response is under two minutes old. A forced load SUPERSEDES one in flight — the load that
    /// follows the visit stamp must win over any asked for before it (iD3). A superseded answer (a
    /// newer load, a sign-out) is dropped.
    func loadFeed(_ tab: FeedTab, force: Bool = false) async {
        // Not during an account deletion: a read upserts the account it names (`prepareForErasure`).
        guard !isIsolated, !erasing else { return }
        var state = feedTabs[tab] ?? FeedTabState()
        if state.loading && !force { return }
        if !force, (state.response != nil && !state.fromCache) || state.unavailable,
           Int64.nowMs - state.loadedAt < Self.feedStaleAfter { return }
        let seq = (feedSeq[tab] ?? 0) &+ 1
        feedSeq[tab] = seq
        let epoch = accountEpoch
        state.loading = true
        feedTabs[tab] = state
        do {
            // Once this session's stamp has landed, its answer IS the anchor: the server's stored
            // one is the visit before last while the stamp is missing, and another device's stamp
            // moves it mid-session. Before that, the server reads its own.
            let res = try await api.feed(tab: tab, since: visitStamped && prevOpenedAt > 0 ? prevOpenedAt : nil)
            guard feedSeq[tab] == seq, epoch == accountEpoch else { return }
            let alertsBefore = reminderAlerts(now: .nowMs).map(\.postId)
            feedTabs[tab] = FeedTabState(response: res, fromCache: false, loadedAt: .nowMs)
            feedLiveLoaded.insert("capabilities")
            if feedCapabilities != res.capabilities { feedCapabilities = res.capabilities }
            // Provisional only: once the visit stamp has answered, no response moves the anchor.
            if !visitStamped, res.prevOpenedAt > 0 { prevOpenedAt = res.prevOpenedAt }
            ingestSocial(res.posts)
            feedVersion &+= 1
            scheduleFeedCacheWrite()
            flushSocial()
            // A reminded dated post that arrived (or left) re-arms the local alerts.
            if reminderAlerts(now: .nowMs).map(\.postId) != alertsBefore { await syncAmbient() }
        } catch {
            guard feedSeq[tab] == seq, epoch == accountEpoch else { return }
            var failed = feedTabs[tab] ?? FeedTabState()
            failed.loading = false
            if error.isCancellation {
                feedTabs[tab] = failed
                return
            }
            if let api = error as? APIError {
                switch api {
                case .http(404, _):
                    // A server that predates `/me/feed` (iD8): the degraded feed, not an error.
                    failed.unavailable = true
                    failed.failed = false
                    failed.loadedAt = .nowMs
                case .suspended:
                    accountSuspended = true
                    failed.failed = true
                case .unauthorized:
                    feedTabs[tab] = failed
                    handleSessionExpired()
                    return
                default:
                    failed.failed = true
                }
            } else {
                failed.failed = true
            }
            feedTabs[tab] = failed
            feedVersion &+= 1
            if !failed.unavailable {
                AppModel.log.error("feed \(tab.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The pull: the library, the tab, Activity, the reminders and the hides, together.
    func refreshFeed(_ tab: FeedTab) async {
        async let shows: Void = reload()
        async let posts: Void = loadFeed(tab, force: true)
        async let bell: Void = loadActivity(reset: true)
        async let reminded: Void = loadReminders()
        async let hidden = loadHides()
        _ = await (shows, posts, bell, reminded, hidden)
    }

    // MARK: - Offline copy

    /// The last feed this device saw, decoded OFF the main actor (the library cache's pattern), and
    /// applied only where nothing live has landed yet. Every post in it is non-fresh (iD2).
    func loadCachedFeed() {
        guard !isIsolated, let owner = accountStorage else { return }
        let epoch = accountEpoch
        Task { [weak self] in
            let url = owner.file("feed-cache.json")
            let cached = await Task.detached(priority: .userInitiated) { () -> FeedCacheFile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(FeedCacheFile.self, from: data)
            }.value
            // A sign-out (the epoch moved) or an account deletion under way while the copy was
            // decoding: it is the previous account's feed, hides and reminders — never applied.
            guard let self, let cached, cached.version == 1, epoch == self.accountEpoch,
                  !self.erasing, AccountLocalStore.shared.matches(owner) else { return }
            self.applyCachedFeed(cached)
        }
    }

    private func applyCachedFeed(_ cached: FeedCacheFile) {
        var applied = false
        for (tab, response) in [(FeedTab.following, cached.following), (.forYou, cached.forYou)] {
            guard let response else { continue }
            var state = feedTabs[tab] ?? FeedTabState()
            guard state.response == nil else { continue }
            state.response = response.asCached()
            state.fromCache = true
            state.loadedAt = cached.savedAt
            feedTabs[tab] = state
            applied = true
            // Live counts win: a subject a live response already carried keeps its values.
            var base = socialBase
            for post in response.posts where base[post.id] == nil {
                base[post.id] = SubjectSocial(post)
            }
            if base.count != socialBase.count { socialBase = base }
        }
        if !feedLiveLoaded.contains("hides") {
            serverMutedShowIds = Set(cached.mutedShowIds)
            serverHiddenPostIds = Set(cached.hiddenPostIds)
            hidesVersion &+= 1
            applied = true
        }
        var viewed = storyViewed
        for (id, at) in cached.storyViewed where at > (viewed[id] ?? 0) { viewed[id] = at }
        if viewed != storyViewed { storyViewed = viewed }
        if !feedLiveLoaded.contains("activity") { activityUnread = cached.activityUnread }
        if !feedLiveLoaded.contains("reminders"), let items = cached.reminderItems {
            reminderItems = items
            reminderFranchises = Dictionary((cached.reminderFranchises ?? []).map { ($0.id, $0) },
                                            uniquingKeysWith: { a, _ in a })
            var base = socialBase
            for item in items where base[item.postId] == nil {
                base[item.postId] = item.post.map { SubjectSocial($0) } ?? SubjectSocial(reminded: true)
            }
            if base.count != socialBase.count { socialBase = base }
        }
        if !feedLiveLoaded.contains("capabilities"), feedCapabilities != cached.capabilities {
            feedCapabilities = cached.capabilities
            applied = true
        }
        if applied { feedVersion &+= 1 }
    }

    /// Debounced 1 s; the final atomic write is serialized with teardown. Called after every
    /// successful feed, reminders, hides or Activity load and every `markViewed`.
    func scheduleFeedCacheWrite() {
        guard !isIsolated, !erasing, let owner = accountStorage else { return }
        feedCacheWrite?.cancel()
        let epoch = accountEpoch
        feedCacheWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, epoch == self.accountEpoch, !self.erasing,
                  AccountLocalStore.shared.matches(owner) else { return }
            guard let file = self.makeFeedCacheFile() else { return }
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? AccountLocalStore.shared.write(data, name: "feed-cache.json", owner: owner)
        }
    }

    private func makeFeedCacheFile() -> FeedCacheFile? {
        let following = feedTabs[.following]?.response
        let forYou = feedTabs[.forYou]?.response
        guard following != nil || forYou != nil || !reminderItems.isEmpty || !storyViewed.isEmpty else { return nil }
        return FeedCacheFile(savedAt: .nowMs, following: following, forYou: forYou,
                             reminderItems: reminderItems, reminderFranchises: Array(reminderFranchises.values),
                             mutedShowIds: Array(serverMutedShowIds), hiddenPostIds: Array(serverHiddenPostIds),
                             storyViewed: storyViewed, activityUnread: activityUnread,
                             capabilities: feedCapabilities)
    }

    // MARK: - Derived (memoised, never computed in a body)

    /// The rows one tab draws. A body reads this and nothing else of the feed; a warm key returns
    /// the rows it composed last time without touching a post.
    func feedRows(_ tab: FeedTab) -> [FeedRow] {
        // Read once each, so a body that reads only `feedRows` still observes what they come from.
        let state = feedTabs[tab] ?? FeedTabState()
        let libraryCopies = library
        let minute = nowMinute
        let prev = prevOpenedAt
        let recs = visibleRecommendations.map(\.key)
        let chart = trending
        let folds = feedFolds
        let online = SyncCenter.shared.isOnline
        let kind = audience
        let key = FeedDerivedCache.Key(tab: tab, feed: feedVersion, library: libraryVersion, minute: minute,
                                       prevOpenedAt: prev, recs: recs, trending: chart.count, online: online,
                                       hides: hidesVersion, audience: kind)
        if let hit = feedDerived.rows[tab], hit.key == key { return hit.rows }

        let untracked = Array(chart.filter { !isInLibrary($0.id) && kind.allows($0.source) }
            .prefix(FeedComposer.maxTrending))
        let rows = FeedComposer.rows(
            tab: tab, state: state, library: libraryCopies, libraryIndex: { self.franchise(id: $0) },
            now: minute, folds: folds,
            hidden: hiddenPostIds, muted: mutedShowIds, recommendationKeys: recs,
            untrackedTrending: untracked, libraryEmpty: libraryCopies.isEmpty, online: online,
            allows: { kind.allows($0) })

        var models: [String: FeedPostModel] = [:]
        var fresh: [FeedPostModel] = []
        for row in rows {
            guard case .post(let m) = row else { continue }
            models[m.id] = m
            if m.fresh { fresh.append(m) }
        }
        feedDerived.rows[tab] = (key, rows)
        feedDerived.fresh[tab] = tab == .following ? fresh : []
        feedDerived.tabModels[tab] = models
        feedDerived.models = feedDerived.tabModels.values.reduce(into: [:]) { all, next in
            all.merge(next) { current, _ in current }
        }
        return rows
    }

    /// What the tab's body renders: skeleton, a no-cache error, or content.
    func feedPhase(_ tab: FeedTab) -> FeedSurfacePhase {
        let state = feedTabs[tab] ?? FeedTabState()
        guard state.response != nil || state.unavailable else {
            if state.loading || (state.loadedAt == 0 && !state.failed) { return .loading }
            return .errorNoCache(offline: !SyncCenter.shared.isOnline)
        }
        // The library is still arriving and the feed has nothing of its own to show: holding the
        // skeleton beats flashing the empty account for the second before the shows land.
        if tab == .following, library.isEmpty, loading, state.response?.posts.isEmpty ?? true {
            return .loading
        }
        return .content(refreshing: state.loading)
    }

    /// The fresh posts of Following — the new-posts pill's faces and count. `[]` for For you.
    func freshPosts(_ tab: FeedTab) -> [FeedPostModel] {
        guard tab == .following else { return [] }
        _ = feedRows(tab)
        return feedDerived.fresh[tab] ?? []
    }

    /// The stories tray: one reel per library show with a fresh drop (`StoryReel.build`), memoised
    /// on the library, the minute and whether the path is constrained (a muted show keeps its reel).
    var storyReels: [StoryReel] {
        let constrained = SyncCenter.shared.isConstrained || SyncCenter.shared.isExpensive
        let shows = library
        let key = StoriesKey(library: libraryVersion, minute: nowMinute, constrained: constrained)
        if let hit = feedDerived.stories, hit.key == key { return hit.value }
        // The wall clock at composition (not the observed `now`: the key already turns on the minute).
        let reels = StoryReel.build(library: shows, now: .nowMs, constrained: constrained)
        feedDerived.stories = (key, reels)
        return reels
    }

    /// The reels the tray shows: only the ones still to be SEEN. A story is an alert that a new
    /// episode is out, so a reel leaves once its latest drop has been viewed or watched, and comes
    /// back only when a newer episode airs (`hasViewed` compares against `latestAired`). An empty
    /// tray is the normal state — something to wait for, not a row of grey rings.
    var trayReels: [StoryReel] {
        storyReels.filter { !$0.seen && !hasViewed($0) }
    }

    /// A post already composed: from the loaded tabs' rows, else a loaded post page.
    func feedPost(id: String) -> FeedPostModel? {
        for tab in FeedTab.allCases where feedTabs[tab]?.response != nil {
            _ = feedRows(tab)
            if let m = feedDerived.tabModels[tab]?[id] { return m }
        }
        return postDetails[id]?.model
    }

    /// The franchise a post belongs to, from whatever has it loaded (feed tabs, post pages,
    /// reminders) — for the Undo of a mute and for folds.
    func franchiseIdOfPost(_ postId: String) -> String? {
        for state in feedTabs.values {
            if let p = state.response?.posts.first(where: { $0.id == postId }) { return p.franchiseId }
        }
        if let d = postDetails[postId]?.detail { return d.post.franchiseId }
        if let r = reminderItems.first(where: { $0.postId == postId })?.post { return r.franchiseId }
        return nil
    }

    // MARK: - Post page

    /// `GET /feed/posts/:id`. A cached page shows at once; this refreshes it. The detail is stored
    /// under the id asked for AND the canonical id (an adopted `catalog:` alias, server §2.7), and
    /// at most `postDetailLimit` pages are kept (the least recently loaded leaves first).
    func loadPostDetail(_ id: String, force: Bool = false) async {
        guard !isIsolated else { return }
        var state = postDetails[id] ?? PostDetailState()
        if state.loading { return }
        if !force, state.detail != nil, Int64.nowMs - (postDetailLoadedAt[id] ?? 0) < Self.feedStaleAfter / 2 { return }
        let epoch = accountEpoch
        state.loading = true
        state.failed = false
        postDetails[id] = state
        do {
            let detail = try await api.feedPost(id: id)
            guard epoch == accountEpoch else { return }
            let fid = detail.post.franchiseId
            let copy = franchise(id: fid)
            let model = FeedComposer.model(detail.post, show: detail.franchise, library: copy,
                                           owned: isInLibrary(fid), now: now, fresh: false)
            let landed = PostDetailState(detail: detail, model: model, loading: false, notFound: false, failed: false)
            var pages = postDetails
            pages[id] = landed
            pages[detail.post.id] = landed
            let stamp: Int64 = .nowMs
            postDetailLoadedAt[id] = stamp
            postDetailLoadedAt[detail.post.id] = stamp
            // LRU: the least recently loaded pages leave first.
            if postDetailLoadedAt.count > Self.postDetailLimit {
                let evict = postDetailLoadedAt.sorted { $0.value < $1.value }
                    .prefix(postDetailLoadedAt.count - Self.postDetailLimit).map(\.key)
                for key in evict where key != id && key != detail.post.id {
                    postDetailLoadedAt[key] = nil
                    pages[key] = nil
                }
            }
            postDetails = pages
            ingestSocial([detail.post])
            feedLiveLoaded.insert("capabilities")
            if feedCapabilities != detail.capabilities {
                feedCapabilities = detail.capabilities
                feedVersion &+= 1
            }
        } catch {
            guard epoch == accountEpoch else { return }
            var failed = postDetails[id] ?? PostDetailState()
            failed.loading = false
            if error.isCancellation {
                postDetails[id] = failed
                return
            }
            if let api = error as? APIError {
                switch api {
                case .http(404, _):
                    // Updated or removed — or an adopted `catalog:` id (server §13.12). The page
                    // offers the show when it is known (`ThreadSubject.catalogMediaId`).
                    failed.notFound = true
                case .suspended:
                    accountSuspended = true
                    failed.failed = true
                case .unauthorized:
                    postDetails[id] = failed
                    handleSessionExpired()
                    return
                default:
                    failed.failed = true
                }
            } else {
                failed.failed = true
            }
            postDetails[id] = failed
        }
    }

    // MARK: - Stories

    /// A reel is seen once its latest drop has been viewed.
    func hasViewed(_ reel: StoryReel) -> Bool {
        (storyViewed[reel.id] ?? 0) >= reel.latestAired
    }

    func markViewed(_ reel: StoryReel) {
        guard (storyViewed[reel.id] ?? 0) < reel.latestAired else { return }
        storyViewed[reel.id] = reel.latestAired
        scheduleFeedCacheWrite()
    }

    // MARK: - Social ingest

    /// Server truth for each post, from the response that carried it. A pending toggle keeps its
    /// overlay on top, unchanged. One assignment, so observers see one change, not one per post.
    func ingestSocial(_ posts: [FeedPost]) {
        guard !posts.isEmpty else { return }
        var base = socialBase
        var changed = false
        for post in posts {
            let next = SubjectSocial(post)
            if base[post.id] != next {
                base[post.id] = next
                changed = true
            }
        }
        if changed { socialBase = base }
    }

    // MARK: - Teardown

    /// Everything the feed and the social layer hold for this account — in memory and on disk
    /// (spec §1.6.1 item 7). Called from `teardown()`.
    func clearFeedAndSocial() {
        socialLanes.values.forEach { $0.cancel() }
        socialLanes = [:]
        ratingLanes.values.forEach { $0.cancel() }
        ratingLanes = [:]
        feedCacheWrite?.cancel(); feedCacheWrite = nil
        socialPersistWrite?.cancel(); socialPersistWrite = nil
        for tab in FeedTab.allCases { feedSeq[tab] = (feedSeq[tab] ?? 0) &+ 1 }
        for key in threadSeq.keys { threadSeq[key] = (threadSeq[key] ?? 0) &+ 1 }
        activitySeq &+= 1

        feedTabs = [:]
        currentFeedTab = .following
        feedCapabilities = FeedCapabilities(comments: false)
        postDetails = [:]
        postDetailLoadedAt = [:]
        socialBase = [:]
        socialPending = [:]
        socialPendingRestoreFailed = false
        pendingRatings = [:]
        episodeRooms = [:]
        threads = [:]
        pendingComments = []
        commentsInFlight = []
        blockedSessionIds = []
        socialProfile = nil
        serverMutedShowIds = []
        serverHiddenPostIds = []
        feedFolds = [:]
        reminderPrimerPostId = nil
        reminderItems = []
        reminderFranchises = [:]
        activity = []
        activityUnread = 0
        activityCursor = nil
        activityLoading = false
        activityFailed = false
        storyViewed = [:]
        feedOverlayOpen = false
        accountSuspended = false
        feedLiveLoaded = []
        feedVersion &+= 1
        hidesVersion &+= 1
        feedDerived = FeedDerivedCache()

        AccountLocalStore.shared.remove("feed-cache.json", owner: accountStorage)
        AccountLocalStore.shared.remove("social-pending.json", owner: accountStorage)
        SubjectCrop.shared.clear()
        // The retired recap's per-account keys (RecapDigest.swift), so an old install signed out
        // carries nothing of the previous account.
        UserDefaults.standard.removeObject(forKey: "recap.acknowledgedDigestID")
        UserDefaults.standard.removeObject(forKey: "recap.lastFullRecapAt")
    }
}

extension SubjectSocial {
    /// A post's social facts as the server sent them.
    init(_ post: FeedPost) {
        self.init(liked: post.viewer.liked, likes: post.counts.likes, saved: post.viewer.saved,
                  reminded: post.viewer.reminded, comments: post.counts.comments)
    }
}
