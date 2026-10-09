import Foundation
import CryptoKit

/// Account-owned local files. All writes and removal run synchronously on the main actor:
/// teardown cannot race a detached writer that recreates data after sign-out.
@MainActor
final class AccountLocalStore {
    static let shared = AccountLocalStore()

    struct Snapshot: Equatable, Sendable {
        let ownerKey: String
        let generation: Int
        let directory: URL

        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    }

    private let support: URL
    private let accounts: URL
    private var generation = 0
    private(set) var current: Snapshot?

    init(directory: URL? = nil) {
        support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        accounts = support.appendingPathComponent("Previously/Accounts", isDirectory: true)
    }

    static func ownerKey(for accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func activate(accountID: String?) -> Snapshot? {
        discardLegacyFiles()
        guard let accountID, !accountID.isEmpty else {
            clearCurrent()
            return nil
        }
        let key = Self.ownerKey(for: accountID)
        if let current, current.ownerKey == key { return current }
        generation &+= 1
        let directory = accounts.appendingPathComponent(key, isDirectory: true)
        // An interrupted account switch must not leave another owner's files on this device.
        if let folders = try? FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil) {
            for folder in folders where folder.lastPathComponent != key { try? FileManager.default.removeItem(at: folder) }
        }
        let snapshot = Snapshot(ownerKey: key, generation: generation, directory: directory)
        current = snapshot
        return snapshot
    }

    func matches(_ snapshot: Snapshot?) -> Bool { snapshot != nil && snapshot == current }

    func read(_ name: String, owner: Snapshot?) -> Data? {
        guard let owner, matches(owner) else { return nil }
        return try? Data(contentsOf: owner.file(name))
    }

    func write(_ data: Data, name: String, owner: Snapshot?) throws {
        guard let owner, matches(owner) else { return }
        try FileManager.default.createDirectory(at: owner.directory, withIntermediateDirectories: true)
        // Offline copies and queued changes are account-owned cache data. A device backup must
        // not restore an old copy after the account's local directory has been removed.
        var directory = owner.directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        try data.write(to: owner.file(name), options: .atomic)
    }

    func remove(_ name: String, owner: Snapshot?) {
        guard let owner, matches(owner) else { return }
        try? FileManager.default.removeItem(at: owner.file(name))
    }

    func clearCurrent() {
        generation &+= 1
        // A crash can occur after a durable sign-out/deletion receipt but before teardown has
        // activated an owner on the next launch. Clear all owned caches even when current is nil.
        try? FileManager.default.removeItem(at: accounts)
        current = nil
        discardLegacyFiles()
    }

    private func discardLegacyFiles() {
        // These older files carry no owner. Never migrate them into whichever account logs in
        // first; that would assign the previous user's history and queued writes to a new one.
        for name in ["library-cache.json", "feed-cache.json", "social-pending.json",
                     "recommendations-cache.json", "recommendations-feedback.json"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
        let legacySessions = support.appendingPathComponent("Previously", isDirectory: true)
        for name in ["sessions.json", "sessions.backup.json", "sessions-sync.json"] {
            try? FileManager.default.removeItem(at: legacySessions.appendingPathComponent(name))
        }
        for key in ["recentSearches", "recentSearchItems", "previously.import.progress", "previously.audience",
                    "previously.audience.pending", "previously.firstRun.pending", "previously.forYouStageDay",
                    "previously.forYouStageKey", "previously.recommendationsUnavailableUntil",
                    "profile.snapshot.counts", "profile.snapshot.covers", "resumedReturningParts"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
