import XCTest

/// Randomized interaction stays inside an explicit, app-owned selector whitelist.
@MainActor
final class PreviouslyMonkeyTests: XCTestCase {
    func testSeededMonkey() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer { driver.attachEvidence(name: "monkey"); driver.app.terminate() }
        try await driver.begin()
        let initial = try await driver.oracle.state("fixture-a")
        var expectedProgress = try XCTUnwrap(initial.episodes(1001))
        var random = SeededRandom(seed: driver.configuration.seed)
        let tabs = ["home", "schedule", "feed", "library", "discover"]
        let queries = ["QA", "   ", "雪", "TV 📺", "qa-anime", "x".padding(toLength: 120, withPad: "x", startingAt: 0)]

        // All five roots get a deterministic sanity check even with a short smoke budget.
        for tab in tabs { try driver.navigate(tab) }
        try driver.openAnime()
        try driver.assertProgress(expectedProgress)
        try driver.markNext()
        try driver.assertProgress(expectedProgress + 1)
        _ = try await driver.oracle.waitForEpisodes(expectedProgress + 1, mediaID: 1001, account: "fixture-a")
        try driver.tap("qa.undo")
        try driver.assertProgress(expectedProgress)
        _ = try await driver.oracle.waitForEpisodes(expectedProgress, mediaID: 1001, account: "fixture-a")

        let deadline = Date().addingTimeInterval(driver.configuration.duration)
        var decisions = 0
        while Date() < deadline, decisions < driver.configuration.maxActions {
            decisions += 1
            let bucket = random.index(100)
            if bucket < 40 {
                let tab = tabs[random.index(tabs.count)]
                if driver.isAvailable("qa.tab.\(tab)") {
                    try driver.navigate(tab)
                } else {
                    driver.record("navigate", "qa.tab.\(tab)", "unavailable", "No counted coverage for a hidden control.")
                    try driver.dismissKeyboard()
                    if let scroller = driver.visibleScroller() { scroller.swipeDown() }
                }
            } else if bucket < 70 {
                if driver.isAvailable("qa.progress.mark.1001"), expectedProgress < 11 {
                    try driver.markNext()
                    expectedProgress += 1
                    try driver.assertProgress(expectedProgress)
                    _ = try await driver.oracle.waitForEpisodes(expectedProgress, mediaID: 1001, account: "fixture-a")
                    // Half of mutations exercise Undo while its receipt is actionable.
                    if random.index(2) == 0 {
                        try driver.tap("qa.undo")
                        expectedProgress -= 1
                        try driver.assertProgress(expectedProgress)
                        _ = try await driver.oracle.waitForEpisodes(expectedProgress, mediaID: 1001, account: "fixture-a")
                    }
                } else if driver.isAvailable("qa.show.qa-anime") {
                    try driver.tap("qa.show.qa-anime")
                    try driver.require("qa.detail.qa-anime")
                    try driver.assertProgress(expectedProgress)
                } else {
                    driver.record("progress", "qa.progress.mark.1001", "unavailable", "Only visible, enabled fixture controls are eligible.")
                }
            } else if bucket < 90 {
                if driver.isAvailable("qa.tab.discover") {
                    try driver.navigate("discover")
                    let query = queries[random.index(queries.count)]
                    let fieldID = "qa.search.field"
                    if driver.isAvailable(fieldID) || driver.isAvailable("qa.search.open") {
                        try driver.replaceText(query, in: fieldID)
                        try driver.dismissKeyboard()
                    } else {
                        driver.record("search", fieldID, "unavailable", "Search selector was not ready; query was not typed.")
                    }
                } else {
                    driver.record("search", "qa.tab.discover", "unavailable", "Discover was obscured.")
                    try driver.dismissKeyboard()
                }
            } else {
                if driver.isAvailable("qa.profile.open") {
                    try driver.tap("qa.profile.open")
                    try driver.tap("qa.profile.done")
                    try driver.requireReady()
                } else {
                    driver.record("sheet", "qa.profile.open", "unavailable", "Profile was not visible on this root.")
                }
            }
            XCTAssertEqual(driver.app.state, .runningForeground, "A whitelisted action left or terminated the app.")
            try driver.require("qa.account.fixture-a")
        }

        try driver.dismissKeyboard()
        try driver.openAnime()
        try driver.assertProgress(expectedProgress)
        let final = try await driver.oracle.state("fixture-a")
        XCTAssertEqual(final.episodes(1001), expectedProgress)
        XCTAssertEqual(final.episodes(2001), initial.episodes(2001), "Unselected TV progress changed.")
        XCTAssertEqual(final.ownership, initial.ownership, "A read/navigation action changed library membership.")
        XCTAssertFalse(final.erased)
        driver.record("assert-oracle", "fixture-a", "passed", "Expected progress and membership independently confirmed.")

        driver.app.terminate()
        try await driver.launch()
        try driver.openAnime()
        try driver.assertProgress(expectedProgress)
        try await driver.assertAccountSnapshot()
        driver.record("relaunch", QAConfiguration.appBundleID, "completed", "UI matches the scratch oracle after a real process restart.")
        XCTAssertGreaterThan(driver.completed, 5)
        XCTAssertTrue(Set(tabs).isSubset(of: driver.checkedStates))
    }
}
