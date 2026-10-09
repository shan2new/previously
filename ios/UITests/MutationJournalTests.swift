import XCTest

/// Exercises the production journal with real atomic files. No network attempt is eligible
/// until staging succeeds; receipt retirement must also survive a process restart.
@MainActor
final class MutationJournalTests: XCTestCase {
    private let writerID = UUID(uuidString: "c941ce61-6793-4392-b692-5eef1f3bc4d8")!

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func stamp(sequence: Int64, followup: Bool = false) -> MutationStamp {
        var mutation = MutationStamp(operationID: UUID(), writerID: writerID, sequence: sequence)
        if followup {
            mutation.followupOperationID = UUID()
            mutation.followupSequence = sequence + 1
        }
        return mutation
    }

    /// A regular file at the account directory deterministically rejects a file write, including
    /// on machines where chmod would be bypassed. Preserve the old directory for cold-restore proof.
    private func withBlockedWrites(owner: AccountLocalStore.Snapshot, scratch: URL,
                                   _ body: () throws -> Void) throws {
        let manager = FileManager.default
        let preserved = scratch.appendingPathComponent("preserved-account-" + UUID().uuidString)
        try manager.moveItem(at: owner.directory, to: preserved)
        defer {
            try? manager.removeItem(at: owner.directory)
            if manager.fileExists(atPath: preserved.path) {
                try? manager.moveItem(at: preserved, to: owner.directory)
            }
        }
        try Data("writes-blocked".utf8).write(to: owner.directory)
        try body()
    }

    func testStagingSuccessRestoresCompleteMutationAndIntentOnColdLaunch() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountLocalStore(directory: directory)
        let owner = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        let journal = MutationJournal(storage: storage)
        journal.activate(owner: owner)
        let mutation = stamp(sequence: 7, followup: true)
        let payload = Data(#"{"parts":[{"mediaId":1001,"episodes":4}],"removeMembership":true}"#.utf8)
        XCTAssertTrue(try journal.stage(command: "Undo", title: "Fixture Anime", intentData: payload,
                                        mutation: mutation, coalescingKey: "batch:qa-anime"))

        // Reconstruct both production objects, without copying their in-memory entries.
        let coldStorage = AccountLocalStore(directory: directory)
        let coldOwner = try XCTUnwrap(coldStorage.activate(accountID: "fixture-a"))
        let coldJournal = MutationJournal(storage: coldStorage)
        coldJournal.activate(owner: coldOwner)
        let restored = try XCTUnwrap(coldJournal.entries.first)
        XCTAssertEqual(coldJournal.entries.count, 1)
        XCTAssertEqual(restored.command, "Undo")
        XCTAssertEqual(restored.title, "Fixture Anime")
        XCTAssertEqual(restored.intentData, payload)
        XCTAssertEqual(restored.mutation, mutation, "A retry must keep its operation, writer, sequence and reserved followup.")
        XCTAssertEqual(restored.coalescingKey, "batch:qa-anime")
        XCTAssertGreaterThan(restored.at, 0)
        XCTAssertTrue(coldJournal.acknowledge(mutation, owner: coldOwner))
        let afterReceipt = MutationJournal(storage: coldStorage)
        afterReceipt.activate(owner: coldOwner)
        XCTAssertTrue(afterReceipt.entries.isEmpty)
    }

    func testOlderReceiptCannotRetireNewerCoalescedIntentOrRewriteSameOperation() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountLocalStore(directory: directory)
        let owner = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        let journal = MutationJournal(storage: storage)
        journal.activate(owner: owner)
        let old = stamp(sequence: 10)
        let latest = stamp(sequence: 11)
        let unrelated = stamp(sequence: 12)
        let oldPayload = Data(#"{"mediaId":1001,"episodes":4}"#.utf8)
        let latestPayload = Data(#"{"mediaId":1001,"episodes":5}"#.utf8)
        XCTAssertTrue(try journal.stage(command: "Mark", title: "Anime", intentData: oldPayload,
                                        mutation: old, coalescingKey: "progress:1001"))
        XCTAssertTrue(try journal.stage(command: "Mark", title: "Anime", intentData: latestPayload,
                                        mutation: latest, coalescingKey: "progress:1001"))
        XCTAssertTrue(try journal.stage(command: "Add", title: "Other", intentData: Data("other".utf8),
                                        mutation: unrelated, coalescingKey: "membership:other"))
        XCTAssertFalse(try journal.stage(command: "Retry", title: "Anime", intentData: oldPayload,
                                         mutation: old, coalescingKey: "progress:1001"),
                       "An old retry must not become eligible to send behind a newer user intent.")
        XCTAssertFalse(journal.acknowledge(old, owner: owner))
        XCTAssertFalse(journal.discard(operationID: old.operationID, owner: owner))
        let mismatchedReceipt = MutationStamp(operationID: latest.operationID,
                                               writerID: latest.writerID, sequence: old.sequence)
        XCTAssertFalse(journal.acknowledge(mismatchedReceipt, owner: owner),
                       "An operation ID alone is insufficient to retire a different stamped intent.")
        XCTAssertThrowsError(try journal.stage(command: "Mark", title: "Anime", intentData: oldPayload,
                                               mutation: latest, coalescingKey: "progress:1001"),
                             "An existing operation ID cannot be reused with a different body.")
        let cold = MutationJournal(storage: storage)
        cold.activate(owner: owner)
        XCTAssertEqual(cold.entries.count, 2)
        XCTAssertEqual(cold.entries.first { $0.mutation.operationID == latest.operationID }?.intentData, latestPayload)
        XCTAssertTrue(cold.acknowledge(latest, owner: owner))
        XCTAssertEqual(cold.entries.map(\.mutation), [unrelated], "One receipt must not retire another resource's intent.")
    }

    func testMissingOrStaleOwnerCannotStageOrAcknowledge() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountLocalStore(directory: directory)
        let journal = MutationJournal(storage: storage)
        let mutation = stamp(sequence: 1)
        let payload = Data("private-a".utf8)
        XCTAssertThrowsError(try journal.stage(command: "Mark", title: "A", intentData: payload,
                                               mutation: mutation, coalescingKey: nil))
        XCTAssertTrue(journal.entries.isEmpty)
        let a = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        journal.activate(owner: a)
        XCTAssertTrue(try journal.stage(command: "Mark", title: "A", intentData: payload,
                                        mutation: mutation, coalescingKey: nil))
        let b = try XCTUnwrap(storage.activate(accountID: "fixture-b"))
        XCTAssertThrowsError(try journal.stage(command: "Mark", title: "Late A", intentData: Data("late-a".utf8),
                                               mutation: stamp(sequence: 2), coalescingKey: nil))
        XCTAssertFalse(journal.acknowledge(mutation, owner: a))
        XCTAssertFalse(journal.acknowledge(mutation, owner: b))
        XCTAssertFalse(journal.discard(operationID: mutation.operationID, owner: a))
        journal.activate(owner: b)
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        XCTAssertFalse(journal.acknowledge(mutation, owner: b))
    }

    func testStagingDiskFailureKeepsLastDurableIntent() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountLocalStore(directory: directory)
        let owner = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        let journal = MutationJournal(storage: storage)
        journal.activate(owner: owner)
        let accepted = stamp(sequence: 3)
        let rejected = stamp(sequence: 4)
        let payload = Data("episode-4".utf8)
        XCTAssertTrue(try journal.stage(command: "Mark", title: "Anime", intentData: payload,
                                        mutation: accepted, coalescingKey: "progress:1001"))
        try withBlockedWrites(owner: owner, scratch: directory) {
            XCTAssertThrowsError(try journal.stage(command: "Mark", title: "Anime", intentData: Data("episode-5".utf8),
                                                   mutation: rejected, coalescingKey: "progress:1001"))
            XCTAssertThrowsError(try journal.stage(command: "Retry", title: "Anime", intentData: payload,
                                                   mutation: accepted, coalescingKey: "progress:1001"),
                                 "An in-memory duplicate alone cannot establish persist-before-send readiness.")
            XCTAssertEqual(journal.entries.map(\.mutation), [accepted])
            XCTAssertEqual(journal.entries.first?.intentData, payload)
        }
        let cold = MutationJournal(storage: storage)
        cold.activate(owner: owner)
        XCTAssertEqual(cold.entries.map(\.mutation), [accepted])
        XCTAssertEqual(cold.entries.first?.intentData, payload)

        // An interrupted/corrupted file must not turn unknown pending work into an empty outbox
        // that the next user action silently overwrites.
        let corruptData = Data("{truncated-journal".utf8)
        try storage.write(corruptData, name: "mutation-journal.json", owner: owner)
        let corrupt = MutationJournal(storage: storage)
        corrupt.activate(owner: owner)
        XCTAssertTrue(corrupt.restoreFailed)
        XCTAssertThrowsError(try corrupt.stage(command: "Mark", title: "Anime", intentData: Data("episode-5".utf8),
                                               mutation: rejected, coalescingKey: "progress:1001"))
        XCTAssertFalse(corrupt.discard(operationID: accepted.operationID, owner: owner))
        XCTAssertEqual(storage.read("mutation-journal.json", owner: owner), corruptData)
        XCTAssertTrue(corrupt.discardAll(owner: owner), "Only explicit discard may resolve unreadable pending work.")
        XCTAssertFalse(corrupt.restoreFailed)
        XCTAssertTrue(try corrupt.stage(command: "Mark", title: "Anime", intentData: Data("episode-5".utf8),
                                        mutation: rejected, coalescingKey: "progress:1001"))
        // A path that exists but cannot be read as file data differs from a missing journal.
        let journalFile = owner.file("mutation-journal.json")
        try FileManager.default.removeItem(at: journalFile)
        try FileManager.default.createDirectory(at: journalFile, withIntermediateDirectories: false)
        let unreadable = MutationJournal(storage: storage)
        unreadable.activate(owner: owner)
        XCTAssertTrue(unreadable.restoreFailed)
        XCTAssertThrowsError(try unreadable.stage(command: "Mark", title: "Anime", intentData: payload,
                                                  mutation: accepted, coalescingKey: "progress:1001"))
    }

    func testAcknowledgementDiskFailureLeavesOperationReplayable() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountLocalStore(directory: directory)
        let owner = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        let journal = MutationJournal(storage: storage)
        journal.activate(owner: owner)
        let mutation = stamp(sequence: 5)
        let payload = Data("episode-6".utf8)
        XCTAssertTrue(try journal.stage(command: "Mark", title: "Anime", intentData: payload,
                                        mutation: mutation, coalescingKey: "progress:1001"))
        try withBlockedWrites(owner: owner, scratch: directory) {
            XCTAssertFalse(journal.acknowledge(mutation, owner: owner))
            XCTAssertFalse(journal.discard(operationID: mutation.operationID, owner: owner))
            XCTAssertEqual(journal.entries.map(\.mutation), [mutation])
        }
        let cold = MutationJournal(storage: storage)
        cold.activate(owner: owner)
        XCTAssertEqual(cold.entries.first?.intentData, payload)
        XCTAssertEqual(cold.entries.first?.mutation, mutation)
        XCTAssertTrue(try cold.stage(command: "Retry", title: "Updated title", intentData: payload,
                                     mutation: mutation, coalescingKey: "progress:1001"),
                      "A lost local acknowledgement must replay the same protected operation.")
        XCTAssertTrue(cold.acknowledge(mutation, owner: owner))
        XCTAssertTrue(cold.entries.isEmpty)
    }

    func testExplicitDiscardPersistsAndAccountTeardownCannotResurrectPendingChanges() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountLocalStore(directory: directory)
        let owner = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        let journal = MutationJournal(storage: storage)
        journal.activate(owner: owner)
        let discarded = stamp(sequence: 1)
        let retained = stamp(sequence: 2)
        XCTAssertTrue(try journal.stage(command: "Mark", title: "Discarded", intentData: Data("discard".utf8),
                                        mutation: discarded, coalescingKey: nil))
        XCTAssertTrue(try journal.stage(command: "Mark", title: "Retained", intentData: Data("retain".utf8),
                                        mutation: retained, coalescingKey: nil))
        XCTAssertTrue(journal.discard(operationID: discarded.operationID, owner: owner))
        let cold = MutationJournal(storage: storage)
        cold.activate(owner: owner)
        XCTAssertEqual(cold.entries.map(\.mutation), [retained])
        cold.reset()
        XCTAssertTrue(cold.entries.isEmpty)
        let stillOwned = MutationJournal(storage: storage)
        stillOwned.activate(owner: owner)
        XCTAssertEqual(stillOwned.entries.map(\.mutation), [retained], "Detach alone must not discard an unsent intent.")
        storage.clearCurrent()
        stillOwned.reset()
        XCTAssertFalse(stillOwned.acknowledge(retained, owner: owner))
        let signedInAgain = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        let afterSignOut = MutationJournal(storage: storage)
        afterSignOut.activate(owner: signedInAgain)
        XCTAssertTrue(afterSignOut.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.directory.path))
    }
}
