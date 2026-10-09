import Foundation
import Observation

/// Unconfirmed consumer intent is durable before HTTP starts. This contains no token and lives
/// only in the current account's excluded-from-backup directory.
@MainActor
@Observable
final class MutationJournal {
    struct Entry: Codable, Equatable, Sendable {
        let command: String
        let title: String
        let intentData: Data
        let mutation: MutationStamp
        let coalescingKey: String?
        let at: Int64
    }

    enum JournalError: Error { case noCurrentOwner, immutableOperation, corruptJournal, persistenceFailure }
    private let storage: AccountLocalStore
    private var owner: AccountLocalStore.Snapshot?
    private(set) var entries: [Entry] = []
    private(set) var restoreFailed = false
    private let filename = "mutation-journal.json"

    init(storage: AccountLocalStore? = nil) { self.storage = storage ?? .shared }

    func activate(owner: AccountLocalStore.Snapshot?) {
        self.owner = owner
        entries = []
        restoreFailed = false
        guard storage.matches(owner), let owner else { return }
        guard let data = storage.read(filename, owner: owner) else {
            restoreFailed = FileManager.default.fileExists(atPath: owner.file(filename).path)
            return
        }
        do { entries = try JSONDecoder().decode([Entry].self, from: data) }
        catch { restoreFailed = true }
    }

    /// Detach memory. AccountLocalStore owns file removal on actual account teardown.
    func reset() {
        owner = nil
        entries = []
        restoreFailed = false
    }

    @discardableResult
    func stage(command: String, title: String, intentData: Data, mutation: MutationStamp,
               coalescingKey: String? = nil) throws -> Bool {
        guard storage.matches(owner) else { throw JournalError.noCurrentOwner }
        guard !restoreFailed else { throw JournalError.corruptJournal }
        var next = entries
        if let existing = next.first(where: { $0.mutation.operationID == mutation.operationID }) {
            guard existing.mutation == mutation, existing.intentData == intentData,
                  existing.coalescingKey == coalescingKey else { throw JournalError.immutableOperation }
            // Retry reuses the exact stored intent, including its creation ordering.
            try commit(next)
            return true
        }
        if let key = coalescingKey {
            let sameResource = next.filter { $0.coalescingKey == key && $0.mutation.writerID == mutation.writerID }
            if sameResource.contains(where: { $0.mutation.sequence > mutation.sequence }) { return false }
            next.removeAll { $0.coalescingKey == key && $0.mutation.writerID == mutation.writerID
                && $0.mutation.sequence <= mutation.sequence }
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let at = max(now, (next.map(\.at).max() ?? 0) + 1)
        next.append(Entry(command: command, title: title, intentData: intentData, mutation: mutation,
                          coalescingKey: coalescingKey, at: at))
        try commit(next)
        return true
    }

    /// An old receipt cannot retire a newer intent; an old owner cannot touch a new account.
    @discardableResult
    func acknowledge(_ mutation: MutationStamp, owner: AccountLocalStore.Snapshot?) -> Bool {
        guard owner == self.owner, storage.matches(owner) else { return false }
        guard let entry = entries.first(where: { $0.mutation.operationID == mutation.operationID }) else { return false }
        guard entry.mutation == mutation else { return false }
        do {
            try commit(entries.filter { $0.mutation.operationID != mutation.operationID })
            return true
        } catch { return false }
    }

    @discardableResult
    func discard(operationID: UUID, owner: AccountLocalStore.Snapshot?) -> Bool {
        guard owner == self.owner, storage.matches(owner) else { return false }
        guard !restoreFailed, entries.contains(where: { $0.mutation.operationID == operationID }) else { return false }
        do {
            try commit(entries.filter { $0.mutation.operationID != operationID })
            return true
        } catch { return false }
    }

    @discardableResult
    func discardAll(owner: AccountLocalStore.Snapshot?) -> Bool {
        guard owner == self.owner, storage.matches(owner) else { return false }
        do { try commit([]); return true } catch { return false }
    }

    private func commit(_ next: [Entry]) throws {
        guard storage.matches(owner) else { throw JournalError.noCurrentOwner }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Memory advances only after the atomic write, including receipt retirement.
        do { try storage.write(try encoder.encode(next), name: filename, owner: owner) }
        catch { throw JournalError.persistenceFailure }
        entries = next
        restoreFailed = false
    }
}
