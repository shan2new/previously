import SwiftUI
import UserNotifications

// The social layer — the model half (spec §1.6.4, §4.2–§4.6). Every social view calls one method
// here and reads one overlay; none of them talks to the API.
//
// The write rules, which differ from the library's on purpose:
//   • TOGGLES (like, save, remind, hide, mute, comment like, block) are optimistic, newest word
//     wins, persisted across launches and self-healing: one lane per toggle sends the last word
//     and a failure is never a toast or a Sync status row (the recommendations-feedback precedent);
//   • RATINGS are the same shape, keyed "m:e";
//   • COMMENTS are content: a pending row the thread draws, and on a transport failure a
//     SyncCenter row with a `WriteIntent` that replays the same client id from any launch.
// Haptics: `.selection` on the way ON for like, save, remind and a comment like (iD21) and when a
// rating is set; OFF is silent. A view never adds one on top.

/// Where the composer stands (spec §4.5 step 1). Terms come first, then identity.
enum ComposeGate: Equatable { case disabled, loading, needsTerms, needsIdentity, ready }

/// What a send did. The composer keeps the draft for everything but `.sent` and `.queued`.
enum SendOutcome: Equatable {
    case sent(SocialComment)
    /// Offline or a transport failure: the thread's pending row and a SyncCenter row carry it.
    case queued
    /// The composer steps back into its gate.
    case needsTerms, needsIdentity
    /// A `ContentRejection` raw value ("link", "too_long", …) — the draft is kept.
    case rejected(String)
    /// `.unwatched` / `.unaired`, after the one progress replay.
    case locked(EpisodeAccess)
    case rateLimited(seconds: Int)
    /// Comments are switched off (404 `comments disabled`).
    case disabled
    /// 404 subject/parent, 410 deleted on replay.
    case gone
}

enum SocialFailure: Error, Equatable {
    case handleTaken, invalidHandle(String), invalidDisplayName(String), termsVersionMismatch(String)
    case rateLimited(Int), offline, server
}

/// Saved, composed: a row per saved post; `model` is nil for a post the server can no longer
/// compose (the quiet "no longer available" row).
struct SavedPostsModel {
    let items: [(item: SavedItem, model: FeedPostModel?)]
}

/// `Application Support/social-pending.json`: the toggles, ratings and replies the server has not
/// confirmed. Deleted on sign-out.
struct SocialPendingFile: Codable, Sendable {
    struct Toggle: Codable, Sendable {
        let key: SocialToggleKey
        let write: SocialToggleWrite
    }
    var version = 1
    var toggles: [Toggle]
    var ratings: [PendingRating]
    var comments: [PendingComment]
}

/// How a social write failed, decided once for every lane.
enum SocialWriteFailure: Equatable {
    /// 400, 404, 409, 410, 422 — the server will never accept this word: revert.
    case final
    case rateLimited(Int)
    /// Transport, 5xx, infrastructure: kept; the next trigger retries.
    case transient
    case suspended
    case unauthorized

    init(_ error: Error) {
        guard let api = error as? APIError else { self = .transient; return }
        switch api {
        case .suspended: self = .suspended
        case .unauthorized: self = .unauthorized
        case .rateLimited(let after): self = .rateLimited(max(1, Int((after ?? 60).rounded(.up))))
        case .http(let code, _):
            if code == 429 { self = .rateLimited(60) }
            else if (400..<500).contains(code) { self = .final }
            else { self = .transient }
        default: self = .transient
        }
    }
}

extension AppModel {
    // MARK: - Overlay reads (server base under the pending word)

    func isLiked(_ subject: String) -> Bool {
        socialPending[SocialToggleKey(kind: .like, target: subject)]?.on ?? socialBase[subject]?.liked ?? false
    }

    func likeCount(_ subject: String) -> Int {
        let base = socialBase[subject] ?? SubjectSocial()
        guard let pending = socialPending[SocialToggleKey(kind: .like, target: subject)] else { return base.likes }
        return max(0, base.likes + (pending.on ? 1 : 0) - (base.liked ? 1 : 0))
    }

    /// The server's count; a sent reply adds one and a deleted own reply takes one away until the
    /// next response says otherwise.
    func commentCount(_ subject: String) -> Int { socialBase[subject]?.comments ?? 0 }

    func isSaved(_ postId: String) -> Bool {
        socialPending[SocialToggleKey(kind: .save, target: postId)]?.on ?? socialBase[postId]?.saved ?? false
    }

    func isReminded(_ postId: String) -> Bool {
        socialPending[SocialToggleKey(kind: .remind, target: postId)]?.on ?? socialBase[postId]?.reminded ?? false
    }

    /// Server ∪ pending ON − pending OFF.
    var mutedShowIds: Set<String> { overlaid(serverMutedShowIds, kind: .muteShow) }

    /// Server ∪ pending ON − pending OFF.
    var hiddenPostIds: Set<String> { overlaid(serverHiddenPostIds, kind: .hidePost) }

    private func overlaid(_ server: Set<String>, kind: SocialToggleKind) -> Set<String> {
        var ids = server
        for (key, write) in socialPending where key.kind == kind {
            if write.on { ids.insert(key.target) } else { ids.remove(key.target) }
        }
        return ids
    }

    func fold(for postId: String) -> FeedFold? { feedFolds[postId] }

    func isCommentLiked(_ c: SocialComment) -> Bool {
        socialPending[SocialToggleKey(kind: .commentLike, target: c.id)]?.on
            ?? socialBase[Self.commentKey(c.id)]?.liked ?? c.liked
    }

    func commentLikeCount(_ c: SocialComment) -> Int {
        let base = socialBase[Self.commentKey(c.id)] ?? SubjectSocial(liked: c.liked, likes: c.likeCount)
        guard let pending = socialPending[SocialToggleKey(kind: .commentLike, target: c.id)] else { return base.likes }
        return max(0, base.likes + (pending.on ? 1 : 0) - (base.liked ? 1 : 0))
    }

    /// A reply's social base lives beside the subjects', keyed `c:<commentId>`.
    nonisolated static func commentKey(_ id: String) -> String { "c:\(id)" }

    // MARK: - Toggles (§4.3)

    func toggleLike(_ subject: String, franchiseId: String) {
        let desired = !isLiked(subject)
        enqueueToggle(SocialToggleKey(kind: .like, target: subject), on: desired, franchiseId: franchiseId)
        if desired { FeedbackCoordinator.fire(.selection) }
    }

    /// Like only — the media's double tap and its named "Like" action (Instagram's double tap never
    /// takes a like back). A no-op on a post already liked.
    func like(_ subject: String, franchiseId: String) {
        guard !isLiked(subject) else { return }
        toggleLike(subject, franchiseId: franchiseId)
    }

    func toggleSave(_ post: FeedPostModel) {
        let desired = !isSaved(post.id)
        enqueueToggle(SocialToggleKey(kind: .save, target: post.id), on: desired, franchiseId: post.post.franchiseId)
        if desired {
            FeedbackCoordinator.fire(.selection)
            // Saved lives only in Profile; the receipt says where (iD6).
            showNotice(Copy.Feed.savedNotice)
        }
    }

    /// Saved's own rows (a post the server can no longer compose has no model to toggle).
    func setSaved(_ on: Bool, postId: String, franchiseId: String?) {
        guard on != isSaved(postId) else { return }
        enqueueToggle(SocialToggleKey(kind: .save, target: postId), on: on, franchiseId: franchiseId)
        if on { FeedbackCoordinator.fire(.selection) }
    }

    /// Remind me (§4.4). A dated future premiere arms a local alert — said only once it is real;
    /// without permission the post draws the primer line and the tap never raises the system ask.
    func toggleRemind(_ post: FeedPostModel) {
        let id = post.id
        let desired = !isReminded(id)
        enqueueToggle(SocialToggleKey(kind: .remind, target: id), on: desired, franchiseId: post.post.franchiseId)
        guard desired else {
            if reminderPrimerPostId == id { reminderPrimerPostId = nil }
            Task { await syncAmbient() }
            return
        }
        FeedbackCoordinator.fire(.selection)
        let alert = post.post.premiere.map {
            ReminderAlert(postId: id, franchiseId: post.post.franchiseId, title: post.showName,
                          installment: post.post.installment, mediaId: post.post.part?.mediaId,
                          at: $0.at, dateOnly: $0.precision == .dateOnly)
        }
        guard let alert, let premiere = post.post.premiere,
              !TemporalCopy.premiereHasPassed(premiere.at, anchor: premiere.anchor, now: .nowMs),
              let fires = EpisodeNotifications.fireTime(for: alert), fires > Int64.nowMs else {
            // Undated (window, announced, rumour, a trailer with no slot) or already past: nothing
            // is scheduled here — the server tells reminder holders in Activity when it firms up.
            showNotice(Copy.Feed.reminderSetUndated)
            return
        }
        Task { [weak self] in
            let status = await EpisodeNotifications.shared.authorizationStatus()
            guard let self, self.isReminded(id) else { return }
            switch status {
            case .authorized, .provisional, .ephemeral:
                await self.syncAmbient()
                self.showNotice(Copy.Feed.reminderSetFor(
                    Formatting.formatted(premiere.at, skeleton: "EEEdMMM", anchor: premiere.anchor)))
            default:
                self.reminderPrimerPostId = id
            }
        }
    }

    /// "Not interested": the post folds in place into "Thanks · Undo".
    func hidePost(_ post: FeedPostModel) {
        let reduce = UIAccessibility.isReduceMotionEnabled
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduce)) {
            feedFolds[post.id] = .notInterested
        }
        enqueueToggle(SocialToggleKey(kind: .hidePost, target: post.id), on: true, franchiseId: post.post.franchiseId)
        feedVersion &+= 1
        hidesVersion &+= 1
    }

    /// Mute a show's news. From a post, that post folds in place ("You muted news from …").
    func muteShow(franchiseId: String, showName: String, fromPostId: String?) {
        if let fromPostId {
            let reduce = UIAccessibility.isReduceMotionEnabled
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduce)) {
                feedFolds[fromPostId] = .muted(show: showName)
            }
        }
        enqueueToggle(SocialToggleKey(kind: .muteShow, target: franchiseId), on: true, franchiseId: franchiseId)
        feedVersion &+= 1
        hidesVersion &+= 1
    }

    func unmuteShow(franchiseId: String) {
        enqueueToggle(SocialToggleKey(kind: .muteShow, target: franchiseId), on: false, franchiseId: franchiseId)
        // A "You muted news from …" row for this show has nothing left to say.
        let stale = feedFolds.filter { postId, fold in
            if case .muted = fold { return franchiseIdOfPost(postId) == franchiseId }
            return false
        }.map(\.key)
        if !stale.isEmpty {
            var folds = feedFolds
            stale.forEach { folds[$0] = nil }
            feedFolds = folds
        }
        feedVersion &+= 1
        hidesVersion &+= 1
    }

    /// The fold's Undo: the post comes back, and the word that hid it is taken back (a hide that
    /// never left the device costs no request — the cancelling rule).
    func undoFold(postId: String) {
        guard let fold = feedFolds[postId] else { return }
        let reduce = UIAccessibility.isReduceMotionEnabled
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduce)) {
            feedFolds[postId] = nil
        }
        switch fold {
        case .notInterested:
            enqueueToggle(SocialToggleKey(kind: .hidePost, target: postId), on: false, franchiseId: nil)
        case .muted:
            if let fid = franchiseIdOfPost(postId) {
                enqueueToggle(SocialToggleKey(kind: .muteShow, target: fid), on: false, franchiseId: fid)
            }
        }
        feedVersion &+= 1
        hidesVersion &+= 1
    }

    func toggleCommentLike(_ c: SocialComment) {
        let key = Self.commentKey(c.id)
        if socialBase[key] == nil { socialBase[key] = SubjectSocial(liked: c.liked, likes: c.likeCount) }
        let desired = !isCommentLiked(c)
        enqueueToggle(SocialToggleKey(kind: .commentLike, target: c.id), on: desired, franchiseId: nil)
        if desired { FeedbackCoordinator.fire(.selection) }
    }

    /// Steps 1, 2, 5 and 6 of §4.3, with the cancelling rule: a word that equals the server's and
    /// has no lane running is simply withdrawn — nothing is sent.
    private func enqueueToggle(_ key: SocialToggleKey, on desired: Bool, franchiseId: String?) {
        let reduce = UIAccessibility.isReduceMotionEnabled
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduce)) {
            if let server = serverValue(key), server == desired, socialLanes[key] == nil {
                socialPending[key] = nil
            } else {
                socialPending[key] = SocialToggleWrite(on: desired,
                                                       franchiseId: franchiseId ?? socialPending[key]?.franchiseId,
                                                       queuedAt: .nowMs)
            }
        }
        persistSocialPending()
        flushSocialKey(key)
    }

    /// What the server holds for a toggle, when the model knows it. A block's is never known here
    /// (the list is not kept), so a block's word is always sent — the call is idempotent.
    private func serverValue(_ key: SocialToggleKey) -> Bool? {
        switch key.kind {
        case .like: return socialBase[key.target]?.liked ?? false
        case .save: return socialBase[key.target]?.saved ?? false
        case .remind: return socialBase[key.target]?.reminded ?? false
        case .hidePost: return serverHiddenPostIds.contains(key.target)
        case .muteShow: return serverMutedShowIds.contains(key.target)
        case .commentLike: return socialBase[Self.commentKey(key.target)]?.liked ?? false
        case .block: return nil
        }
    }

    // MARK: - Lanes

    /// Sends every word the server has not had. Runs on every enqueue, after the pending file
    /// loads, after each successful feed load, on foreground and on reconnect. No-op in an isolated
    /// model, while the device is offline (the reconnect flushes), while an account deletion is
    /// under way (`abortErasure` flushes) and behind a suspension (every word would answer 403).
    func flushSocial() {
        guard !isIsolated, !erasing, !accountSuspended, SyncCenter.shared.isOnline else { return }
        for key in socialPending.keys where socialLanes[key] == nil { flushSocialKey(key) }
        for key in pendingRatings.keys where ratingLanes[key] == nil { flushRating(key) }
    }

    /// ONE lane per toggle, newest word wins: a word that lands while a request is in flight is
    /// sent after it; one that equals what just landed is done.
    private func flushSocialKey(_ key: SocialToggleKey) {
        guard !isIsolated, !erasing, !accountSuspended, socialLanes[key] == nil,
              SyncCenter.shared.isOnline, persistSocialPending() else { return }
        let epoch = accountEpoch
        // An episode's heart is gated by the part's progress (409 `episode_locked`): a mark made
        // seconds ago must reach the server before the like does.
        let episode = key.kind == .like ? ThreadSubject.parseEpisode(key.target) : nil
        socialLanes[key] = Task { [weak self] in
            guard let self else { return }
            if let episode { await self.awaitEpisodeGate(mediaId: episode.mediaId) }
            var retriedLock = false
            // An erasure stops the lane between words: the word stays pending, unsent.
            while epoch == self.accountEpoch, !self.erasing, let write = self.socialPending[key] {
                if let until = write.retryAfter, until > .nowMs { break }
                guard self.persistSocialPending() else { break }
                do {
                    try await self.sendToggle(key, on: write.on)
                    guard epoch == self.accountEpoch else { return }
                    self.commitToggle(key, on: write.on)
                    if self.socialPending[key]?.on == write.on {
                        self.socialPending[key] = nil
                        break
                    }
                    // Else a newer word arrived while this one was on the wire: loop and send it.
                } catch {
                    guard epoch == self.accountEpoch else { return }
                    // Refused by an erasure's halt (a teardown moved the epoch above): the word is
                    // kept and the lane ends, so `abortErasure`'s flush can start it again.
                    if error.isCancellation { break }
                    if let episode, !retriedLock,
                       await self.recoverEpisodeLock(error, mediaId: episode.mediaId, episode: episode.episode) {
                        retriedLock = true
                        guard epoch == self.accountEpoch else { return }
                        continue
                    }
                    switch SocialWriteFailure(error) {
                    case .final:
                        self.socialPending[key] = nil          // the overlay falls back to the base
                        self.didRevertToggle(key)
                    case .rateLimited(let seconds):
                        self.socialPending[key]?.retryAfter = .nowMs + Int64(seconds) * 1000
                    case .transient:
                        self.socialPending[key]?.attempts += 1  // kept; the next trigger retries
                    case .suspended:
                        self.accountSuspended = true
                    case .unauthorized:
                        self.handleSessionExpired()
                        return
                    }
                    break
                }
            }
            guard epoch == self.accountEpoch else { return }
            self.socialLanes[key] = nil
            self.persistSocialPending()
        }
    }

    private func sendToggle(_ key: SocialToggleKey, on: Bool) async throws {
        switch key.kind {
        case .like: try await api.setLike(subject: key.target, on: on)
        case .save: try await api.setSave(postId: key.target, on: on)
        case .remind: try await api.setReminder(postId: key.target, on: on)
        case .hidePost: try await api.setHide(kind: .post, target: key.target, on: on)
        case .muteShow: try await api.setHide(kind: .show, target: key.target, on: on)
        case .commentLike: try await api.setCommentLike(id: key.target, on: on)
        case .block: try await api.setBlock(userId: key.target, on: on)
        }
    }

    /// Folds a word the server accepted into the base, so the overlay reads the same once the
    /// pending entry steps aside.
    private func commitToggle(_ key: SocialToggleKey, on: Bool) {
        switch key.kind {
        case .like, .commentLike:
            let baseKey = key.kind == .like ? key.target : Self.commentKey(key.target)
            var base = socialBase[baseKey] ?? SubjectSocial()
            guard base.liked != on else { return }
            base.likes = max(0, base.likes + (on ? 1 : -1))
            base.liked = on
            socialBase[baseKey] = base
        case .save:
            var base = socialBase[key.target] ?? SubjectSocial()
            guard base.saved != on else { return }
            base.saved = on
            socialBase[key.target] = base
        case .remind:
            var base = socialBase[key.target] ?? SubjectSocial()
            if base.reminded != on {
                base.reminded = on
                socialBase[key.target] = base
            }
            if !on, reminderItems.contains(where: { $0.postId == key.target }) {
                reminderItems.removeAll { $0.postId == key.target }
                scheduleFeedCacheWrite()
            }
        case .hidePost:
            if on { serverHiddenPostIds.insert(key.target) } else { serverHiddenPostIds.remove(key.target) }
            scheduleFeedCacheWrite()
        case .muteShow:
            if on { serverMutedShowIds.insert(key.target) } else { serverMutedShowIds.remove(key.target) }
            scheduleFeedCacheWrite()
        case .block:
            break
        }
    }

    /// A word the server refused for good: the overlay already fell back to the base; this puts
    /// back what the word had changed elsewhere.
    private func didRevertToggle(_ key: SocialToggleKey) {
        switch key.kind {
        case .remind:
            feedVersion &+= 1
            if reminderPrimerPostId == key.target { reminderPrimerPostId = nil }
            Task { await syncAmbient() }
        case .hidePost, .muteShow:
            feedVersion &+= 1
            hidesVersion &+= 1
        case .like:
            // An episode's heart is gated server-side (409 `episode_locked`): reload the room.
            if let ep = ThreadSubject.parseEpisode(key.target) {
                Task { await loadEpisodeRoom(mediaId: ep.mediaId, episode: ep.episode) }
            }
        case .save, .commentLike, .block:
            break
        }
    }

    // MARK: - Persistence

    /// The outbox reaches disk before a task can dispatch its request. A failed local write
    /// keeps the word pending and prevents HTTP; teardown cannot race this main-actor write.
    @discardableResult
    func persistSocialPending() -> Bool {
        guard !isIsolated, !erasing, let owner = accountStorage,
              AccountLocalStore.shared.matches(owner) else { return false }
        guard !socialPendingRestoreFailed else {
            showError("Saved activity could not be restored. Sign out to discard this device's saved changes, then sign in again.")
            return false
        }
        socialPersistWrite?.cancel()
        let file = SocialPendingFile(
            toggles: socialPending.map { SocialPendingFile.Toggle(key: $0.key, write: $0.value) },
            ratings: Array(pendingRatings.values), comments: pendingComments)
        do {
            // Persist the empty receipt too: ignoring a failed file removal would replay an old
            // toggle after relaunch and could replace a newer word on the server.
            let data = try JSONEncoder().encode(file)
            try AccountLocalStore.shared.write(data, name: "social-pending.json", owner: owner)
            return true
        } catch {
            showError(Copy.Notice.reason(MutationJournal.JournalError.persistenceFailure))
            return false
        }
    }

    /// Restore the small pending outbox synchronously before the UI can enqueue a new word.
    /// Otherwise a pre-dispatch write could replace the file while a detached restore reads it.
    func loadPendingSocial() {
        guard !isIsolated, !erasing, let owner = accountStorage,
              AccountLocalStore.shared.matches(owner) else { return }
        let savedURL = owner.file("social-pending.json")
        let savedData = AccountLocalStore.shared.read("social-pending.json", owner: owner)
        let saved = savedData.flatMap { try? JSONDecoder().decode(SocialPendingFile.self, from: $0) }
        if FileManager.default.fileExists(atPath: savedURL.path), saved?.version != 1 {
            socialPendingRestoreFailed = true
            SyncCenter.shared.localActivityRecoveryRequired = true
            showError("Saved activity could not be restored. Sign out to discard this device's saved changes, then sign in again.")
            return
        }
        if let file = saved {
            var toggles = socialPending
            var hidesChanged = false
            for toggle in file.toggles where toggles[toggle.key] == nil {
                toggles[toggle.key] = toggle.write
                if toggle.key.kind == .hidePost || toggle.key.kind == .muteShow { hidesChanged = true }
            }
            socialPending = toggles
            var ratings = pendingRatings
            for rating in file.ratings {
                let key = Self.ratingKey(rating.mediaId, rating.episode)
                if ratings[key] == nil { ratings[key] = rating }
            }
            pendingRatings = ratings
            let known = Set(pendingComments.map(\.id))
            pendingComments += file.comments.filter { !known.contains($0.id) }
            if hidesChanged { feedVersion &+= 1; hidesVersion &+= 1 }
        }
        flushSocial()
        for comment in pendingComments where comment.state != .failed {
            Task { _ = await self.retryComment(id: comment.id) }
        }
    }

    // MARK: - Hides

    /// `GET /me/hides` → the server's muted shows and hidden posts. Returns the list too (Profile's
    /// Muted shows names the shows from it). Nil when it could not load.
    @discardableResult
    func loadHides() async -> [FeedHide]? {
        guard !isIsolated else { return nil }
        let epoch = accountEpoch
        do {
            let res = try await api.hides()
            guard epoch == accountEpoch else { return nil }
            let shows = Set(res.items.filter { $0.kind == .show }.map(\.target))
            let posts = Set(res.items.filter { $0.kind == .post }.map(\.target))
            feedLiveLoaded.insert("hides")
            if shows != serverMutedShowIds || posts != serverHiddenPostIds {
                serverMutedShowIds = shows
                serverHiddenPostIds = posts
                feedVersion &+= 1
                hidesVersion &+= 1
            }
            scheduleFeedCacheWrite()
            return res.items
        } catch {
            guard epoch == accountEpoch else { return nil }
            handleSocialReadError(error)
            return nil
        }
    }

    // MARK: - Ratings and episode rooms

    nonisolated static func ratingKey(_ mediaId: Int, _ episode: Int) -> String { "\(mediaId):\(episode)" }

    /// The pending word over the room's `yours`. Nil = not rated.
    func yourRating(mediaId: Int, episode: Int) -> Int? {
        if let pending = pendingRatings[Self.ratingKey(mediaId, episode)] { return pending.score }
        return episodeRooms[ThreadSubject.episode(mediaId: mediaId, episode: episode)]?.rating.yours
    }

    /// 0…100; nil clears. Optimistic, newest word wins, one lane per episode. Signs with one
    /// `.selection` when a score is set — call it once, on release, not per drag step.
    func rateEpisode(mediaId: Int, episode: Int, score: Int?) {
        let key = Self.ratingKey(mediaId, episode)
        let clamped = score.map { min(100, max(0, $0)) }
        let room = episodeRooms[ThreadSubject.episode(mediaId: mediaId, episode: episode)]
        if let room, room.rating.yours == clamped, ratingLanes[key] == nil {
            pendingRatings[key] = nil
        } else {
            pendingRatings[key] = PendingRating(mediaId: mediaId, episode: episode, score: clamped, queuedAt: .nowMs)
        }
        if clamped != nil { FeedbackCoordinator.fire(.selection) }
        persistSocialPending()
        flushRating(key)
    }

    private func flushRating(_ key: String) {
        guard !isIsolated, !erasing, !accountSuspended, ratingLanes[key] == nil,
              SyncCenter.shared.isOnline, persistSocialPending() else { return }
        let epoch = accountEpoch
        // A rating is gated like the heart: the part's progress must be on the server first.
        let gatedMediaId = pendingRatings[key]?.mediaId
        ratingLanes[key] = Task { [weak self] in
            guard let self else { return }
            if let gatedMediaId { await self.awaitEpisodeGate(mediaId: gatedMediaId) }
            var retriedLock = false
            while epoch == self.accountEpoch, !self.erasing, let write = self.pendingRatings[key] {
                guard self.persistSocialPending() else { break }
                do {
                    try await self.api.setRating(mediaId: write.mediaId, episode: write.episode, score: write.score)
                    guard epoch == self.accountEpoch else { return }
                    // The room (its average moved too) before the pending word steps aside, so the
                    // sticker never shows the old score for a beat.
                    if let room = try? await self.api.episodeRoom(mediaId: write.mediaId, episode: write.episode),
                       epoch == self.accountEpoch {
                        self.ingestRoom(room)
                    }
                    guard epoch == self.accountEpoch else { return }
                    if let current = self.pendingRatings[key], current.score == write.score {
                        self.pendingRatings[key] = nil
                        break
                    }
                    if self.pendingRatings[key] == nil { break }
                } catch {
                    guard epoch == self.accountEpoch else { return }
                    if error.isCancellation { break }   // an erasure's halt: kept, the lane ends
                    if !retriedLock,
                       await self.recoverEpisodeLock(error, mediaId: write.mediaId, episode: write.episode) {
                        retriedLock = true
                        guard epoch == self.accountEpoch else { return }
                        continue
                    }
                    switch SocialWriteFailure(error) {
                    case .final:
                        // 409 `episode_locked`, 404: withdrawn silently; the room says the truth.
                        self.pendingRatings[key] = nil
                        Task { await self.loadEpisodeRoom(mediaId: write.mediaId, episode: write.episode) }
                    case .rateLimited, .transient:
                        break
                    case .suspended:
                        self.accountSuspended = true
                    case .unauthorized:
                        self.handleSessionExpired()
                        return
                    }
                    break
                }
            }
            guard epoch == self.accountEpoch else { return }
            self.ratingLanes[key] = nil
            self.persistSocialPending()
        }
    }

    /// Waits (≤ 3 s) for the part's progress to reach the server — its lane, its show's one-call
    /// writes — before an `ep:` like or a rating is sent, as a comment does (§4.5 step 4).
    private func awaitEpisodeGate(mediaId: Int) async {
        await awaitProgressLane(mediaId: mediaId, timeout: .seconds(3))
    }

    /// A 409 `episode_locked` (unwatched) while this device's gate reads OPEN: the mark has not
    /// reached the server. Replays a failed progress write if one stands, waits for the lane, and
    /// answers true — worth ONE more send before the word is reverted.
    private func recoverEpisodeLock(_ error: Error, mediaId: Int, episode: Int) async -> Bool {
        guard let api = error as? APIError, case .http(409, _) = api,
              let social = api.socialError, social.code == .episodeLocked,
              social.reason != EpisodeAccess.unaired.rawValue,
              clientEpisodeAccess(mediaId: mediaId, episode: episode) == .open else { return false }
        if SyncCenter.shared.hasFailedProgress(mediaId: mediaId) {
            await SyncCenter.shared.replayProgress(mediaId: mediaId)
        }
        await awaitProgressLane(mediaId: mediaId, timeout: .seconds(3))
        return true
    }

    func episodeRoom(mediaId: Int, episode: Int) -> EpisodeRoom? {
        episodeRooms[ThreadSubject.episode(mediaId: mediaId, episode: episode)]
    }

    /// `GET /social/episodes/:m/:n` — the lock line's count, the heart, the sticker's average.
    func loadEpisodeRoom(mediaId: Int, episode: Int) async {
        guard !isIsolated else { return }
        let epoch = accountEpoch
        do {
            let room = try await api.episodeRoom(mediaId: mediaId, episode: episode)
            guard epoch == accountEpoch else { return }
            ingestRoom(room)
        } catch {
            guard epoch == accountEpoch else { return }
            handleSocialReadError(error)
        }
    }

    private func ingestRoom(_ room: EpisodeRoom) {
        let subject = ThreadSubject.episode(mediaId: room.mediaId, episode: room.episode)
        episodeRooms[subject] = room
        var base = socialBase[subject] ?? SubjectSocial()
        base.liked = room.liked
        base.likes = room.likeCount
        base.comments = room.commentCount
        if socialBase[subject] != base { socialBase[subject] = base }
    }

    /// The client's half of the episode gate (iD16), from the LIVE library part: the server's two
    /// rules — aired by now (anchor-aware), then progress. It can only unlock LATER than the
    /// server, never earlier. `.unknown` when the show or part is not in the library: the view
    /// treats it as locked and asks the server (`loadEpisodeRoom`).
    func clientEpisodeAccess(franchiseId: String, mediaId: Int, episode: Int) -> EpisodeAccess {
        guard let f = franchise(id: franchiseId),
              let part = f.parts.first(where: { $0.mediaId == mediaId }) else { return .unknown }
        return Self.episodeAccess(part: part, anchor: f.timeAnchor, episode: episode, now: .nowMs)
    }

    /// The pure rule (server §4.1 `episodeAccess`): unaired first — only when the aired count is
    /// KNOWN — then unwatched.
    nonisolated static func episodeAccess(part: FranchisePart, anchor: Formatting.TimeAnchor,
                                          episode: Int, now: Int64) -> EpisodeAccess {
        let aired: Int
        let known: Bool
        if part.isUpcoming {
            aired = 0
            known = true
        } else if part.isReleasing {
            // The write ceiling's aired count and "known" test (`FranchisePart.airedForGate`,
            // `progressCeiling`): one number for the mark and the room, as the server has.
            aired = part.airedForGate(now: now, anchor: anchor)
            known = aired > 0 || !part.airings.isEmpty || part.nextAiringAt != nil
                || part.episodes.contains { $0.airDate != nil } || part.totalEpisodes > 0
        } else {
            aired = part.availableEpisodes()
            known = aired > 0 || part.totalEpisodes > 0
        }
        if known && episode > aired { return .unaired }
        if part.progress < episode { return .unwatched }
        return .open
    }

    /// The same gate for a subject that names only its media id (an `ep:` room).
    private func clientEpisodeAccess(mediaId: Int, episode: Int) -> EpisodeAccess {
        guard let f = library.first(where: { $0.parts.contains { $0.mediaId == mediaId } }) else { return .unknown }
        return clientEpisodeAccess(franchiseId: f.id, mediaId: mediaId, episode: episode)
    }

    // MARK: - Comments

    func thread(_ subject: String) -> CommentThread? { threads[subject] }

    /// This subject's replies still on their way, newest first.
    func pendingComments(for subject: String) -> [PendingComment] {
        pendingComments.filter { $0.subject == subject }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The first page (a reset) of a thread. For an `ep:` room the read waits for the part's
    /// progress lane (bounded, 3 s), and a room the SERVER still locks while the client says open —
    /// a mark still on its way — shows "Saving your progress" (`locked`, `.unwatched`, `loading`
    /// all at once) while the part's failed write replays, then reads ONCE more (§4.2 step 3).
    func loadComments(_ subject: String, sort: CommentSort, reset: Bool) async {
        guard !isIsolated else { return }
        var thread = threads[subject] ?? CommentThread()
        if thread.loading, !reset, thread.sort == sort { return }
        let seq = (threadSeq[subject] ?? 0) &+ 1
        threadSeq[subject] = seq
        let epoch = accountEpoch
        if thread.sort != sort {
            thread.items = []
            thread.nextCursor = nil
        }
        thread.sort = sort
        thread.loading = true
        thread.failed = false
        threads[subject] = thread

        let ep = ThreadSubject.parseEpisode(subject)
        if let ep { await awaitProgressLane(mediaId: ep.mediaId, timeout: .seconds(3)) }
        guard threadSeq[subject] == seq, epoch == accountEpoch else { return }
        do {
            var page = try await api.comments(subject: subject, sort: sort, cursor: nil, limit: 20)
            guard threadSeq[subject] == seq, epoch == accountEpoch else { return }
            if page.locked, page.access == .unwatched, let ep,
               clientEpisodeAccess(mediaId: ep.mediaId, episode: ep.episode) == .open {
                var saving = threads[subject] ?? CommentThread()
                saving.locked = true
                saving.access = .unwatched
                saving.total = page.total
                saving.loading = true
                threads[subject] = saving
                if SyncCenter.shared.hasFailedProgress(mediaId: ep.mediaId) {
                    await SyncCenter.shared.replayProgress(mediaId: ep.mediaId)
                }
                _ = await awaitProgressLane(mediaId: ep.mediaId)
                guard threadSeq[subject] == seq, epoch == accountEpoch else { return }
                page = try await api.comments(subject: subject, sort: sort, cursor: nil, limit: 20)
                guard threadSeq[subject] == seq, epoch == accountEpoch else { return }
            }
            applyCommentsPage(page, to: subject, reset: true)
        } catch {
            guard threadSeq[subject] == seq, epoch == accountEpoch else { return }
            failCommentsLoad(subject, error: error)
        }
    }

    /// The next page, from the thread's opaque cursor; deduped by id.
    func loadMoreComments(_ subject: String) async {
        guard !isIsolated, var thread = threads[subject], let cursor = thread.nextCursor, !thread.loading else { return }
        let seq = (threadSeq[subject] ?? 0) &+ 1
        threadSeq[subject] = seq
        let epoch = accountEpoch
        thread.loading = true
        threads[subject] = thread
        do {
            let page = try await api.comments(subject: subject, sort: thread.sort, cursor: cursor, limit: 20)
            guard threadSeq[subject] == seq, epoch == accountEpoch else { return }
            applyCommentsPage(page, to: subject, reset: false)
        } catch {
            guard threadSeq[subject] == seq, epoch == accountEpoch else { return }
            failCommentsLoad(subject, error: error)
        }
    }

    private func applyCommentsPage(_ page: CommentsPage, to subject: String, reset: Bool) {
        var thread = threads[subject] ?? CommentThread()
        // Someone blocked this session disappears at once, before the server's next answer does.
        let blocked = locallyBlockedUserIds
        let incoming = page.items.filter { !blocked.contains($0.author.id) }
        if reset {
            var seen = Set<String>()
            thread.items = incoming.filter { seen.insert($0.id).inserted }
        } else {
            var seen = Set(thread.items.map(\.id))
            thread.items += incoming.filter { seen.insert($0.id).inserted }
        }
        thread.total = page.total
        thread.nextCursor = page.nextCursor
        thread.locked = page.locked
        thread.access = page.access
        thread.loading = false
        thread.failed = false
        thread.loadedOnce = true
        threads[subject] = thread

        var base = socialBase
        for c in incoming {
            let key = Self.commentKey(c.id)
            let next = SubjectSocial(liked: c.liked, likes: c.likeCount)
            if base[key] != next { base[key] = next }
        }
        if !page.locked {
            var subjectBase = base[subject] ?? SubjectSocial()
            subjectBase.comments = page.total
            base[subject] = subjectBase
        }
        if base != socialBase { socialBase = base }
    }

    private func failCommentsLoad(_ subject: String, error: Error) {
        var thread = threads[subject] ?? CommentThread()
        thread.loading = false
        defer { threads[subject] = thread }
        guard !error.isCancellation else { return }
        if let apiError = error as? APIError {
            switch apiError {
            case .http(404, _):
                if apiError.socialError?.code == .commentsDisabled { disableComments() } else { thread.failed = true }
            case .suspended:
                accountSuspended = true
                thread.failed = true
            case .unauthorized:
                handleSessionExpired()
            default:
                thread.failed = true
            }
        } else {
            thread.failed = true
        }
    }

    /// Comments were switched off server-side (§4.9): every reply affordance hides.
    private func disableComments() {
        guard feedCapabilities.comments else { return }
        feedCapabilities = FeedCapabilities(comments: false)
        feedVersion &+= 1
    }

    /// Users blocked on this device this session (confirmed or not) and any block still waiting
    /// for the server — their replies never come back into a loaded thread.
    private var locallyBlockedUserIds: Set<String> {
        Set(socialPending.compactMap { $0.key.kind == .block && $0.value.on ? $0.key.target : nil })
            .union(blockedSessionIds)
    }

    // MARK: Sending (§4.5)

    /// Sends a reply. It is a pending row at once; the send continues even if the caller stops
    /// waiting (the composer's 1.5 s, iD5), because it runs in its own task.
    func sendComment(_ target: ComposeTarget, body: String) async -> SendOutcome {
        guard feedCapabilities.comments else { return .disabled }
        let count = SocialText.count(body)
        guard count > 0 else { return .rejected("empty") }
        guard count <= SocialText.limit else { return .rejected("too_long") }
        let pending = PendingComment(id: UUID().uuidString.lowercased(), subject: target.subject,
                                     franchiseId: target.franchiseId, franchiseTitle: target.franchiseTitle,
                                     parentId: target.parentId, replyingTo: target.replyingTo,
                                     body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                                     createdAt: .nowMs, state: .sending)
        pendingComments.insert(pending, at: 0)
        persistSocialPending()
        let id = pending.id
        return await Task { [weak self] () -> SendOutcome in
            await self?.attemptComment(id: id) ?? .gone
        }.value
    }

    /// Re-runs the send with the stored pending entry — the SAME id, which the server replays
    /// idempotently (the thread's "Not sent · Retry", and Sync status).
    func retryComment(id: String) async -> SendOutcome {
        guard pendingComments.contains(where: { $0.id == id }) else { return .gone }
        return await attemptComment(id: id)
    }

    /// The `WriteIntent` replay after a relaunch: the pending row is rebuilt if it is missing.
    func replayComment(id: String, subject: String, parentId: String?, body: String,
                       franchiseId: String, title: String) async {
        if !pendingComments.contains(where: { $0.id == id }) {
            pendingComments.insert(PendingComment(id: id, subject: subject, franchiseId: franchiseId,
                                                  franchiseTitle: title, parentId: parentId, replyingTo: nil,
                                                  body: body, createdAt: .nowMs, state: .sending), at: 0)
            persistSocialPending()
        }
        _ = await retryComment(id: id)
    }

    /// The pending row and its Sync status row, gone.
    func discardComment(id: String) {
        pendingComments.removeAll { $0.id == id }
        discardCommentFailure(id: id)
        persistSocialPending()
    }

    /// Steps 3–6 of §4.5 for one pending entry.
    private func attemptComment(id: String) async -> SendOutcome {
        // During an erasure the reply stays pending, unsent (`abortErasure` retries it).
        guard !isIsolated, !erasing else { return .queued }
        guard !commentsInFlight.contains(id), var pending = pendingComments.first(where: { $0.id == id }) else {
            return .queued
        }
        commentsInFlight.insert(id)
        defer { commentsInFlight.remove(pending.id); commentsInFlight.remove(id) }
        let epoch = accountEpoch
        setCommentState(pending.id, .sending)

        guard SyncCenter.shared.isOnline else {
            setCommentState(pending.id, .failed)
            fileCommentFailure(pending, error: URLError(.notConnectedToInternet))
            return .queued
        }
        let ep = ThreadSubject.parseEpisode(pending.subject)
        if let ep {
            // The server gate reads the part's progress: a mark still on its way must land first.
            let settled = await awaitProgressLane(mediaId: ep.mediaId)
            guard epoch == accountEpoch else { return .gone }
            if !settled { await SyncCenter.shared.replayProgress(mediaId: ep.mediaId) }
        }

        var retriedLock = false
        var retriedConflict = false
        while true {
            guard epoch == accountEpoch, persistSocialPending() else { return .queued }
            do {
                let res = try await api.postComment(CommentBody(id: pending.id, subject: pending.subject,
                                                                body: pending.body, parentId: pending.parentId))
                guard epoch == accountEpoch else { return .gone }
                commentLanded(res.comment, pendingId: pending.id)
                return .sent(res.comment)
            } catch {
                guard epoch == accountEpoch else { return .gone }
                if error.isCancellation {
                    setCommentState(pending.id, .failed)
                    fileCommentFailure(pending, error: error)
                    return .queued
                }
                let apiError = error as? APIError
                let social = apiError?.socialError
                switch apiError {
                case .suspended?:
                    accountSuspended = true
                    setCommentState(pending.id, .failed)
                    return .disabled
                case .unauthorized?:
                    handleSessionExpired()
                    return .gone
                case .rateLimited(let after)?:
                    setCommentState(pending.id, .rateLimited)
                    return .rateLimited(seconds: max(1, Int((after ?? 60).rounded(.up))))
                case .http(409, _)?:
                    switch social?.code {
                    case .handleRequired?:
                        dropPendingComment(pending.id)
                        return .needsIdentity
                    case .termsRequired?:
                        dropPendingComment(pending.id)
                        _ = await loadSocialProfile(force: true)
                        return .needsTerms
                    case .episodeLocked?:
                        if social?.reason == EpisodeAccess.unaired.rawValue {
                            dropPendingComment(pending.id)
                            return .locked(.unaired)
                        }
                        if !retriedLock, let ep, clientEpisodeAccess(mediaId: ep.mediaId, episode: ep.episode) == .open {
                            // The mark has not reached the server yet: replay it, wait, retry ONCE
                            // with the same id.
                            retriedLock = true
                            await SyncCenter.shared.replayProgress(mediaId: ep.mediaId)
                            _ = await awaitProgressLane(mediaId: ep.mediaId)
                            guard epoch == accountEpoch else { return .gone }
                            continue
                        }
                        dropPendingComment(pending.id)
                        return .locked(.unwatched)
                    case .idConflict?:
                        if !retriedConflict {
                            // The id belongs to someone else's reply: a fresh uuid, one retry.
                            retriedConflict = true
                            pending = rekeyPendingComment(pending)
                            commentsInFlight.insert(pending.id)
                            continue
                        }
                        dropPendingComment(pending.id)
                        return .gone
                    default:
                        dropPendingComment(pending.id)
                        return .gone
                    }
                case .http(410, _)?:
                    // Replayed after its author deleted it.
                    dropPendingComment(pending.id)
                    return .gone
                case .http(404, _)?:
                    dropPendingComment(pending.id)
                    if social?.code == .commentsDisabled {
                        disableComments()
                        return .disabled
                    }
                    return .gone
                case .http(let code, _)? where code == 422 || code == 400:
                    dropPendingComment(pending.id)
                    return .rejected(social?.reason ?? "")
                default:
                    // Transport, 5xx, infrastructure: the pending row stays, Sync status carries it.
                    setCommentState(pending.id, .failed)
                    fileCommentFailure(pending, error: error)
                    return .queued
                }
            }
        }
    }

    /// The reply is on the server: the pending row leaves, the reply takes the top of its thread
    /// and the subject's count moves by one.
    private func commentLanded(_ comment: SocialComment, pendingId: String) {
        pendingComments.removeAll { $0.id == pendingId }
        discardCommentFailure(id: pendingId)
        var thread = threads[comment.subject] ?? CommentThread()
        if !thread.items.contains(where: { $0.id == comment.id }) {
            thread.items.insert(comment, at: 0)
            thread.total += 1
            var base = socialBase[comment.subject] ?? SubjectSocial()
            base.comments += 1
            socialBase[comment.subject] = base
        }
        threads[comment.subject] = thread
        socialBase[Self.commentKey(comment.id)] = SubjectSocial(liked: comment.liked, likes: comment.likeCount)
        persistSocialPending()
    }

    private func setCommentState(_ id: String, _ state: PendingComment.State) {
        guard let i = pendingComments.firstIndex(where: { $0.id == id }), pendingComments[i].state != state else { return }
        pendingComments[i].state = state
        persistSocialPending()
    }

    private func dropPendingComment(_ id: String) {
        pendingComments.removeAll { $0.id == id }
        discardCommentFailure(id: id)
        persistSocialPending()
    }

    /// The same reply under a new id (409 `id_conflict`), in the same place.
    private func rekeyPendingComment(_ old: PendingComment) -> PendingComment {
        let fresh = PendingComment(id: UUID().uuidString.lowercased(), subject: old.subject,
                                   franchiseId: old.franchiseId, franchiseTitle: old.franchiseTitle,
                                   parentId: old.parentId, replyingTo: old.replyingTo, body: old.body,
                                   createdAt: old.createdAt, state: .sending)
        if let i = pendingComments.firstIndex(where: { $0.id == old.id }) {
            pendingComments[i] = fresh
        } else {
            pendingComments.insert(fresh, at: 0)
        }
        discardCommentFailure(id: old.id)
        persistSocialPending()
        return fresh
    }

    /// Step 6: Sync status, with the exact write as its replay. The title carries an excerpt so two
    /// failed replies on one show are two rows (rows are keyed by command + title).
    private func fileCommentFailure(_ pending: PendingComment, error: Error) {
        let id = pending.id
        fileFailure(command: Copy.Social.postReplyCommand,
                    title: Copy.Social.failedReplyTitle(show: pending.franchiseTitle,
                                                        excerpt: Self.excerpt(pending.body, 24)),
                    reason: Copy.Notice.reason(error),
                    intent: .comment(id: id, subject: pending.subject, parentId: pending.parentId,
                                     body: pending.body, franchiseId: pending.franchiseId,
                                     title: pending.franchiseTitle)) { [weak self] in
            _ = await self?.retryComment(id: id)
        }
    }

    private func discardCommentFailure(id: String) {
        guard !isIsolated else { return }
        for change in SyncCenter.shared.failedChanges {
            if case .comment(let cid, _, _, _, _, _) = change.intent, cid == id {
                SyncCenter.shared.discard(change.id)
            }
        }
    }

    /// The first `limit` characters of a reply, cut at a word where one is near, with an ellipsis
    /// when anything was cut.
    nonisolated static func excerpt(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        var cut = String(flat.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "\u{2026}"
    }

    // MARK: Delete, report, block (§4.6)

    /// Own replies only. A reply already gone (404) is removed all the same.
    func deleteComment(_ c: SocialComment) async -> Bool {
        guard !isIsolated else { return false }
        let epoch = accountEpoch
        do {
            try await api.deleteComment(id: c.id)
        } catch {
            guard epoch == accountEpoch else { return false }
            let apiError = error as? APIError
            if apiError?.socialError?.code == .commentsDisabled {
                disableComments()
                return false
            }
            // 404: not found or already deleted — gone either way.
            guard let apiError, case .http(404, _) = apiError else {
                handleSocialReadError(error)
                return false
            }
        }
        guard epoch == accountEpoch else { return false }
        removeComment(c)
        FeedbackCoordinator.fire(.destructive)
        showNotice(Copy.Social.deletedNotice)
        return true
    }

    /// The server hides a reported reply for its reporter at once; so does the thread.
    func reportComment(_ c: SocialComment, reason: ReportReason, note: String?) async -> Bool {
        guard !isIsolated else { return false }
        let epoch = accountEpoch
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await api.reportComment(id: c.id, reason: reason, note: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        } catch {
            guard epoch == accountEpoch else { return false }
            // 404: already gone — hidden for this reader all the same.
            guard let apiError = error as? APIError, case .http(404, _) = apiError else {
                handleSocialReadError(error)
                return false
            }
        }
        guard epoch == accountEpoch else { return false }
        removeComment(c, countsTowardTotal: false)
        showNotice(Copy.Social.reportedNotice)
        return true
    }

    /// Optimistic (§4.3, kind `.block`): the author's replies leave every loaded thread at once.
    func block(_ user: PublicUser) async -> Bool {
        enqueueToggle(SocialToggleKey(kind: .block, target: user.id), on: true, franchiseId: nil)
        blockedSessionIds.insert(user.id)
        removeReplies(by: user.id)
        showNotice(Copy.Social.blockedNotice(user.handle))
        return true
    }

    func unblock(_ user: PublicUser) async -> Bool {
        enqueueToggle(SocialToggleKey(kind: .block, target: user.id), on: false, franchiseId: nil)
        blockedSessionIds.remove(user.id)
        return true
    }

    /// `GET /me/blocks`, with this device's unconfirmed words applied. Nil when it could not load.
    func loadBlocked() async -> [BlockedUser]? {
        guard !isIsolated else { return nil }
        let epoch = accountEpoch
        do {
            let res = try await api.blocks()
            guard epoch == accountEpoch else { return nil }
            let unblocked = Set(socialPending.compactMap { $0.key.kind == .block && !$0.value.on ? $0.key.target : nil })
            return res.items.filter { !unblocked.contains($0.user.id) }
        } catch {
            guard epoch == accountEpoch else { return nil }
            handleSocialReadError(error)
            return nil
        }
    }

    private func removeComment(_ c: SocialComment, countsTowardTotal: Bool = true) {
        guard var thread = threads[c.subject] else { return }
        let before = thread.items.count
        thread.items.removeAll { $0.id == c.id }
        guard thread.items.count != before else { return }
        thread.total = max(0, thread.total - 1)
        threads[c.subject] = thread
        if countsTowardTotal, var base = socialBase[c.subject] {
            base.comments = max(0, base.comments - 1)
            socialBase[c.subject] = base
        }
    }

    private func removeReplies(by userId: String) {
        var all = threads
        var changed = false
        for (subject, var thread) in all {
            let before = thread.items.count
            thread.items.removeAll { $0.author.id == userId }
            guard thread.items.count != before else { continue }
            thread.total = max(0, thread.total - (before - thread.items.count))
            all[subject] = thread
            changed = true
        }
        if changed { threads = all }
    }

    // MARK: - Identity and rules

    /// `GET /me/profile`, once per session unless forced.
    @discardableResult
    func loadSocialProfile(force: Bool = false) async -> SocialProfile? {
        guard !isIsolated else { return socialProfile }
        if !force, let socialProfile { return socialProfile }
        let epoch = accountEpoch
        do {
            let profile = try await api.socialProfile()
            guard epoch == accountEpoch else { return nil }
            if socialProfile != profile { socialProfile = profile }
            return profile
        } catch {
            guard epoch == accountEpoch else { return nil }
            handleSocialReadError(error)
            return socialProfile
        }
    }

    var composeGate: ComposeGate {
        guard feedCapabilities.comments else { return .disabled }
        guard let profile = socialProfile else { return .loading }
        if profile.needsTerms { return .needsTerms }
        if profile.needsIdentity { return .needsIdentity }
        return .ready
    }

    /// Agree and continue: the version the server says is current. A mismatch (the terms moved
    /// while the sheet was open) refetches the profile and answers so the sheet asks again.
    func acceptCommunityRules() async -> Result<SocialProfile, SocialFailure> {
        guard !isIsolated else { return .failure(.server) }
        let epoch = accountEpoch
        var version = socialProfile?.currentTermsVersion
        if version == nil { version = await loadSocialProfile(force: true)?.currentTermsVersion }
        guard let version else { return .failure(SyncCenter.shared.isOnline ? .server : .offline) }
        do {
            let profile = try await api.acceptTerms(version: version)
            guard epoch == accountEpoch else { return .failure(.server) }
            socialProfile = profile
            return .success(profile)
        } catch {
            guard epoch == accountEpoch else { return .failure(.server) }
            let failure = socialFailure(error)
            if case .termsVersionMismatch = failure { await loadSocialProfile(force: true) }
            return .failure(failure)
        }
    }

    /// Is this handle free? Nil when the question could not be asked.
    func checkHandle(_ raw: String) async -> HandleAvailability? {
        guard !isIsolated else { return nil }
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else { return nil }
        return try? await api.handleAvailability(handle)
    }

    func saveIdentity(handle: String, displayName: String) async -> Result<SocialProfile, SocialFailure> {
        guard !isIsolated else { return .failure(.server) }
        let epoch = accountEpoch
        do {
            let profile = try await api.saveSocialProfile(
                handle: handle.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            guard epoch == accountEpoch else { return .failure(.server) }
            socialProfile = profile
            return .success(profile)
        } catch {
            guard epoch == accountEpoch else { return .failure(.server) }
            return .failure(socialFailure(error))
        }
    }

    private func socialFailure(_ error: Error) -> SocialFailure {
        guard let apiError = error as? APIError else {
            return error.isCancellation || !SyncCenter.shared.isOnline ? .offline : .server
        }
        let social = apiError.socialError
        switch apiError {
        case .rateLimited(let after):
            return .rateLimited(max(1, Int((after ?? 60).rounded(.up))))
        case .transport:
            return .offline
        case .suspended:
            accountSuspended = true
            return .server
        case .unauthorized:
            handleSessionExpired()
            return .server
        case .http(409, _):
            switch social?.code {
            case .handleTaken?: return .handleTaken
            case .termsVersionMismatch?: return .termsVersionMismatch(social?.currentVersion ?? "")
            default: return .server
            }
        case .http(422, _):
            switch social?.code {
            case .invalidHandle?: return .invalidHandle(social?.reason ?? "")
            case .invalidDisplayName?: return .invalidDisplayName(social?.reason ?? "")
            default: return .server
            }
        default:
            return .server
        }
    }

    // MARK: - Saved

    /// `GET /me/saved`, each item composed against its franchise (never fresh). Nil when it could
    /// not load.
    func loadSaved() async -> SavedPostsModel? {
        guard !isIsolated else { return nil }
        let epoch = accountEpoch
        do {
            let res = try await api.saved()
            guard epoch == accountEpoch else { return nil }
            let shows = Dictionary(res.franchises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let clock = now
            let items = res.items.map { item -> (item: SavedItem, model: FeedPostModel?) in
                let model = item.post.flatMap { post -> FeedPostModel? in
                    guard let show = shows[post.franchiseId] else { return nil }
                    return FeedComposer.model(post, show: show, library: franchise(id: post.franchiseId),
                                              owned: isInLibrary(post.franchiseId), now: clock, fresh: false)
                }
                return (item, model)
            }
            ingestSocial(res.items.compactMap(\.post))
            // Every row here is saved as the server knows it, whatever the post payload said.
            var base = socialBase
            for item in res.items {
                var entry = base[item.postId] ?? SubjectSocial()
                if !entry.saved {
                    entry.saved = true
                    base[item.postId] = entry
                }
            }
            if base != socialBase { socialBase = base }
            return SavedPostsModel(items: items)
        } catch {
            guard epoch == accountEpoch else { return nil }
            handleSocialReadError(error)
            return nil
        }
    }

    // MARK: - Errors on reads

    /// A read that failed: a dead session and a suspension are the model's business; anything
    /// else is the caller's quiet empty/failed state.
    func handleSocialReadError(_ error: Error) {
        guard !error.isCancellation, let apiError = error as? APIError else { return }
        switch apiError {
        case .suspended: accountSuspended = true
        case .unauthorized: handleSessionExpired()
        default: break
        }
    }
}
