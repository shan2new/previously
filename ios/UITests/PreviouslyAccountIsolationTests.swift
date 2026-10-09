import XCTest

@MainActor
final class PreviouslyAccountIsolationTests: XCTestCase {
    func testOldOwnerDelayedWriteCannotRetryWithNewOwnerToken() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "account-delayed-write"); driver.app.terminate() }
        try await driver.begin()
        let bBefore = try await driver.oracle.state("fixture-b")
        try waitForMonitor(driver)
        let oldMonitor = try numericValue(driver, identifier: "qa.network.generation")
        // Keep the server's accepted A request alive beyond sign-out. The client may cancel its
        // response; that cannot undo a server commit, but every request must retain A's identity.
        try await driver.oracle.fault("delay", account: "fixture-a", delayMs: 25_000)
        try driver.openAnime()
        try driver.markNext()
        try await driver.oracle.waitForFault("delay", path: "/me/progress", account: "fixture-a", inFlight: true)
        try driver.assertValue("4", identifier: "qa.journal.progress.1001")
        try signOutAAndSignInB(driver)
        try driver.assertAbsent("qa.journal.progress.1001")
        try waitForMonitor(driver)
        XCTAssertGreaterThan(try numericValue(driver, identifier: "qa.network.generation"), oldMonitor)
        driver.record("assert-monitor-restart", "qa.network.callbacks", "passed", "New monitor generation delivered a real NWPathMonitor callback after A logout and B login.")
        let bSignedIn = try await driver.oracle.state("fixture-b")
        XCTAssertEqual(bSignedIn.progress, bBefore.progress)
        XCTAssertEqual(bSignedIn.ownership, bBefore.ownership)
        try await driver.oracle.waitForFault("delay", path: "/me/progress", account: "fixture-a", inFlight: false, timeout: 28)
        let bAfter = try await driver.oracle.state("fixture-b")
        XCTAssertEqual(bAfter.progress, bBefore.progress)
        XCTAssertEqual(bAfter.progressCommits, bBefore.progressCommits)
        XCTAssertEqual(bAfter.mutationAttempts, bSignedIn.mutationAttempts)
        let requests = try await driver.oracle.requests()
        XCTAssertFalse(requests.contains { $0.account == "fixture-b" && $0.method == "PUT" && $0.path == "/me/progress" },
                       "An old A progress request acquired B's credential, even if B's route refused it.")
        try driver.openProfile()
        try driver.assertAbsent("qa.sync.pending.progress.1001")
        try driver.assertAbsent("qa.sync.retry.progress.1001")
        try driver.tap("qa.profile.done")
        driver.app.terminate()
        try await driver.launch(account: "fixture-b")
        try driver.require("qa.account.fixture-b")
        try driver.navigate("library")
        try driver.require("qa.show.qa-plan")
        try driver.assertAbsent("qa.show.qa-anime")
        driver.record("assert-account-transport", "fixture-b", "passed", "No A PUT was authenticated as B; B's canonical progress and ownership survived the held A request and relaunch.")
    }

    func testOldOwnerFailedRetryAndCacheDoNotAppearForNewOwner() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "account-failed-retry"); driver.app.terminate() }
        try await driver.begin()
        let bBefore = try await driver.oracle.state("fixture-b")
        try await driver.oracle.fault("before-commit", account: "fixture-a", remaining: 3)
        try driver.openAnime()
        try driver.markNext()
        try driver.openProfile()
        try driver.assertValue("4", identifier: "qa.sync.pending.progress.1001", timeout: 8)
        try signOutAAndSignInB(driver)
        try driver.openProfile()
        try driver.assertAbsent("qa.sync.pending.progress.1001")
        try driver.assertAbsent("qa.sync.retry.progress.1001")
        try driver.tap("qa.profile.done")
        driver.app.terminate()
        try await driver.launch(account: "fixture-b")
        try driver.require("qa.account.fixture-b")
        try driver.openProfile()
        try driver.assertAbsent("qa.sync.pending.progress.1001")
        try driver.assertAbsent("qa.sync.retry.progress.1001")
        let bAfter = try await driver.oracle.state("fixture-b")
        XCTAssertEqual(bAfter.progress, bBefore.progress)
        XCTAssertEqual(bAfter.ownership, bBefore.ownership)
        XCTAssertEqual(bAfter.progressCommits, bBefore.progressCommits)
        let requests = try await driver.oracle.requests()
        XCTAssertFalse(requests.contains { $0.account == "fixture-b" && $0.method == "PUT" && $0.path == "/me/progress" })
        driver.record("assert-account-retry", "fixture-b", "passed", "A's visible failed intent was cleared on sign-out, remained absent after B relaunch and never attempted a B progress PUT.")
    }

    private func numericValue(_ driver: QADriver, identifier: String) throws -> Int {
        let element = try driver.require(identifier)
        return try XCTUnwrap(Int((element.value as? String) ?? ""))
    }

    private func waitForMonitor(_ driver: QADriver) throws {
        let target = try driver.require("qa.network.callbacks")
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return Int((element.value as? String) ?? "0") ?? 0 > 0
        }
        if !predicate.evaluate(with: target) {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)], timeout: 6)
            XCTAssertEqual(result, .completed, "A restarted reachability monitor never delivered its initial callback.")
        }
        XCTAssertGreaterThan(try numericValue(driver, identifier: "qa.network.callbacks"), 0)
    }

    private func signOutAAndSignInB(_ driver: QADriver) throws {
        if !driver.isAvailable("qa.profile.done") { try driver.openProfile() }
        try driver.tap("qa.signout")
        try driver.tap("qa.signout.confirm")
        try driver.require("qa.signin.dev.field")
        try driver.replaceText("fixture-b", in: "qa.signin.dev.field")
        try driver.tap("qa.signin.dev.submit")
        try driver.requireReady(timeout: 15)
        try driver.require("qa.account.fixture-b")
    }
}
