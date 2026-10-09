import XCTest

/// Opt-in external integration evidence, excluded from the dependency-free core suites.
/// The fixture supplies Google's documented public IFrame API example only for this case.
@MainActor
final class PreviouslyTrailerTests: XCTestCase {
    private struct ProviderSnapshot: Decodable, Sendable {
        let instance: String
        let key: String
        let host: String
        let persistent: Bool
        let providerState: Int
        let current: Double
        let duration: Double
        let muted: Bool?
        let moving: Bool
        let presenting: Bool
        let destroyed: Bool
        let error: Int?
        let providerReports: Int
    }

    func testLivePrivacyEnhancedTrailerKeepsPlaybackAndControlsAcrossFullscreen() async throws {
        let driver = QADriver(test: self, configuration: try QAConfiguration())
        defer {
            XCUIDevice.shared.orientation = .portrait
            driver.attachEvidence(name: "live-privacy-enhanced-trailer")
            driver.app.terminate()
        }
        try await driver.begin()
        try await driver.oracle.trailerMode(enabled: true)
        try driver.openAnime()
        // The show profile initially opens Posts. Its trailers live on the real Media tab.
        try driver.tap("qa.detail.tab.media")
        try openTrailer(driver)
        let inline = try await waitForProvider(driver, description: "actual inline video playback", timeout: 40) {
            $0.key == "M7lc1UVf-VE" && $0.providerState == 1 && $0.current > 0.4 && $0.duration > 20 && $0.moving
        }
        XCTAssertEqual(inline.host, "www.youtube-nocookie.com")
        XCTAssertFalse(inline.persistent, "The actual WKWebView must use a temporary website data store.")
        XCTAssertNotNil(inline.muted)
        let advancing = try await waitForProvider(driver, description: "provider clock advancement") {
            $0.instance == inline.instance && $0.providerState == 1 && $0.current > inline.current + 1
        }
        driver.record("assert-provider-privacy", inline.key, "passed",
                      "Actual IFrame API host=\(inline.host), persistent=\(inline.persistent), duration=\(inline.duration), clock=\(advancing.current).")

        // Rotation is a real consumer route into the fullscreen player. Pause promptly so the
        // native controls remain visible while the provider acknowledgement is inspected.
        XCUIDevice.shared.orientation = .landscapeLeft
        driver.record("rotate", "landscape-left", "completed", "Production trailer director opens fullscreen for an engaged playing trailer.")
        let pause = driver.app.buttons.matching(identifier: "Pause").firstMatch
        guard pause.waitForExistence(timeout: 10), pause.isHittable else {
            throw QAError.assertion("Fullscreen playback did not expose its native Pause control after rotation.")
        }
        pause.tap()
        driver.record("tap", "Pause", "completed")
        let paused = try await waitForProvider(driver, description: "provider-acknowledged pause") {
            $0.instance == inline.instance && $0.presenting && $0.providerState == 2
        }
        XCTAssertGreaterThanOrEqual(paused.current, advancing.current - 0.5)
        try await Task.sleep(for: .seconds(2))
        let stillPaused = try await waitForProvider(driver, description: "stable paused provider clock") {
            $0.instance == inline.instance && $0.providerState == 2 && $0.presenting && $0.providerReports > paused.providerReports
        }
        XCTAssertLessThanOrEqual(abs(stillPaused.current - paused.current), 0.75)
        driver.record("assert-provider-pause", inline.key, "passed", "State=2; provider clock stayed within 0.75s across a 2s pause.")

        try tapControl("Play", driver: driver)
        try tapControl("Turn sound off", driver: driver)
        let muted = try await waitForProvider(driver, description: "provider-acknowledged play and mute") {
            $0.instance == inline.instance && $0.providerState == 1 && $0.muted == true && $0.current > paused.current + 0.5
        }
        try tapControl("Pause", driver: driver)
        _ = try await waitForProvider(driver, description: "pause before sound restoration") {
            $0.instance == inline.instance && $0.providerState == 2
        }
        try tapControl("Turn sound on", driver: driver)
        try tapControl("Play", driver: driver)
        _ = try await waitForProvider(driver, description: "provider-acknowledged unmute") {
            $0.instance == inline.instance && $0.providerState == 1 && $0.muted == false && $0.current > muted.current
        }
        driver.record("assert-provider-sound", inline.key, "passed", "Actual isMuted() reported true after mute and false after sound restoration.")

        guard let beforeSeek = providerSnapshot(driver), beforeSeek.instance == inline.instance else {
            throw QAError.assertion("The actual provider clock was unavailable before forward seek.")
        }
        let seekStarted = Date()
        try tapControl("Forward 10 seconds", driver: driver)
        let sought = try await waitForProvider(driver, description: "provider-acknowledged forward seek") {
            $0.instance == inline.instance && $0.providerState == 1 &&
            $0.current - beforeSeek.current - Date().timeIntervalSince(seekStarted) >= 5
        }
        XCTAssertLessThan(sought.current, sought.duration)
        driver.record("assert-provider-seek", inline.key, "passed",
                      "Forward 10s control moved actual provider clock from \(beforeSeek.current) to \(sought.current), exceeding ordinary elapsed playback by at least 5s.")
        // Hold the visible native chrome through the return. A paused player retains controls;
        // the provider's real pause acknowledgement determines the expected handoff clock.
        try tapControl("Pause", driver: driver)
        let pausedForReturn = try await waitForProvider(driver, description: "pause before rotation return") {
            $0.instance == inline.instance && $0.presenting && $0.providerState == 2
        }
        // The rotation route returns automatically when upright. Closing into landscape first
        // would put the inline card off-screen, where the product correctly stops playback.
        XCUIDevice.shared.orientation = .portrait
        driver.record("rotate", "portrait", "completed")
        let returned = try await waitForProvider(driver, description: "same paused clock after inline handoff") {
            $0.instance == inline.instance && !$0.presenting && $0.providerState == 2
        }
        XCTAssertEqual(returned.key, inline.key)
        XCTAssertEqual(returned.host, "www.youtube-nocookie.com")
        XCTAssertFalse(returned.persistent)
        XCTAssertEqual(returned.duration, inline.duration, accuracy: 1)
        XCTAssertEqual(returned.current, pausedForReturn.current, accuracy: 0.75)
        driver.record("assert-provider-handoff", inline.key, "passed",
                      "Same playback instance \(inline.instance) retained its provider-acknowledged paused clock across fullscreen and inline surfaces.")
        // Also verify the explicit fullscreen switch and exit while the underlying portrait card
        // remains visible; this is a distinct consumer path from rotation-driven dismissal.
        try tapObservedInlineFullscreen(driver)
        // Fullscreen's production onAppear resumes a paused trailer. Prove that actual
        // provider acknowledgement instead of assuming the inline paused mode persists.
        let resumed = try await waitForProvider(driver, description: "actual playing explicit fullscreen entry") {
            $0.instance == inline.instance && $0.presenting && $0.providerState == 1 && $0.current > returned.current + 0.5
        }
        driver.record("assert-provider-explicit-entry", inline.key, "passed",
                      "Inline paused state=2 at \(returned.current); observed fullscreen tap resumed actual state=1 at \(resumed.current), same instance.")
        try tapControl("Exit full screen", driver: driver)
        let explicitReturn = try await waitForProvider(driver, description: "continuous playback after explicit fullscreen exit") {
            $0.instance == inline.instance && !$0.presenting && $0.providerState == 1 && $0.current > resumed.current + 0.5
        }
        XCTAssertEqual(explicitReturn.host, "www.youtube-nocookie.com")
        driver.record("assert-provider-explicit-handoff", inline.key, "passed", "The explicit fullscreen control and exit retained the same actual player and advancing clock while its portrait card was visible.")
        try await driver.oracle.trailerMode(enabled: false)
    }

    private func tapObservedInlineFullscreen(_ driver: QADriver) throws {
        // This separate external integration case may use the observed physical control.
        // The production card deliberately offers named VoiceOver actions as one element;
        // its drawn buttons are not separate AX nodes. Core monkey actions never use this.
        let cards = driver.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "YouTube IFrame API demonstration"))
            .allElementsBoundByIndex
        guard let card = cards.first(where: { $0.exists && $0.frame.width > 200 && $0.frame.height > 120 }) else {
            throw QAError.assertion("The observed featured trailer picture had no usable frame. " + cardDiagnostics(driver))
        }
        let frame = card.frame
        // Observed featured-card anatomy:44pt rightmost control;24pt scrubber+8pt bottom
        // padding below its44pt foot. The attachment records the actual screen before input.
        let point = CGPoint(x: frame.maxX - 22, y: frame.maxY - 54)
        guard frame.contains(point), driver.app.frame.contains(frame) else {
            throw QAError.assertion("The observed fullscreen control was outside the visible featured card.")
        }
        let proof = XCTAttachment(screenshot: driver.app.screenshot())
        proof.name = "inline-fullscreen-observed-control"
        proof.lifetime = .keepAlways
        add(proof)
        driver.record("observe-control", "inline-trailer.full-screen", "passed",
                      "Screenshot=inline-fullscreen-observed-control; cardFrame=\(frame); tapPoint=\(point); provider paused so chrome remains visible. Fixed observed physical control; no VoiceOver qualification.")
        card.coordinate(withNormalizedOffset: CGVector(dx: (point.x - frame.minX) / frame.width,
                                                       dy: (point.y - frame.minY) / frame.height)).tap()
        driver.record("tap-observed-control", "inline-trailer.full-screen", "completed", "Frame-derived physical tap; actual provider/fullscreen state must confirm entry.")
    }

    private func openTrailer(_ driver: QADriver) throws {
        let scroll = driver.element("qa.scroll.detail")
        for _ in 0..<8 where playableCard(driver) == nil {
            guard scroll.exists, scroll.isHittable else {
                throw QAError.assertion("The detail scroller was unavailable while revealing the fixture trailer.")
            }
            scroll.swipeUp()
            driver.record("reveal", "qa.scroll.detail", "completed", "Bounded scroll toward the live fixture trailer.")
        }
        guard let card = playableCard(driver) else {
            throw QAError.assertion("The opt-in detail trailer did not expose its actual playable card. " + cardDiagnostics(driver))
        }
        card.tap()
        driver.record("tap", "YouTube IFrame API demonstration", "completed")
    }

    private func playableCard(_ driver: QADriver) -> XCUIElement? {
        let identified = driver.app.buttons.matching(identifier: "qa.trailer.open.M7lc1UVf-VE").allElementsBoundByIndex
        if let card = identified.first(where: { $0.exists && $0.isHittable }) { return card }
        // A container can inherit its child's label and button trait. Only a real hittable
        // card/name control may be tapped; an earlier virtual match is not the same action.
        return driver.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "YouTube IFrame API demonstration"))
            .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
    }

    private func cardDiagnostics(_ driver: QADriver) -> String {
        driver.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "YouTube IFrame API demonstration"))
            .allElementsBoundByIndex.map { "id=\($0.identifier), frame=\($0.frame), hittable=\($0.isHittable)" }.joined(separator: "; ")
    }

    private func tapControl(_ label: String, driver: QADriver) throws {
        let button = driver.app.buttons.matching(identifier: label).firstMatch
        if !button.exists {
            guard let state = providerSnapshot(driver), state.presenting else {
                throw QAError.assertion("\(label) was absent outside the proven fullscreen trailer.")
            }
            // The real fullscreen surface brings back its chrome on a tap. This bounded action
            // uses the observed app window; it never substitutes a synthetic player command.
            let window = driver.app.windows.firstMatch
            guard window.exists, window.isHittable else {
                throw QAError.assertion("Fullscreen trailer window was not hittable while revealing \(label).")
            }
            window.tap()
            driver.record("reveal-controls", "fullscreen-window", "completed", "Actual controls were absent; tapped the fullscreen surface once.")
        }
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let ready = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: button)], timeout: 5)
        guard ready == .completed else {
            throw QAError.assertion("Actual native trailer control \(label) did not become hittable.")
        }
        button.tap()
        driver.record("tap", label, "completed")
    }

    private func providerSnapshot(_ driver: QADriver) -> ProviderSnapshot? {
        let markers = driver.app.staticTexts.matching(identifier: "qa.trailer.state").allElementsBoundByIndex
        for marker in markers where marker.exists {
            guard let raw = marker.value as? String, let data = raw.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(ProviderSnapshot.self, from: data) else { continue }
            return snapshot
        }
        return nil
    }

    private func waitForProvider(_ driver: QADriver, description: String, timeout: TimeInterval = 15,
                                 satisfying predicate: (ProviderSnapshot) -> Bool) async throws -> ProviderSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var last: ProviderSnapshot?
        while Date() < deadline {
            if let state = providerSnapshot(driver) {
                last = state
                if let code = state.error {
                    throw QAError.assertion("YouTube returned actual player error \(code) while checking \(description).")
                }
                if state.destroyed {
                    throw QAError.assertion("The actual trailer player was destroyed while checking \(description).")
                }
                if predicate(state) {
                    driver.record("assert-provider-state", state.key, "passed",
                                  "\(description): state=\(state.providerState), time=\(state.current), muted=\(String(describing: state.muted)), fullscreen=\(state.presenting).")
                    return state
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw QAError.assertion("Timed out checking \(description); last provider state=\(last?.providerState.description ?? "missing"), time=\(last?.current.description ?? "missing").")
    }
}
