import XCTest

/// Actual production queue and receipt handling; each test uses its own temporary account store.
@MainActor
final class RewatchStoreTests: XCTestCase {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func acknowledgeAll(_ store: RewatchStore, applied: Bool = true) throws {
        var count = 0
        while let next = store.nextPendingWrite() {
            store.acknowledge(next.id, next.write, applied: applied)
            count += 1
            XCTAssertLessThan(count, 10, "Queue failed to make progress.")
        }
    }

    func testSupersededReceiptRequiresCanonicalReadAndPersistsItsResult() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RewatchStore(directory: directory)
        let active = store.startRewatch(franchiseId: "qa-anime", scope: .franchise, startedAt: 100, episodes: 12)
        try acknowledgeAll(store, applied: false)
        XCTAssertFalse(store.hasUnsentWrites)
        XCTAssertTrue(store.needsCanonicalRead)
        XCTAssertTrue(store.hasPendingWrites)
        var canonical = active
        canonical.cancelledAt = 200
        canonical.cancelledAtEpisode = 6
        let remote = store.sessions.map { $0.id == active.id ? canonical : $0 }
        XCTAssertTrue(store.merge(server: remote, readAt: store.revision))
        XCTAssertFalse(store.needsCanonicalRead)
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertNil(store.activeSession(for: "qa-anime"))
        XCTAssertEqual(store.sessions.first { $0.id == active.id }, canonical)
        let relaunched = RewatchStore(directory: directory)
        XCTAssertEqual(relaunched.sessions.first { $0.id == active.id }, canonical)
        XCTAssertFalse(relaunched.needsCanonicalRead)
    }

    func testCanonicalReadRequirementSurvivesColdLaunchAndReceiptParsing() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RewatchStore(directory: directory)
        store.startRewatch(franchiseId: "qa-anime", scope: .franchise, startedAt: 100, episodes: 12)
        try acknowledgeAll(store, applied: false)
        let relaunched = RewatchStore(directory: directory)
        XCTAssertTrue(relaunched.needsCanonicalRead)
        XCTAssertFalse(relaunched.hasUnsentWrites)
        XCTAssertTrue(relaunched.merge(server: [], readAt: relaunched.revision))
        XCTAssertTrue(relaunched.sessions.isEmpty, "Canonical deletion must remove formerly acknowledged local history.")
        XCTAssertFalse(relaunched.needsCanonicalRead)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1/watch-sessions"))
        for (header, expected) in [(nil, true), ("true", true), ("false", false), ("FALSE", false)] as [(String?, Bool)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil,
                headerFields: header.map { ["X-Previously-Applied": $0] }))
            XCTAssertEqual(WatchSessionMutationReceipt.applied(response), expected)
        }
    }

    func testCanonicalReadCannotOverwriteNewerLocalIntentOrSignedOutOwner() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RewatchStore(directory: directory)
        let active = store.startRewatch(franchiseId: "qa-anime", scope: .franchise, startedAt: 100, episodes: 12)
        try acknowledgeAll(store, applied: false)
        let beforeRead = store.revision
        let staleServer = store.sessions
        store.setStartDate(active.id, to: 300)
        XCTAssertFalse(store.merge(server: staleServer, readAt: beforeRead))
        XCTAssertTrue(store.needsCanonicalRead)
        XCTAssertEqual(store.sessions.first { $0.id == active.id }?.startedAt, 300)
        let pending = try XCTUnwrap(store.nextPendingWrite())
        XCTAssertEqual(pending.id, active.id)
        XCTAssertNotNil(pending.write.mutation)
        store.acknowledge(pending.id, pending.write)
        var canonical = active
        canonical.startedAt = 300
        XCTAssertTrue(store.merge(server: [canonical], readAt: store.revision))
        XCTAssertFalse(store.needsCanonicalRead)
        let signedOutRevision = store.revision
        store.reset()
        XCTAssertFalse(store.merge(server: staleServer, readAt: signedOutRevision))
        store.acknowledge(pending.id, pending.write, applied: false)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertNil(store.nextPendingWrite())
    }
}
