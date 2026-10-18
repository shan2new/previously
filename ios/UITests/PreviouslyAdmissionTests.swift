import XCTest

@MainActor
final class PreviouslyAdmissionTests: XCTestCase {
    private let progressPath = "/me/franchises/qa-tv/progress"

    func testCancelUnownedTVEpisodeLeavesMembershipAndProgressUntouched() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "admission-cancel"); driver.app.terminate() }
        try await driver.begin(account: "fixture-b")
        let before = try await driver.oracle.state("fixture-b")
        try openTVEpisodes(driver)
        try driver.tap("qa.episode.2001.5")
        try driver.require("qa.progress.admission.confirm")
        try driver.tap("qa.prompt.cancel")
        try driver.assertAbsent("qa.progress.admission.confirm")
        let after = try await driver.oracle.state("fixture-b")
        XCTAssertEqual(after.progress, before.progress)
        XCTAssertEqual(after.ownership, before.ownership)
        XCTAssertEqual(after.mutationAttempts, before.mutationAttempts)
    }

    func testAcceptUnownedTVNextEpisodeAddsOnceAndExistingShowMarksNormally() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "admission-next"); driver.app.terminate() }
        try await driver.begin(account: "fixture-b")
        try openTVEpisodes(driver)
        try driver.tap("qa.progress.increment.2001")
        try driver.tap("qa.progress.admission.confirm")
        let added = try await driver.oracle.waitForEpisodes(1, mediaID: 2001, account: "fixture-b")
        XCTAssertTrue(added.ownership.contains("qa-tv"))
        XCTAssertEqual(added.progressCommits, 1)
        try driver.assertProgress(1, mediaID: 2001)
        let next = try driver.require("qa.progress.increment.2001")
        let enabled = NSPredicate(format: "enabled == true")
        if !enabled.evaluate(with: next) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: next)], timeout: 6), .completed,
                           "The admission receipt never enabled ordinary progress controls.")
        }
        try driver.tap("qa.progress.increment.2001")
        try driver.assertAbsent("qa.progress.admission.confirm")
        let marked = try await driver.oracle.waitForEpisodes(2, mediaID: 2001, account: "fixture-b")
        XCTAssertEqual(marked.progressCommits, 2)
        let writes = try await driver.oracle.requests().filter { $0.account == "fixture-b" && $0.method == "PUT" && $0.path == progressPath }
        XCTAssertEqual(writes.count, 1, "The accepted admission was submitted more than once.")
    }

    func testAcceptThroughSelectedTVEpisodeDoesNotResetToEpisodeOne() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "admission-through"); driver.app.terminate() }
        try await driver.begin(account: "fixture-b")
        try openTVEpisodes(driver)
        try driver.tap("qa.episode.2001.5")
        try driver.tap("qa.progress.admission.confirm")
        let state = try await driver.oracle.waitForEpisodes(5, mediaID: 2001, account: "fixture-b")
        XCTAssertTrue(state.ownership.contains("qa-tv"))
        XCTAssertEqual(state.progressCommits, 1)
        try driver.assertProgress(5, mediaID: 2001)
        driver.app.terminate()
        try await driver.launch(account: "fixture-b")
        try driver.navigate("library")
        try driver.tap("qa.show.qa-tv")
        try driver.assertProgress(5, mediaID: 2001)
    }

    func testAcceptUnownedTVSeasonKeepsFullSelectedSeason() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "admission-season"); driver.app.terminate() }
        try await driver.begin(account: "fixture-b")
        try openTVEpisodes(driver)
        try driver.tap("qa.progress.season.2001")
        try driver.tap("qa.progress.admission.confirm")
        let state = try await driver.oracle.waitForEpisodes(8, mediaID: 2001, account: "fixture-b")
        XCTAssertTrue(state.ownership.contains("qa-tv"))
        XCTAssertEqual(state.progressCommits, 1)
        XCTAssertEqual(state.subscriptions.first { $0.franchiseId == "qa-tv" }?.status, "completed")
        try driver.assertProgress(8, mediaID: 2001)
    }

    func testToolbarBulkAdmissionUsesSelectedSecondSeasonOnly() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "admission-selected-second-season"); driver.app.terminate() }
        try await driver.begin(account: "fixture-b")
        try driver.navigate("discover")
        try driver.replaceText("multiseason", in: "qa.search.field")
        try driver.openSearchResult("qa-multi-tv")
        try driver.tap("qa.detail.tab.episodes")
        try driver.tap("qa.season.menu.4001")
        try driver.tap("qa.season.pick.4002")
        try driver.require("qa.progress.increment.4002")
        try driver.tap("qa.detail.more")
        try driver.tap("qa.progress.bulk.4002")
        try driver.tap("qa.progress.admission.confirm")
        let state = try await driver.oracle.waitForEpisodes(4, mediaID: 4002, account: "fixture-b")
        XCTAssertTrue(state.ownership.contains("qa-multi-tv"))
        XCTAssertNil(state.episodes(4001), "A Season 2 selection silently marked the earlier season.")
        XCTAssertEqual(state.progressCommits, 1)
        XCTAssertEqual(state.subscriptions.first { $0.franchiseId == "qa-multi-tv" }?.status, "watching")
        try driver.assertProgress(0, mediaID: 4001)
        try driver.assertProgress(4, mediaID: 4002)
    }

    func testFailedAdmissionRetryKeepsExactSelectedProgressAndOperation() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "admission-retry"); driver.app.terminate() }
        try await driver.begin(account: "fixture-b")
        try openTVEpisodes(driver)
        try await driver.oracle.fault("before-commit", account: "fixture-b", path: progressPath, remaining: 3)
        try driver.tap("qa.episode.2001.5")
        try driver.tap("qa.progress.admission.confirm")
        try await driver.oracle.waitForFault("before-commit", path: progressPath, account: "fixture-b", inFlight: false, timeout: 12)
        let failed = try await driver.oracle.waitForRequests(3, method: "PUT", path: progressPath, account: "fixture-b")
        let original = try XCTUnwrap(failed.first?.mutation)
        XCTAssertTrue(failed.allSatisfy { $0.mutation == original })
        let beforeRetry = try await driver.oracle.state("fixture-b")
        XCTAssertFalse(beforeRetry.ownership.contains("qa-tv"))
        XCTAssertNil(beforeRetry.episodes(2001))
        try driver.openProfile()
        let retry = driver.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "qa.sync.retry.")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 6), "The failed admission did not expose a recoverable Retry.")
        try driver.tap(retry.identifier)
        let recovered = try await driver.oracle.waitForEpisodes(5, mediaID: 2001, account: "fixture-b")
        XCTAssertTrue(recovered.ownership.contains("qa-tv"))
        XCTAssertEqual(recovered.progressCommits, 1)
        let attempts = try await driver.oracle.waitForRequests(4, method: "PUT", path: progressPath, account: "fixture-b")
        XCTAssertTrue(attempts.allSatisfy { $0.mutation == original }, "Retry minted a second logical operation.")
    }

    func testCommittedAdmissionLostReceiptHasOneEffect() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "admission-lost-receipt"); driver.app.terminate() }
        try await driver.begin(account: "fixture-b")
        try openTVEpisodes(driver)
        try await driver.oracle.fault("drop-after-commit", account: "fixture-b", path: progressPath)
        try driver.tap("qa.episode.2001.5")
        try driver.tap("qa.progress.admission.confirm")
        let attempts = try await driver.oracle.waitForRequests(2, method: "PUT", path: progressPath, account: "fixture-b")
        let original = try XCTUnwrap(attempts.first?.mutation)
        XCTAssertTrue(attempts.allSatisfy { $0.mutation == original })
        let state = try await driver.oracle.waitForEpisodes(5, mediaID: 2001, account: "fixture-b")
        XCTAssertEqual(state.progressCommits, 1)
        XCTAssertTrue(state.ownership.contains("qa-tv"))
        try driver.assertProgress(5, mediaID: 2001)
    }

    private func openTVEpisodes(_ driver: QADriver) throws {
        try driver.navigate("discover")
        try driver.replaceText("television", in: "qa.search.field")
        try driver.openSearchResult("qa-tv")
        try driver.tap("qa.detail.tab.episodes")
        try driver.require("qa.progress.increment.2001")
    }
}
