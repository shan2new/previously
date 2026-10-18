import XCTest

/// Exercises actual AppModel publication/lifecycle and the production guarded reader in the QA
/// app's own sandbox. No real App Group, device account or WidgetKit host is manipulated.
@MainActor
final class PreviouslyWidgetTests: XCTestCase {
    func testLogoutColdCleanupAndOfflineAccountBNeverExposeAWidget() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "widget-logout-offline-b"); driver.app.terminate() }
        try await driver.begin()
        try assertAWidget(driver)
        try await driver.oracle.fault("offline", account: "fixture-b", path: "/me/library", remaining: 100)

        try driver.openProfile()
        try driver.tap("qa.signout")
        try driver.tap("qa.signout.confirm")
        try driver.require("qa.signin.dev.field")
        try assertClearedWidget(driver)
        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.signin.dev.field", timeout: 15)
        try assertClearedWidget(driver)

        try driver.replaceText("fixture-b", in: "qa.signin.dev.field")
        try driver.tap("qa.signin.dev.submit")
        try driver.require("qa.account.fixture-b", timeout: 15)
        _ = try await driver.oracle.waitForRequests(1, method: "GET", path: "/me/library", account: "fixture-b")
        try assertOfflineBWidget(driver)
        driver.app.terminate()
        try await driver.launch(account: "fixture-b", expectReady: false)
        try driver.require("qa.account.fixture-b", timeout: 15)
        try assertOfflineBWidget(driver)
        let state = try await driver.oracle.state("fixture-b")
        XCTAssertEqual(state.progress.first(where: { $0.mediaId == 3001 })?.episodes, 0)
        driver.record("assert-widget-offline-account-switch", "fixture-b", "passed",
                      "A published through AppModel; logout and signed-out relaunch removed all widget files. B's library transport stayed offline through login/relaunch and the guarded reader never returned A.")
    }

    func testUnconfirmedDeletionClearsWidgetAndColdHoldCannotRestoreIt() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "widget-deletion-hold"); driver.app.terminate() }
        try await driver.begin()
        try assertAWidget(driver)
        try await driver.oracle.deletionMode("complete")
        try await driver.oracle.fault("drop-after-commit", account: "fixture-a", path: "/me")
        try driver.openProfile()
        try driver.tap("qa.delete.open")
        try driver.tap("qa.delete.confirm")
        try driver.require("qa.deletion.recovery", timeout: 25)
        // The response is still unconfirmed: ordinary successful-deletion teardown has not run.
        try assertClearedWidget(driver)
        let erased = try await driver.oracle.waitForDeletion("complete")
        XCTAssertEqual(erased.deletionRequests, 1)

        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.deletion.recovery", timeout: 15)
        try assertClearedWidget(driver)
        let held = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(held.deletionRequests, 1)
        XCTAssertEqual(held.ordinaryRequestsAfterErasure, erased.ordinaryRequestsAfterErasure)
        try driver.tap("qa.deletion.check")
        try driver.require("qa.signin.dev.field", timeout: 15)
        try assertClearedWidget(driver)
        driver.record("assert-widget-deletion-hold", "fixture-a", "passed",
                      "Erasure preparation removed the widget before the lost receipt was reconciled; cold recovery kept it empty and sent no duplicate DELETE.")
    }

    func testDefinitiveDeletionRefusalRestoresCurrentOwnerWithNewGeneration() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "widget-deletion-refused"); driver.app.terminate() }
        try await driver.begin()
        try assertAWidget(driver)
        let before = try value(driver, "qa.widget.generation")
        try await driver.oracle.deletionMode("refuse-next")
        try driver.openProfile()
        try driver.tap("qa.delete.open")
        try driver.tap("qa.delete.confirm")
        try driver.tap("qa.delete.error.done")
        try driver.tap("qa.profile.done")
        try assertAWidget(driver)
        let after = try value(driver, "qa.widget.generation")
        XCTAssertNotEqual(before, after, "A refusal must republish under a new lease after erasure preparation invalidates the old one.")
        XCTAssertNotNil(UUID(uuidString: after))
        let state = try await driver.oracle.state("fixture-a")
        XCTAssertFalse(state.erased)
        XCTAssertEqual(state.deletionRequests, 1)
        driver.app.terminate()
        try await driver.launch()
        try driver.assertAbsent("qa.deletion.recovery")
        try assertAWidget(driver)
        driver.record("assert-widget-deletion-refused", "fixture-a", "passed",
                      "A definitive refusal restored only the still-current account under a fresh widget generation; cold launch carried no deletion hold.")
    }

    func testSameOwnerOfflineColdLaunchRetainsItsValidWidget() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "widget-same-owner-offline"); driver.app.terminate() }
        try await driver.begin()
        try assertAWidget(driver)
        let generation = try value(driver, "qa.widget.generation")
        let beforeRequests = try await driver.oracle.requests().filter {
            $0.account == "fixture-a" && $0.method == "GET" && $0.path == "/me/library"
        }.count
        try await driver.oracle.fault("offline", account: "fixture-a", path: "/me/library", remaining: 100)
        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.account.fixture-a", timeout: 15)
        _ = try await driver.oracle.waitForRequests(beforeRequests + 1, method: "GET", path: "/me/library", account: "fixture-a")
        try assertAWidget(driver)
        try driver.assertValue(generation, identifier: "qa.widget.generation")
        driver.record("assert-widget-same-owner-offline", "fixture-a", "passed",
                      "The same account's valid cached widget remained readable with the same generation while fresh library requests were offline.")
    }

    private func assertAWidget(_ driver: QADriver) throws {
        let owner = AccountLocalStore.ownerKey(for: "fixture-a")
        try driver.assertValue(owner, identifier: "qa.widget.owner", timeout: 10)
        try driver.assertValue(owner, identifier: "qa.widget.activeOwner")
        XCTAssertTrue(try value(driver, "qa.widget.shows").split(separator: ",").contains("qa-anime"))
        XCTAssertNotNil(UUID(uuidString: try value(driver, "qa.widget.generation")))
    }

    private func assertClearedWidget(_ driver: QADriver) throws {
        try driver.assertValue("none", identifier: "qa.widget.owner")
        try driver.assertValue("none", identifier: "qa.widget.activeOwner")
        try driver.assertValue("none", identifier: "qa.widget.shows")
        try driver.assertValue("0", identifier: "qa.widget.files")
    }

    private func assertOfflineBWidget(_ driver: QADriver) throws {
        try driver.assertValue(AccountLocalStore.ownerKey(for: "fixture-b"), identifier: "qa.widget.activeOwner")
        try driver.assertValue("none", identifier: "qa.widget.owner")
        try driver.assertValue("none", identifier: "qa.widget.shows")
        // Only B's owner manifest exists: no snapshot or old artwork was retained.
        try driver.assertValue("1", identifier: "qa.widget.files")
    }

    private func value(_ driver: QADriver, _ identifier: String) throws -> String {
        let element = try driver.require(identifier)
        return try XCTUnwrap(element.value as? String)
    }
}
