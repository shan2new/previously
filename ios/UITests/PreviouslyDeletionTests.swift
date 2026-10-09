import XCTest

/// Destructive actions are confined to the app's separate QA bundle and synthetic fixture accounts.
@MainActor
final class PreviouslyDeletionTests: XCTestCase {
    func testAcceptedDeletionShowsManualAppleInstructionsAfterRelaunch() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "delete-manual-apple-revocation"); driver.app.terminate() }
        try await driver.begin()
        try await driver.oracle.deletionMode("complete", appleRevocation: "manual_required")
        try driver.openProfile()
        try driver.tap("qa.delete.open")
        try driver.tap("qa.delete.confirm")
        try driver.require("qa.signin.dev.field", timeout: 15)
        let notice = try driver.require("account.deletion.notice")
        XCTAssertTrue(notice.label.contains("have been deleted"))
        XCTAssertTrue(notice.label.contains("Sign in with Apple"))
        XCTAssertTrue(notice.label.contains("stop using Sign in with Apple"))
        let state = try await driver.oracle.waitForDeletion("complete")
        XCTAssertTrue(state.erased)
        XCTAssertEqual(state.deletionRequests, 1)
        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.signin.dev.field", timeout: 15)
        XCTAssertTrue(try driver.require("account.deletion.notice").label.contains("stop using Sign in with Apple"))
        driver.record("assert-manual-apple-revocation-notice", "fixture-a", "passed", "Synthetic canonical deletion receipt retained explicit Settings guidance across cold sign-out; no real Apple grant was used.")
    }

    func testCommittedDeleteLostResponseRestoresHoldAndConfirmsComplete() async throws {
        try await lostDeletionResponse(completion: "complete")
    }

    func testCommittedDeleteLostResponseRestoresHoldAndShowsPending() async throws {
        try await lostDeletionResponse(completion: "pending")
    }

    func testProxyForbiddenAfterCommittedDeleteKeepsHoldUntilCanonicalStatus() async throws {
        try await lostDeletionResponse(completion: "complete", fault: "proxy-forbidden-after-commit")
    }

    func testUndefinedEmptySuccessAfterCommittedDeleteKeepsHoldUntilCanonicalStatus() async throws {
        try await lostDeletionResponse(completion: "complete", fault: "empty-success-after-commit")
    }

    private func lostDeletionResponse(completion: String, fault: String = "drop-after-commit") async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "delete-uncertain-\(fault)-\(completion)"); driver.app.terminate() }
        try await driver.begin()
        try await driver.oracle.deletionMode(completion)
        try await driver.oracle.fault(fault, account: "fixture-a", path: "/me")
        try driver.openProfile()
        try driver.tap("qa.delete.open")
        try driver.tap("qa.delete.confirm")
        try driver.require("qa.deletion.recovery", timeout: 25)
        let erased = try await driver.oracle.waitForDeletion(completion)
        XCTAssertTrue(erased.erased)
        XCTAssertTrue(erased.progress.isEmpty)
        XCTAssertTrue(erased.subscriptions.isEmpty)
        XCTAssertEqual(erased.deletionRequests, 1, "The uncertain destructive request must not be silently repeated.")
        let attempts = erased.mutationAttempts
        let ordinary = erased.ordinaryRequestsAfterErasure

        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.deletion.recovery", timeout: 15)
        try driver.assertAbsent("qa.tab.library")
        let held = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(held.deletionRequests, 1)
        XCTAssertEqual(held.mutationAttempts, attempts, "Cold-start recovery sent an ordinary app write before reconciliation.")
        XCTAssertEqual(held.ordinaryRequestsAfterErasure, ordinary, "Cold-start recovery sent ordinary requests into an erased account.")
        try driver.tap("qa.deletion.check")
        try driver.require("qa.signin.dev.field", timeout: 15)
        let notice = try driver.require("account.deletion.notice")
        if completion == "pending" {
            XCTAssertTrue(notice.label.contains("will finish automatically"), "Pending provider cleanup must be communicated honestly.")
            XCTAssertFalse(notice.label.contains("have been deleted"))
        } else {
            XCTAssertTrue(notice.label.contains("have been deleted"))
        }
        let reconciled = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(reconciled.deletionRequests, 1)
        XCTAssertEqual(reconciled.deletionStatusReads, 1)
        XCTAssertEqual(reconciled.mutationAttempts, attempts)
        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.signin.dev.field", timeout: 15)
        try driver.assertAbsent("qa.deletion.recovery")
        let signedOut = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(signedOut.mutationAttempts, attempts, "Confirmed sign-out did not survive a process restart.")
        driver.record("assert-deletion-recovery", completion, "passed", "Erased fixture state, durable hold, one DELETE, status-only reconciliation and honest sign-out notice.")
    }

    func testDefinitiveRefusalResumesTrackingAndLeavesNoHold() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "delete-refused"); driver.app.terminate() }
        try await driver.begin()
        try await driver.oracle.deletionMode("refuse-next")
        try driver.openProfile()
        try driver.tap("qa.delete.open")
        try driver.tap("qa.delete.confirm")
        try driver.tap("qa.delete.error.done")
        try driver.tap("qa.profile.done")
        try driver.openAnime()
        try driver.assertProgress(3)
        try driver.markNext()
        _ = try await driver.oracle.waitForEpisodes(4, mediaID: 1001, account: "fixture-a")
        let live = try await driver.oracle.state("fixture-a")
        XCTAssertFalse(live.erased)
        XCTAssertEqual(live.deletionStatus, "active")
        XCTAssertEqual(live.deletionRequests, 1)
        driver.app.terminate()
        try await driver.launch()
        try driver.assertAbsent("qa.deletion.recovery")
        try driver.openAnime()
        try driver.assertProgress(4)
        driver.record("assert-deletion-refused", "fixture-a", "passed", "Explicit refusal resumed a verified progress write and cold launch carries no deletion hold.")
    }

    func testAcceptedPendingDeletionShowsNoticeAndSignsOut() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "delete-pending"); driver.app.terminate() }
        try await driver.begin()
        try await driver.oracle.deletionMode("pending")
        try driver.openProfile()
        try driver.tap("qa.delete.open")
        try driver.tap("qa.delete.confirm")
        try driver.require("qa.signin.dev.field", timeout: 15)
        let notice = try driver.require("account.deletion.notice")
        XCTAssertTrue(notice.label.contains("will finish automatically"))
        XCTAssertFalse(notice.label.contains("have been deleted"))
        let state = try await driver.oracle.waitForDeletion("pending")
        XCTAssertTrue(state.erased)
        XCTAssertTrue(state.progress.isEmpty)
        XCTAssertEqual(state.deletionRequests, 1)
        XCTAssertEqual(state.deletionStatusReads, 0)
        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.signin.dev.field", timeout: 15)
        try driver.assertAbsent("qa.deletion.recovery")
        driver.record("assert-deletion-pending", "fixture-a", "passed", "202 removes tracking data, signs out and states provider cleanup is pending.")
    }
}
