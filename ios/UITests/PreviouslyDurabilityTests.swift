import XCTest

/// Process termination is synchronized against the independent HTTP oracle. These cases kill
/// before a catch or receipt can run, then exercise the actual restored Retry control.
@MainActor
final class PreviouslyDurabilityTests: XCTestCase {
    func testKillBeforeCatchRestoresOriginalDurableProgress() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "kill-before-catch"); driver.app.terminate() }
        try await driver.begin()
        try driver.openAnime()
        try await driver.oracle.fault("hold-before-commit", account: "fixture-a")
        try driver.markNext()
        try driver.assertValue("4", identifier: "qa.journal.progress.1001")
        let stamp = try savedStamp(driver)
        try await driver.oracle.waitForFault("hold-before-commit", path: "/me/progress", account: "fixture-a", inFlight: true)
        let beforeKill = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(beforeKill.episodes(1001), 3)
        XCTAssertEqual(beforeKill.progressCommits, 0)
        XCTAssertFalse(driver.isAvailable("qa.sync.retry.progress.1001"))
        driver.record("kill-before-catch", "progress.1001", "completed", "Intent4 reached owned atomic journal; request held before commit, no catch/receipt yet.")
        try driver.assertValue("0", identifier: "qa.sync.failure.count")
        driver.app.terminate()
        try await driver.oracle.releaseHeld()
        try await driver.oracle.waitForFault("hold-before-commit", path: "/me/progress", account: "fixture-a", inFlight: false)
        try await retryRestored(driver, episodes: 4, stamp: stamp)
        let final = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(final.progressCommits, 1)
        driver.record("assert-pre-dispatch-durability", "progress.1001", "passed", "Cold Retry preserved original operation/writer/sequence, UI4 and canonical4, one effect.")
    }

    func testKillAfterCommitBeforeReceiptReplaysOriginalOperationOnce() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "kill-before-receipt"); driver.app.terminate() }
        try await driver.begin()
        try driver.openAnime()
        try await driver.oracle.fault("hold-after-commit", account: "fixture-a")
        try driver.markNext()
        try driver.assertValue("4", identifier: "qa.journal.progress.1001")
        let stamp = try savedStamp(driver)
        try await driver.oracle.waitForFault("hold-after-commit", path: "/me/progress", account: "fixture-a", inFlight: true)
        let committed = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(committed.episodes(1001), 4)
        XCTAssertEqual(committed.progressCommits, 1)
        try driver.assertValue("0", identifier: "qa.sync.failure.count")
        driver.app.terminate()
        try await driver.oracle.releaseHeld()
        try await driver.oracle.waitForFault("hold-after-commit", path: "/me/progress", account: "fixture-a", inFlight: false)
        try await retryRestored(driver, episodes: 4, stamp: stamp)
        let final = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(final.progressCommits, 1)
        driver.record("assert-lost-receipt-durability", "progress.1001", "passed", "Committed receipt was withheld until process died; same-stamp cold Retry produced no extra effect.")
    }

    func testKillWithNewerQueuedProgressRetainsNewestDurableIntent() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "kill-with-newer-queued-intent"); driver.app.terminate() }
        try await driver.begin()
        try driver.openAnimeEpisodes()
        try await driver.oracle.fault("hold-before-commit", account: "fixture-a")
        try driver.tap("qa.progress.increment.1001")
        try driver.assertValue("4", identifier: "qa.journal.progress.1001")
        let older = try savedStamp(driver)
        try await driver.oracle.waitForFault("hold-before-commit", path: "/me/progress", account: "fixture-a", inFlight: true)
        try driver.tap("qa.progress.increment.1001")
        try driver.assertProgress(5)
        try driver.assertValue("5", identifier: "qa.journal.progress.1001")
        let newer = try savedStamp(driver)
        XCTAssertNotEqual(newer, older)
        let beforeKill = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(beforeKill.episodes(1001), 3)
        try driver.assertValue("0", identifier: "qa.sync.failure.count")
        driver.app.terminate()
        try await driver.oracle.releaseHeld()
        try await driver.oracle.waitForFault("hold-before-commit", path: "/me/progress", account: "fixture-a", inFlight: false)
        try await retryRestored(driver, episodes: 5, stamp: newer)
        let final = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(final.progressCommits, 1)
        let completed = try await driver.oracle.requests().filter {
            $0.method == "PUT" && $0.path == "/me/progress" && $0.account == "fixture-a" && $0.outcome == "200"
        }
        XCTAssertFalse(completed.contains { stampValue($0.mutation) == older })
        driver.record("assert-newer-durable-intent", "progress.1001", "passed", "QueuedP5 replaced journalP4 before dispatch; process died before catch; originalP5stamp reached canonical5 without old effect.")
    }

    private func savedStamp(_ driver: QADriver) throws -> String {
        let element = try driver.require("qa.journal.stamp.1001")
        return try XCTUnwrap(element.value as? String)
    }

    private func retryRestored(_ driver: QADriver, episodes: Int, stamp: String) async throws {
        try await driver.launch()
        try driver.assertValue(String(episodes), identifier: "qa.journal.progress.1001")
        XCTAssertEqual(try savedStamp(driver), stamp)
        try driver.openProfile()
        try driver.assertValue(String(episodes), identifier: "qa.sync.pending.progress.1001")
        try driver.tap("qa.sync.retry.progress.1001")
        _ = try await driver.oracle.waitForEpisodes(episodes, mediaID: 1001, account: "fixture-a")
        try driver.assertAbsent("qa.sync.pending.progress.1001")
        try driver.assertAbsent("qa.journal.progress.1001")
        try driver.tap("qa.profile.done")
        try driver.openAnime()
        try driver.assertProgress(episodes)
        let requests = try await driver.oracle.waitForRequests(1, method: "PUT", path: "/me/progress", account: "fixture-a")
        let successful = requests.filter { $0.outcome == "200" }
        XCTAssertFalse(successful.isEmpty)
        XCTAssertTrue(successful.allSatisfy { stampValue($0.mutation) == stamp }, "Cold Retry changed the staged mutation identity.")
    }

    private func stampValue(_ stamp: QAOracle.MutationRecord?) -> String? {
        stamp.map { "\($0.operationID)|\($0.writerID)|\($0.sequence)" }
    }
}
