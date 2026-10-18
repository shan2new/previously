import Foundation

/// Ephemeral UI state only. The accepted operation is persisted by the existing batch journal
/// before dispatch; cancelled confirmations never enter that journal.
@MainActor
final class LibraryProgressAdmission {
    let franchise: Franchise
    let batch: WatchedBatch
    let message: String
    let receiptMessage: String
    private var ticket: ProgressAdmissionTicket

    init(franchise: Franchise, batch: WatchedBatch, message: String,
         accountID: String?, accountEpoch: Int) {
        self.franchise = franchise
        self.batch = batch
        self.message = message
        let unmarking = zip(batch.parts, batch.previous).allSatisfy { $0.0.episodes <= $0.1.episodes }
        receiptMessage = unmarking
            ? Copy.Toast.batchUnmarked(max(1, batch.episodeCount + batch.filmCount))
            : Copy.Toast.batchWatched(batch.episodeCount, films: batch.filmCount)
        ticket = ProgressAdmissionTicket(parts: batch.parts, accountID: accountID, accountEpoch: accountEpoch)
    }

    func cancel() { ticket.cancel() }

    fileprivate func take(accountID: String?, accountEpoch: Int) -> [FranchiseProgressValue]? {
        ticket.accept(accountID: accountID, accountEpoch: accountEpoch)
    }
}

extension AppModel {
    /// Both catalogues share the same episode controls and account membership contract.
    /// An existing library show keeps its normal immediate mark/confirmation flow.
    func libraryProgressAdmission(_ f: Franchise, parts: [FranchiseProgressValue],
                                  message: String) -> LibraryProgressAdmission? {
        guard !isInLibrary(f.id), !erasing, !accountSuspended,
              currentAccountID != nil || isIsolated,
              let batch = WatchedBatch(franchise: f, selectedProgress: parts, now: now) else { return nil }
        return LibraryProgressAdmission(franchise: f, batch: batch, message: message,
                                        accountID: currentAccountID, accountEpoch: accountEpoch)
    }

    func acceptLibraryProgress(_ admission: LibraryProgressAdmission) {
        guard !erasing, !accountSuspended,
              admission.take(accountID: currentAccountID, accountEpoch: accountEpoch) != nil else { return }
        // Membership and every selected progress value are one durable, retryable transaction.
        // There is no separate subscribe race or closure lost between "add" and "continue".
        markWatched(admission.franchise, batch: admission.batch, receiptMessage: admission.receiptMessage)
    }
}
