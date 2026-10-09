import Foundation

/// Identity belongs to a user intent, not a network attempt. Retrying keeps the same stamp.
struct MutationStamp: Codable, Equatable, Sendable {
    let operationID: UUID
    let writerID: UUID
    let sequence: Int64
    var followupOperationID: UUID? = nil
    var followupSequence: Int64? = nil

    var followup: MutationStamp? {
        guard let followupOperationID, let followupSequence else { return nil }
        return MutationStamp(operationID: followupOperationID, writerID: writerID, sequence: followupSequence)
    }

    @MainActor
    func reservingFollowup(owner: AccountLocalStore.Snapshot?) -> MutationStamp? {
        guard let next = Self.fresh(owner: owner), next.writerID == writerID else { return nil }
        var result = self
        result.followupOperationID = next.operationID
        result.followupSequence = next.sequence
        return result
    }

    private struct Clock: Codable {
        var writerID: UUID
        var sequence: Int64
    }

    /// Persist the next sequence before sending. A missing owner or failed local write produces
    /// no stamp; the caller must retain the intent rather than send an unprotected mutation.
    @MainActor
    static func fresh(owner: AccountLocalStore.Snapshot?, storage: AccountLocalStore? = nil) -> MutationStamp? {
        let storage = storage ?? .shared
        guard storage.matches(owner) else { return nil }
        guard let owner else { return nil }
        // Ordering survives ordinary sign-out; this directory contains only the random writer
        // ID and counter, never library content, tokens or pending requests.
        var clocks = owner.directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MutationClocks", isDirectory: true)
        let file = clocks.appendingPathComponent(owner.ownerKey + ".json")
        var clock = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode(Clock.self, from: $0) }
            ?? Clock(writerID: UUID(), sequence: 0)
        guard clock.sequence >= 0, clock.sequence < 9_007_199_254_740_991 else { return nil }
        clock.sequence += 1
        do {
            try FileManager.default.createDirectory(at: clocks, withIntermediateDirectories: true)
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try clocks.setResourceValues(resources)
            try JSONEncoder().encode(clock).write(to: file, options: .atomic)
            return MutationStamp(operationID: UUID(), writerID: clock.writerID, sequence: clock.sequence)
        } catch { return nil }
    }

    @MainActor
    static func clear(accountID: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = support.appendingPathComponent("Previously/MutationClocks")
            .appendingPathComponent(AccountLocalStore.ownerKey(for: accountID) + ".json")
        try? FileManager.default.removeItem(at: file)
    }
}
