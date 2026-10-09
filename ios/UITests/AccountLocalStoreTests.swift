import XCTest

/// Exercises the production storage implementation in a disposable directory, without launching
/// the app or touching the simulator's account data.
@MainActor
final class AccountLocalStoreTests: XCTestCase {
    func testOwnerSwitchRejectsStaleWritesAndDeletesPreviousFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountLocalStore(directory: directory)
        let a = try XCTUnwrap(storage.activate(accountID: "fixture-a"))
        try storage.write(Data("a-only".utf8), name: "library-cache.json", owner: a)
        let stagedA = try AccountExportStore.write(name: "previously-library.json", data: Data("a-only".utf8),
                                                 owner: a, storage: storage, directory: directory)
        let userSavedCopy = directory.appendingPathComponent("my-saved-library.json")
        try FileManager.default.copyItem(at: stagedA, to: userSavedCopy)
        XCTAssertEqual(storage.read("library-cache.json", owner: a), Data("a-only".utf8))
        let b = try XCTUnwrap(storage.activate(accountID: "fixture-b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        XCTAssertNil(storage.read("library-cache.json", owner: b))
        XCTAssertThrowsError(try AccountExportStore.write(name: "previously-library.json", data: Data("late-a".utf8),
                                                        owner: a, storage: storage, directory: directory))
        try storage.write(Data("late-a".utf8), name: "library-cache.json", owner: a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        XCTAssertNil(storage.read("library-cache.json", owner: b))
        try storage.write(Data("b-only".utf8), name: "library-cache.json", owner: b)
        storage.clearCurrent()
        AccountExportStore.clearTemporaryFiles(directory: directory)
        try storage.write(Data("late-b".utf8), name: "library-cache.json", owner: b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.directory.path))
        XCTAssertNil(storage.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedA.path))
        XCTAssertEqual(try Data(contentsOf: userSavedCopy), Data("a-only".utf8))
        XCTAssertThrowsError(try AccountExportStore.write(name: "previously-library.json", data: Data("late-b".utf8),
                                                        owner: b, storage: storage, directory: directory))
    }

    func testLegacyUnownedDataIsDiscardedInsteadOfMigrated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("Previously")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old-library".utf8).write(to: directory.appendingPathComponent("library-cache.json"))
        for name in ["sessions.json", "sessions.backup.json", "sessions-sync.json"] {
            try Data("old-history".utf8).write(to: legacy.appendingPathComponent(name))
        }
        let storage = AccountLocalStore(directory: directory)
        let owner = try XCTUnwrap(storage.activate(accountID: "first-login"))
        XCTAssertNil(storage.read("library-cache.json", owner: owner))
        XCTAssertNil(storage.read("sessions.backup.json", owner: owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-cache.json").path))
        for name in ["sessions.json", "sessions.backup.json", "sessions-sync.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(name).path))
        }
    }

    func testRelaunchRestoresOnlyRecordedOwnerAndNoOwnerCannotWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AccountLocalStore(directory: directory)
        let a = try XCTUnwrap(first.activate(accountID: "fixture-a"))
        try first.write(Data("owned".utf8), name: "recent-searches.json", owner: a)
        let firstStamp = try XCTUnwrap(MutationStamp.fresh(owner: a, storage: first))
        let restarted = AccountLocalStore(directory: directory)
        try restarted.write(Data("unowned".utf8), name: "recent-searches.json", owner: nil)
        XCTAssertNil(restarted.current)
        let restored = try XCTUnwrap(restarted.activate(accountID: "fixture-a"))
        XCTAssertEqual(restarted.read("recent-searches.json", owner: restored), Data("owned".utf8))
        let relaunchedStamp = try XCTUnwrap(MutationStamp.fresh(owner: restored, storage: restarted))
        XCTAssertEqual(relaunchedStamp.writerID, firstStamp.writerID)
        XCTAssertGreaterThan(relaunchedStamp.sequence, firstStamp.sequence)
        XCTAssertNotEqual(relaunchedStamp.operationID, firstStamp.operationID)
        restarted.clearCurrent()
        let loggedInAgain = try XCTUnwrap(restarted.activate(accountID: "fixture-a"))
        XCTAssertNil(restarted.read("recent-searches.json", owner: loggedInAgain))
        let signedInStamp = try XCTUnwrap(MutationStamp.fresh(owner: loggedInAgain, storage: restarted))
        XCTAssertEqual(signedInStamp.writerID, firstStamp.writerID, "Ordinary logout must preserve account/device writer identity.")
        XCTAssertGreaterThan(signedInStamp.sequence, relaunchedStamp.sequence)
        XCTAssertNil(MutationStamp.fresh(owner: restored, storage: restarted), "A stale owner minted a new mutation.")
        XCTAssertNil(MutationStamp.fresh(owner: nil, storage: restarted))
        let b = try XCTUnwrap(restarted.activate(accountID: "fixture-b"))
        XCTAssertNil(restarted.read("recent-searches.json", owner: b))
        let bStamp = try XCTUnwrap(MutationStamp.fresh(owner: b, storage: restarted))
        XCTAssertNotEqual(bStamp.writerID, firstStamp.writerID)
    }

    func testColdSignedOutCleanupRemovesOwnedCachesWithoutActivatingAnAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let beforeCrash = AccountLocalStore(directory: directory)
        let a = try XCTUnwrap(beforeCrash.activate(accountID: "fixture-a"))
        for name in ["library-cache.json", "sessions.backup.json", "social-pending.json", "recent-searches.json"] {
            try beforeCrash.write(Data("private-a".utf8), name: name, owner: a)
        }
        // A durable deletion/sign-out receipt exists before the interrupted process ran teardown.
        let coldSignedOut = AccountLocalStore(directory: directory)
        XCTAssertNil(coldSignedOut.current)
        coldSignedOut.clearCurrent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        let sameIdentity = try XCTUnwrap(coldSignedOut.activate(accountID: "fixture-a"))
        XCTAssertNil(coldSignedOut.read("library-cache.json", owner: sameIdentity))
        XCTAssertNil(coldSignedOut.read("sessions.backup.json", owner: sameIdentity))
    }
}
