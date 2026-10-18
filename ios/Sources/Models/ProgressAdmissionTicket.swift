import Foundation

/// A confirmation owns the exact selection and the session that requested it. Consuming or
/// cancelling it is synchronous, before any journal or network mutation can begin.
struct ProgressAdmissionTicket: Sendable {
    let parts: [FranchiseProgressValue]
    private let accountID: String?
    private let accountEpoch: Int
    private var pending = true

    init(parts: [FranchiseProgressValue], accountID: String?, accountEpoch: Int) {
        self.parts = parts
        self.accountID = accountID
        self.accountEpoch = accountEpoch
    }

    mutating func cancel() { pending = false }

    mutating func accept(accountID: String?, accountEpoch: Int) -> [FranchiseProgressValue]? {
        guard pending else { return nil }
        pending = false
        guard self.accountID == accountID, self.accountEpoch == accountEpoch else { return nil }
        return parts
    }
}
