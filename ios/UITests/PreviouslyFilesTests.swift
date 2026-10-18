import XCTest

/// Real UIDocumentPicker and ShareLink activity-sheet journeys. The loopback server interprets
/// only the synthetic parsed entries; it never parses XML on the test's behalf.
@MainActor
final class PreviouslyFilesTests: XCTestCase {
    // Copy.plural binds the count to its noun with a nonbreaking space; assert the
    // exact rendered/accessibility string rather than a visually identical ASCII space.
    private let skippedText = "1\u{00A0}title marked as adult was skipped."

    func testPartialMALFilePreviewAndApplyThroughSystemPicker() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "files-partial-import"); driver.app.terminate() }
        try await driver.begin()
        let protected = try await driver.oracle.state("fixture-b")
        try chooseMALFile("qa-partial.xml", driver: driver)
        try driver.assertValue("1|1|3|1", identifier: "qa.import.preview-counts")
        XCTAssertTrue(driver.app.staticTexts[skippedText].waitForExistence(timeout: 6))
        let previewed = try await driver.oracle.state("fixture-a")
        XCTAssertFalse(previewed.ownership.contains("qa-plan"), "Preview added the title before consent.")
        XCTAssertEqual(previewed.importInputs?.last?.rows.map(\.malId), [900001, 900002])
        XCTAssertEqual(previewed.importInputs?.last?.rows.map(\.watched), [3, 2])
        try driver.tap("qa.import.apply")
        try driver.require("qa.import.done")
        XCTAssertTrue(driver.app.staticTexts[skippedText].exists)
        let imported = try await driver.oracle.waitForEpisodes(3, mediaID: 3001, account: "fixture-a")
        XCTAssertTrue(imported.ownership.contains("qa-plan"))
        XCTAssertEqual(imported.subscriptions.first { $0.franchiseId == "qa-plan" }?.status, "watching")
        XCTAssertEqual(imported.progressCommits, 1)
        let protectedAfter = try await driver.oracle.state("fixture-b")
        XCTAssertEqual(protectedAfter, protected)
        try driver.tap("qa.import.done")
    }

    func testAllSkippedMALFileRendersReasonWithoutApplyAction() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "files-all-skipped-import"); driver.app.terminate() }
        try await driver.begin()
        let before = try await driver.oracle.state("fixture-a")
        try chooseMALFile("qa-all-skipped.xml", driver: driver)
        XCTAssertTrue(driver.app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", skippedText)).firstMatch.waitForExistence(timeout: 8))
        try driver.assertAbsent("qa.import.apply")
        let after = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(after.progress, before.progress)
        XCTAssertEqual(after.ownership, before.ownership)
        XCTAssertEqual(after.commits, before.commits)
        XCTAssertEqual(after.importInputs?.last?.rows.map(\.malId), [900002])
        try driver.tap("qa.import.cancel")
    }

    func testJSONAndCSVSaveToFilesContainAccountCopyAndSurviveSignOut() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "files-export-saved-copy"); driver.app.terminate() }
        try await driver.begin()
        let expected = try await driver.oracle.state("fixture-a")
        let beforeRequests = try await exportRequests(driver)
        try driver.openProfile()
        try driver.tap("qa.export.open")
        let openedRequests = try await exportRequests(driver)
        XCTAssertEqual(openedRequests, beforeRequests, "Opening Export fetched the account before a destination was selected.")
        try saveExport("json", driver: driver)
        let json = try savedData("json", driver: driver)
        let exported = try JSONDecoder().decode(QASnapshot.self, from: json)
        XCTAssertEqual(exported.account, "fixture-a")
        XCTAssertEqual(exported.ownership, expected.ownership)
        XCTAssertEqual(exported.progress, expected.progress)
        let jsonRequests = try await exportRequests(driver)
        XCTAssertEqual(jsonRequests, beforeRequests + 1, "One JSON share exhausted multiple account-export requests.")
        try saveExport("csv", driver: driver)
        let csv = try savedData("csv", driver: driver)
        let text = try XCTUnwrap(String(data: csv, encoding: .utf8))
        let rows = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first, "title,source,status,part,kind,progress,total_episodes")
        XCTAssertTrue(rows.contains { $0.contains("QA Anime") && $0.hasSuffix(",3,12") })
        XCTAssertTrue(rows.contains { $0.contains("QA Television") && $0.hasSuffix(",2,8") })
        let csvRequests = try await exportRequests(driver)
        XCTAssertEqual(csvRequests, jsonRequests, "The local CSV share incorrectly requested the account JSON export.")
        // Return from the pushed export page using its actual navigation Back control.
        let back = driver.app.navigationBars["Export library"].buttons.matching(identifier: "BackButton").firstMatch
        let returned = NSPredicate { _, _ in back.exists && back.isHittable }
        guard returned.evaluate(with: nil)
            || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 8) == .completed else {
            throw QAError.assertion("The named Export library Back control did not become available after Files closed.")
        }
        back.tap()
        driver.record("navigation-back", "system.export.profile", "completed", "Tapped the real Export library Back control after the Files transition.")
        try driver.tap("qa.signout")
        try driver.tap("qa.signout.confirm")
        try driver.require("qa.signin.dev.field")
        XCTAssertEqual(try savedData("json", driver: driver), json)
        XCTAssertEqual(try savedData("csv", driver: driver), csv)
        driver.app.terminate()
        try await driver.launch(expectReady: false)
        try driver.require("qa.signin.dev.field")
        XCTAssertEqual(try savedData("json", driver: driver), json)
        XCTAssertEqual(try savedData("csv", driver: driver), csv)
        let unchanged = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(unchanged.progress, expected.progress)
        XCTAssertEqual(unchanged.ownership, expected.ownership)
    }

    private func chooseMALFile(_ name: String, driver: QADriver) throws {
        try driver.openProfile()
        try driver.tap("qa.import.open")
        try driver.tap("qa.import.source.mal")
        try driver.tap("qa.import.choose-file")
        let folderTitle = driver.app.buttons.matching(NSPredicate(format: "label == %@", "QA Samples, Actions Menu")).firstMatch
        let entered = NSPredicate { _, _ in
            folderTitle.exists || driver.app.navigationBars["QA Samples"].exists
                || driver.app.navigationBars.staticTexts["QA Samples"].exists
        }
        try openQADocuments(driver, acceptingSamplesFolder: true)
        if entered.evaluate(with: nil) {
            driver.record("system-folder-observed", "QA Samples", "passed", "The real picker resumed its previous folder.")
        } else {
            let folder = driver.app.collectionViews["File View"].cells["QA Samples, Folder"].firstMatch
            guard folder.exists || folder.waitForExistence(timeout: 6), folder.isHittable else {
                throw QAError.assertion("The actual QA Samples folder cell was not available.")
            }
            folder.tap()
            driver.record("system-files-tap", "QA Samples, Folder", "completed", "Opened the real folder cell, not its caption.")
        }
        guard entered.evaluate(with: nil)
            || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: entered, object: nil)], timeout: 6) == .completed else {
            throw QAError.assertion("Tapping the actual folder cell did not enter QA Samples.")
        }
        attachFilesUI("import-samples-folder", driver: driver)
        let stem = (name as NSString).deletingPathExtension
        let view = driver.app.collectionViews["File View"].firstMatch
        // Files may hide a known extension. Match the complete displayed name or its exact
        // basename inside one file cell, then record that cell before opening it normally.
        func matchingFiles() -> [XCUIElement] {
            view.cells.allElementsBoundByIndex.filter { $0.staticTexts[name].exists || $0.staticTexts[stem].exists }
        }
        let available = NSPredicate { _, _ in matchingFiles().count == 1 }
        guard available.evaluate(with: nil)
            || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: available, object: nil)], timeout: 6) == .completed,
              let file = matchingFiles().first, file.isHittable else {
            throw QAError.assertion("The expected synthetic file did not resolve to one hittable Files cell: \(name)")
        }
        driver.record("system-file-observed", file.identifier, "passed", "expected=\(name); displayed=\(file.label)")
        file.tap()
        driver.record("system-open-file", name, "completed")
        // Some OS releases require Open after a selected file; others return immediately.
        let open = driver.app.buttons["Open"].firstMatch
        if open.exists && open.isHittable { open.tap(); driver.record("system-open-file", name, "completed") }
    }

    private func saveExport(_ format: String, driver: QADriver) throws {
        try driver.tap("qa.export.\(format)")
        let activities = driver.app.collectionViews["activityCollectionView"].firstMatch
        guard activities.exists || activities.waitForExistence(timeout: 8) else {
            throw QAError.assertion("The actual system share activity list never appeared.")
        }
        attachFilesUI("\(format)-actual-share", driver: driver)
        // Modern iOS exposes activity actions as collection cells, not Buttons. This is
        // the observed system action; choosing it still invokes the normal Files UI.
        try tapSystem("Save to Files", driver: driver)
        driver.record("share-save-to-files", format, "completed")
        try openQADocuments(driver)
        attachFilesUI("\(format)-save-destination-before-save", driver: driver)
        try tapSystem("Save", driver: driver)
        driver.record("system-save-file", format, "completed", "Real Save to Files destination: On My iPhone / Previously QA.")
    }

    private func attachFilesUI(_ name: String, driver: QADriver) {
        let screen = XCTAttachment(screenshot: driver.app.screenshot())
        screen.name = "files-\(name)-screen"
        screen.lifetime = .keepAlways
        add(screen)
        let hierarchy = XCTAttachment(string: driver.app.debugDescription)
        hierarchy.name = "files-\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func exportRequests(_ driver: QADriver) async throws -> Int {
        try await driver.oracle.requests().filter { $0.method == "GET" && $0.path == "/me/export" && $0.account == "fixture-a" }.count
    }

    private func openQADocuments(_ driver: QADriver, acceptingSamplesFolder: Bool = false) throws {
        // Use only actual system labels; no coordinates, direct import URL or Transferable call.
        let files = driver.app.collectionViews["File View"].firstMatch
        guard files.exists || files.waitForExistence(timeout: 8) else {
            throw QAError.assertion("The actual Files collection did not attach.")
        }
        if acceptingSamplesFolder { attachFilesUI("import-picker-attached", driver: driver) }
        let title = driver.app.navigationBars.staticTexts["Previously QA"].firstMatch
        let namedBar = driver.app.navigationBars["Previously QA"].firstMatch
        // Restored Files is a system-hosted subtree. Query its observed labels directly,
        // rather than requiring the host's NavigationBar ancestor to resolve first.
        let titleActions = driver.app.buttons.matching(NSPredicate(format: "label == %@", "Previously QA, Actions Menu")).firstMatch
        let samples = driver.app.buttons.matching(NSPredicate(format: "label == %@", "QA Samples, Actions Menu")).firstMatch
        let acceptedFolder = { acceptingSamplesFolder && samples.exists }
        let parent = driver.app.navigationBars.buttons["Previously QA"].firstMatch
        let browse = driver.app.buttons["Browse"].firstMatch
        let local = driver.app.staticTexts["On My iPhone"].firstMatch
        let attached = NSPredicate { _, _ in
            (acceptedFolder() || titleActions.exists || title.exists || namedBar.exists) || (parent.exists && parent.isHittable)
                || (browse.exists && browse.isHittable) || (local.exists && local.isHittable)
        }
        // The picker attaches after the app's Choose File action returns. An immediate
        // existence check can miss Browse and leave the test waiting on Recents forever.
        if !attached.evaluate(with: nil) {
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: attached, object: nil)], timeout: 8) == .completed else {
                throw QAError.assertion("The real Files picker did not expose a supported navigation control.")
            }
        }
        if acceptedFolder() || titleActions.exists || title.exists || namedBar.exists { return }
        if parent.exists && parent.isHittable {
            parent.tap()
            driver.record("system-files-tap", "Previously QA parent", "completed")
        } else {
            if !local.exists || !local.isHittable { try tapSystem("Browse", driver: driver) }
            try tapSystem("On My iPhone", driver: driver)
            try tapSystem("Previously QA", driver: driver)
        }
        let entered = NSPredicate { _, _ in title.exists || namedBar.exists || titleActions.exists }
        guard entered.evaluate(with: nil)
            || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: entered, object: nil)], timeout: 6) == .completed else {
            throw QAError.assertion("The system picker never entered the QA app's Documents domain.")
        }
    }

    private func tapSystem(_ label: String, driver: QADriver) throws {
        let button = driver.app.buttons[label].firstMatch
        let cell = driver.app.cells.matching(NSPredicate(format: "label == %@", label)).firstMatch
        let text = driver.app.staticTexts[label].firstMatch
        let ready = NSPredicate { _, _ in
            (button.exists && button.isHittable) || (cell.exists && cell.isHittable) || (text.exists && text.isHittable)
        }
        if !ready.evaluate(with: nil) {
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 6) == .completed else {
                throw QAError.assertion("System Files control missing or not hittable: \(label)")
            }
        }
        let target = button.exists && button.isHittable ? button : (cell.exists && cell.isHittable ? cell : text)
        target.tap()
        driver.record("system-files-tap", label, "completed")
    }

    private func savedData(_ format: String, driver: QADriver) throws -> Data {
        let target = try driver.require("qa.files.saved.\(format)")
        let exists = NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return Data(base64Encoded: value) != nil
        }
        if !exists.evaluate(with: target) {
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: exists, object: target)], timeout: 8) == .completed else {
                throw QAError.assertion("No actual user-saved \(format) file appeared in QA Documents.")
            }
        }
        guard let data = Data(base64Encoded: (target.value as? String) ?? "") else {
            throw QAError.assertion("The saved \(format) file readback was not available.")
        }
        return data
    }
}
