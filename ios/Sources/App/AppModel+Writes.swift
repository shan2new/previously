import SwiftUI

// The write transactions that need more than one AppModel call to be correct. Kept out of
// AppModel.swift so every screen (Library rows, the context menu, Detail's overflow) calls one
// canonical mechanism instead of three near-copies.
extension AppModel {

    /// "Mark series as watched…", after its confirmation — INSTANT, like every other batch mark
    /// (review, 23 Sep: the 20 Sep version froze the page on a spinner until the server answered,
    /// while the same season from the "…" menu wrote on the spot, signed differently and undid
    /// differently). Every released episode of every chosen season is marked at once, the status
    /// follows (`WatchedBatch.status`: Watched when nothing is left airing, else Watching), ONE
    /// `.success` signs it, and ONE lane Undo restores every part — and the membership, for a show
    /// that was not in the library.
    ///
    /// A show in the library writes through the per-part lanes (`setProgress`), so the server ends
    /// on the user's last word as it does for any other mark, and a failure stays on screen with a
    /// Retry (a mark never rolls back). A show NOT in the library takes the one-call endpoint —
    /// membership, progress and status in one transaction — and a failure rolls the membership
    /// back, as every membership write does.
    func markWatched(_ f: Franchise, batch: WatchedBatch) {
        guard !batch.parts.isEmpty else { return }
        let fact = Copy.Toast.batchWatched(batch.episodeCount, films: batch.filmCount)
        if isInLibrary(f.id) {
            let previousStatus = f.effectiveStatus
            for value in batch.parts {
                setProgress(franchiseId: f.id, mediaId: value.mediaId, episodes: value.episodes, haptic: false)
            }
            let moves = batch.status != previousStatus
            if moves { setStatus(franchiseId: f.id, status: batch.status, haptic: false, present: false) }
            FeedbackCoordinator.fire(.success)
            // A status the batch changed is told on the same receipt, never silently — on its
            // second line, so neither fact is cut.
            var receipt = UndoState(mediaId: nil, franchiseId: f.id, prevProgress: 0, title: f.title,
                                    episode: 0, count: batch.episodeCount, customMessage: fact) { [weak self] in
                for value in batch.previous {
                    self?.setProgress(franchiseId: f.id, mediaId: value.mediaId, episodes: value.episodes, haptic: false)
                }
                if moves { self?.setStatus(franchiseId: f.id, status: previousStatus, haptic: false, present: false) }
            }
            if moves { receipt.subtitle = Copy.Toast.movedTo(batch.status.displayName) }
            presentUndo(receipt)
            return
        }
        // Not in the library: drawn now, made canonical by the one-call write. The mark and its
        // Undo are queued on the show's chain, so an Undo tapped before the mark has landed is
        // sent after it. An unknown mark receipt may already have committed, so Undo remains
        // a durable newer intent even when the original request failed.
        guard !savingProgressFor.contains(f.id) else { return }
        let mutation: MutationStamp?
        do { mutation = try prepareBatchMutation(f, parts: batch.parts, status: batch.status) }
        catch {
            recordBatchFailure(franchiseId: f.id, title: f.title, parts: batch.parts, status: batch.status, error: error)
            return
        }
        var local = f
        for value in batch.parts { local = local.withUpdatedProgress(mediaId: value.mediaId, episodes: value.episodes) }
        insertPending(local.withStatus(batch.status))
        FeedbackCoordinator.fire(.success)
        var receipt = UndoState(mediaId: nil, franchiseId: f.id, prevProgress: 0, title: f.title,
                                episode: 0, count: batch.episodeCount, customMessage: fact) { [weak self] in
            guard let self else { return }
            let undoMutation: MutationStamp?
            do { undoMutation = try self.prepareBatchMutation(f, parts: batch.previous, status: nil, removeMembership: true) }
            catch {
                self.recordBatchFailure(franchiseId: f.id, title: f.title, parts: batch.previous,
                    status: nil, removeMembership: true, error: error)
                return
            }
            self.withdrawPending(f.id)
            self.enqueueBatch(f.id) { [weak self] in
                guard let self else { return }
                do {
                    try await self.saveProgressBatch(f, parts: batch.previous, status: nil,
                        removeMembership: true, mutation: undoMutation)
                } catch {
                    self.recordBatchFailure(franchiseId: f.id, title: f.title, parts: batch.previous,
                                            status: nil, removeMembership: true, error: error)
                }
            }
        }
        receipt.subtitle = Copy.Toast.addedTo(batch.status.displayName)
        presentUndo(receipt)
        enqueueBatch(f.id) { [weak self] in
            guard let self else { return }
            do {
                try await self.saveProgressBatch(f, parts: batch.parts, status: batch.status, mutation: mutation)
            } catch {
                guard !error.isCancellation else { return }
                self.withdrawPending(f.id)
                if let cur = self.undo, cur.franchiseId == f.id { self.undo = nil }
                self.recordBatchFailure(franchiseId: f.id, title: f.title, parts: batch.parts,
                                        status: batch.status, error: error)
            }
        }
    }

    // MARK: - Remove from Library

    /// Remove a show, with Undo. No confirmation dialog: remove is reversible for 6 s (10 s under
    /// VoiceOver) and never touches watch history — the server deletes only the subscription row,
    /// so every progress row survives and Undo brings the ticks back exactly.
    /// One haptic for the whole transaction (`.commitLight`), fired inside `removeFromLibrary`.
    func removeWithUndo(_ f: Franchise, reduceMotion: Bool) {
        let snapshot = f.snapshotForUndo
        let previousStatus = f.effectiveStatus
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
            removeFromLibrary(franchiseId: f.id, haptic: true)
        }
        // Presented immediately: unlike a mark, a removal has no handoff to wait for.
        presentUndo(UndoState(mediaId: nil, franchiseId: f.id, prevProgress: 0, title: f.title, episode: 0,
                              removed: true, removedFranchise: snapshot, prevStatus: previousStatus))
    }

    // MARK: - Mark through an episode

    /// Move a part's progress to `episode` and present ONE undo that reports the real count and
    /// restores the exact prior value.
    ///
    /// The three halves of this were broken separately and had to be fixed together:
    ///   • `setProgress` creates no `UndoState` at all, so Today's "Mark through episode N" — a
    ///     multi-episode write, reached from a menu, with no confirmation — was **unreversible**.
    ///   • `markCaughtUp` left `UndoState.count` at 1, so a six-episode batch confirmed one.
    ///   • `UndoState.undoAction`, minted for multi-write undo, had no call site, which is also what
    ///     blocked a series-level "mark as watched" from ever being offered.
    ///
    /// One transaction, one haptic (fired inside `setProgress`), one toast, one restoring action.
    /// Returns the state it presented so a caller that owns a handoff can defer the toast instead.
    @discardableResult
    func markThrough(franchiseId: String, mediaId: Int, episode: Int,
                     present: Bool = true) -> UndoState? {
        guard let f = franchise(id: franchiseId),
              let part = f.parts.first(where: { $0.mediaId == mediaId }) else { return nil }
        let prev = part.progress
        // A releasing part is bounded by what has aired by now (iD17), read in its own calendar —
        // an INCREASE only (`writeCeiling`): a batch to 14 over a row recorded at 12 with five
        // aired must not write backwards to 5.
        let target = min(max(0, episode), part.writeCeiling(now: .nowMs, anchor: f.timeAnchor))
        guard target != prev else { return nil }
        let shelvedAs = target > prev ? resumableStatus(f, part: part) : nil

        setProgress(franchiseId: franchiseId, mediaId: mediaId, episodes: target)

        // The restoring action is captured here, from the value read BEFORE the write, so undo
        // cannot be re-derived (wrongly) from state the write has already changed.
        var state = UndoState(
            mediaId: mediaId, franchiseId: franchiseId, prevProgress: prev,
            title: f.title, episode: target,
            count: max(1, abs(target - prev)),
            undoAction: { [weak self] in
                self?.setProgress(franchiseId: franchiseId, mediaId: mediaId,
                                  episodes: prev, haptic: false)
            })
        resume(shelvedAs, franchiseId: franchiseId, mediaId: mediaId, prevProgress: prev, receipt: &state)
        if present { presentUndo(state) }
        return state
    }

    // MARK: - Undo

    /// The single entry point for the toast's Undo button. Takes the state BY VALUE so a toast
    /// that is still on screen stays actionable even if `self.undo` has already moved on.
    func undoTapped(_ state: UndoState) {
        if let action = state.undoAction {
            undo = nil
            // Undoing a mark is a progress write and signs like the unmark a ring makes.
            let progressUndo = state.mediaId != nil && !state.added && !state.removed
            FeedbackCoordinator.fire(progressUndo ? .commitLight : .selection)
            return action()
        }
        if state.removed { return restoreRemoved(state) }
        performUndo()
    }

    /// Put a removed show back exactly as it was — instantly, from the snapshot, before any
    /// network round-trip. The re-subscribe carries the PREVIOUS status, so a Finished show
    /// returns to the Finished shelf rather than silently becoming Planned.
    private func restoreRemoved(_ state: UndoState, mutation: MutationStamp? = nil) {
        guard let f = state.removedFranchise else { return }
        let generation = accountEpoch
        let stamp = mutation ?? MutationStamp.fresh(owner: accountStorage)
        let owner = accountStorage
        let status = state.prevStatus ?? f.effectiveStatus
        let staged = Result { try stageTrackingMutation(command: Copy.Action.add, title: f.title,
            intent: .subscribe(franchiseId: f.id, title: f.title, status: status.rawValue), mutation: stamp) }
        FeedbackCoordinator.fire(.selection)
        undo = nil
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
            if !library.contains(where: { $0.id == f.id }) { library.append(f) }
        }
        Task {
            do {
                guard generation == accountEpoch else { return }
                guard try staged.get() else { await reload(); return }
                guard isIsolated || stamp != nil else { throw APIError.transport(URLError(.cannotWriteToFile)) }
                _ = try await api.subscribe(franchiseId: f.id, status: status, mutation: stamp)
                guard generation == accountEpoch else { return }
                SyncCenter.shared.acknowledgeMutation(stamp, owner: owner)
                await reload()
            } catch {
                guard generation == accountEpoch, !error.isCancellation else { return }
                // Membership is a fact about the account, so it rolls back; the failure is
                // surfaced once, in the SyncBanner, with a Retry that re-issues exactly this call.
                withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) {
                    library.removeAll { $0.id == f.id }
                }
                fileFailure(command: Copy.Action.add, title: f.title,
                                         reason: Copy.Notice.reason(error),
                                         intent: .subscribe(franchiseId: f.id, title: f.title, status: status.rawValue),
                                         mutation: stamp,
                                         retryable: !((error as? APIError)?.isMutationConflict ?? false)) {
                    self.restoreRemoved(state, mutation: stamp)
                }
            }
        }
    }
}
