import Foundation

// Watch sessions on the server (`/me/watch-sessions`, docs/api-contract.md "Watch sessions").
// `RewatchStore` keeps the history and a queue of what the server has not heard (one word per
// session, newest wins); this side sends the queue and folds the server's list back in, so a new
// phone, a reinstall or a new app id gets the history back. The history was device-local until
// 2 Oct 2026 — a session made before then is uploaded by the first sync that does not find it.
extension AppModel {
    /// Sends every queued word. Runs after each change to the history, after a reload, on reconnect
    /// and when an erasure is called off. No-op offline, in an isolated model, while an account
    /// deletion is under way and behind a suspension (every word would answer 403).
    func flushWatchSessions() {
        guard canSyncWatchSessions, rewatchLane == nil else { return }
        let epoch = accountEpoch
        rewatchLane = Task { [weak self] in
            guard let self else { return }
            let drained = await self.drainWatchSessions(epoch: epoch)
            guard epoch == self.accountEpoch else { return }
            self.rewatchLane = nil
            // A word that landed as the last one was acknowledged goes too.
            if drained, RewatchStore.shared.hasPendingWrites { self.flushWatchSessions() }
        }
    }

    /// Sends the queue, then reads the server's list and folds it in. After every successful reload.
    func syncWatchSessions() async {
        guard canSyncWatchSessions else { return }
        let epoch = accountEpoch
        flushWatchSessions()
        if let lane = rewatchLane { await lane.value }
        guard epoch == accountEpoch, canSyncWatchSessions else { return }
        let store = RewatchStore.shared
        let revision = store.revision
        do {
            let remote = try await api.watchSessions()
            guard epoch == accountEpoch else { return }
            store.merge(server: remote.compactMap(WatchSession.init(wire:)), readAt: revision)
        } catch {
            // Kept as it is; the next reload reads again. A server without the route answers 404
            // and the history simply stays on this device.
            if !error.isCancellation {
                AppModel.log.error("watch sessions sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private var canSyncWatchSessions: Bool {
        !isIsolated && !erasing && !accountSuspended && SyncCenter.shared.isOnline
    }

    /// Sends the oldest word until none is left (true) or one fails in a way a retry might fix
    /// (false: kept for the next trigger).
    private func drainWatchSessions(epoch: Int) async -> Bool {
        let store = RewatchStore.shared
        while epoch == accountEpoch, canSyncWatchSessions, let next = store.nextPendingWrite() {
            do {
                switch next.write.kind {
                case .save:
                    // A save whose session is gone was overtaken by a delete; nothing to send.
                    if let session = next.session { try await api.putWatchSession(id: next.id, WatchSessionBody(session)) }
                case .delete:
                    try await api.deleteWatchSession(id: next.id)
                }
                guard epoch == accountEpoch else { return false }
                store.acknowledge(next.id, next.write)
            } catch {
                guard epoch == accountEpoch, !error.isCancellation else { return false }
                switch (error as? APIError)?.status {
                case 410?:
                    store.deletedElsewhere(next.id, next.write)
                case let code? where (400..<500).contains(code) && code != 408 && code != 429:
                    AppModel.log.error("watch session \(next.id.uuidString, privacy: .public) refused: \(code)")
                    store.refuse(next.id, next.write)
                default:
                    return false
                }
            }
        }
        return true
    }
}
