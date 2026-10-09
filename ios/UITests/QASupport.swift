import Foundation
import XCTest

/// The runner never launches the user's normal app bundle or accepts a public API host.
struct QAConfiguration: Sendable {
    static let appBundleID = "com.cognipin.previously.qa"
    let baseURL: URL
    let controlToken: String
    let seed: UInt64
    let duration: TimeInterval
    let maxActions: Int
    let wait: TimeInterval = 6

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let raw = environment["PREVIOUSLY_QA_BASE_URL"] ?? "http://127.0.0.1:18787"
        guard let url = URL(string: raw), url.scheme == "http",
              url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw QAError.unsafeServer(raw)
        }
        guard let token = environment["PREVIOUSLY_QA_CONTROL_TOKEN"], !token.isEmpty else {
            throw QAError.missingControlToken
        }
        baseURL = url
        controlToken = token
        seed = UInt64(environment["PREVIOUSLY_QA_SEED"] ?? "20261006") ?? 20261006
        duration = min(300, max(10, Double(environment["PREVIOUSLY_QA_DURATION_SECONDS"] ?? "60") ?? 60))
        maxActions = min(1_000, max(5, Int(environment["PREVIOUSLY_QA_MAX_ACTIONS"] ?? "80") ?? 80))
    }
}

enum QAError: Error, LocalizedError {
    case unsafeServer(String)
    case missingControlToken
    case server(Int, String)
    case assertion(String)

    var errorDescription: String? {
        switch self {
        case .unsafeServer: "QA requires an explicit loopback HTTP server."
        case .missingControlToken: "Start the scratch QA server and supply PREVIOUSLY_QA_CONTROL_TOKEN to the test runner."
        case let .server(status, body): "Scratch QA request failed (\(status)): \(body.prefix(250))"
        case let .assertion(message): message
        }
    }
}

/// SplitMix64 is small, deterministic, and does not depend on Swift's randomized Hasher.
struct SeededRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
    mutating func index(_ count: Int) -> Int {
        precondition(count > 0)
        return Int(next() % UInt64(count))
    }
}

struct QASnapshot: Codable, Equatable, Sendable {
    struct Progress: Codable, Equatable, Sendable { let mediaId: Int; let episodes: Int }
    struct Subscription: Codable, Equatable, Sendable { let franchiseId: String; let status: String }
    struct Fault: Codable, Equatable, Sendable { let kind: String; let path: String; let remaining: Int; let inFlight: Int }
    let fixtureVersion: String
    let account: String
    let progress: [Progress]
    let subscriptions: [Subscription]
    let commits: Int
    let progressCommits: Int
    let erased: Bool
    let faults: [Fault]?
    let deletionStatus: String?
    let deletionRequests: Int?
    let deletionStatusReads: Int?
    let ordinaryRequestsAfterErasure: Int?
    let mutationAttempts: Int?

    func episodes(_ mediaID: Int) -> Int? { progress.first { $0.mediaId == mediaID }?.episodes }
    var ownership: Set<String> { Set(subscriptions.map(\.franchiseId)) }
}

/// Independent HTTP oracle: it never uses the app's cache or model to decide expected data.
struct QAOracle: Sendable {
    struct MutationRecord: Decodable, Equatable, Sendable {
        let operationID: String
        let writerID: String
        let sequence: Int64
    }
    struct RequestRecord: Decodable, Sendable {
        let method: String
        let path: String
        let account: String?
        let outcome: String
        let mutation: MutationRecord?
    }
    let configuration: QAConfiguration

    func state(_ account: String) async throws -> QASnapshot {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("__qa/state"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "account", value: account)]
        let data = try await request(url: components.url!, method: "GET", body: nil)
        return try JSONDecoder().decode(QASnapshot.self, from: data)
    }

    func reset(_ account: String? = nil) async throws {
        _ = try await post("__qa/reset", object: account.map { ["account": $0] } ?? [:])
    }

    func trailerMode(enabled: Bool, account: String = "fixture-a") async throws {
        _ = try await post("__qa/trailer", object: ["account": account, "enabled": enabled])
    }

    func releaseHeld(account: String = "fixture-a", path: String = "/me/progress", disposition: String = "abort") async throws {
        _ = try await post("__qa/release", object: ["account": account, "path": path, "disposition": disposition])
    }

    func deletionMode(_ mode: String, account: String = "fixture-a", appleRevocation: String? = nil) async throws {
        var object: [String: Any] = ["account": account, "mode": mode]
        if let appleRevocation { object["appleRevocation"] = appleRevocation }
        _ = try await post("__qa/deletion", object: object)
    }

    func requests() async throws -> [RequestRecord] {
        struct Logs: Decodable { let logs: [RequestRecord] }
        let data = try await request(url: configuration.baseURL.appendingPathComponent("__qa/logs"), method: "GET", body: nil)
        return try JSONDecoder().decode(Logs.self, from: data).logs
    }

    func waitForRequests(_ minimum: Int, method: String, path: String, account: String,
                         timeout: TimeInterval = 8) async throws -> [RequestRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matching = try await requests().filter { $0.method == method && $0.path == path && $0.account == account }
            if matching.count >= minimum { return matching }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw QAError.assertion("Expected at least \(minimum) authenticated \(method) \(path) records for \(account).")
    }

    func fault(_ kind: String, account: String, path: String = "/me/progress", delayMs: Int? = nil, remaining: Int = 1) async throws {
        var body: [String: Any] = ["account": account, "kind": kind, "path": path, "remaining": remaining]
        if let delayMs { body["delayMs"] = delayMs }
        _ = try await post("__qa/fault", object: body)
    }

    func waitForEpisodes(_ expected: Int, mediaID: Int, account: String, timeout: TimeInterval = 8) async throws -> QASnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var last = try await state(account)
        while last.episodes(mediaID) != expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            last = try await state(account)
        }
        guard last.episodes(mediaID) == expected else {
            throw QAError.assertion("Canonical progress did not converge for media \(mediaID): expected \(expected), observed \(String(describing: last.episodes(mediaID))).")
        }
        return last
    }

    func waitForDeletion(_ expected: String, account: String = "fixture-a", timeout: TimeInterval = 8) async throws -> QASnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var last = try await state(account)
        while last.deletionStatus != expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            last = try await state(account)
        }
        guard last.deletionStatus == expected else {
            throw QAError.assertion("Deletion did not converge to \(expected); observed \(last.deletionStatus ?? "missing").")
        }
        return last
    }

    /// Synchronize against the recorded scratch fault, so the next query does not depend on
    /// guessing the app's debounce timing or sleeping past an expected server delay.
    func waitForFault(_ kind: String, path: String, account: String, inFlight: Bool, timeout: TimeInterval = 6) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = try await state(account)
            if let fault = snapshot.faults?.last(where: { $0.kind == kind && $0.path == path }),
               fault.remaining == 0, (fault.inFlight > 0) == inFlight { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw QAError.assertion("Scratch fault \(kind) at \(path) did not reach inFlight=\(inFlight) within \(timeout)s.")
    }

    private func post(_ path: String, object: [String: Any]) async throws -> Data {
        try await request(url: configuration.baseURL.appendingPathComponent(path), method: "POST",
                          body: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func request(url: URL, method: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(configuration.controlToken, forHTTPHeaderField: "X-Previously-QA-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw QAError.server((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

struct QAActionRecord: Codable, Sendable {
    let index: Int
    let timestamp: String
    let action: String
    let target: String
    let outcome: String
    let detail: String
}

@MainActor
final class QADriver {
    let app = XCUIApplication(bundleIdentifier: QAConfiguration.appBundleID)
    let test: XCTestCase
    let configuration: QAConfiguration
    let oracle: QAOracle
    private(set) var account = "fixture-a"
    private(set) var trace: [QAActionRecord] = []
    private(set) var completed = 0
    private(set) var unavailable = 0
    private(set) var checks = 0
    private(set) var checkedStates: Set<String> = []
    private let started = Date()

    init(test: XCTestCase, configuration: QAConfiguration) {
        self.test = test
        self.configuration = configuration
        oracle = QAOracle(configuration: configuration)
        test.continueAfterFailure = false
    }

    func begin(account: String = "fixture-a") async throws {
        app.terminate()
        // Every case starts from both synthetic identities and an empty request log. Otherwise
        // account B's state or an authenticated PUT from an earlier case could pollute the oracle.
        try await oracle.reset()
        try await launch(account: account, resetLocal: true)
        record("launch", QAConfiguration.appBundleID, "completed", "Isolated QA bundle; fixture \(account).")
        try await assertAccountSnapshot()
    }

    func launch(account: String? = nil, resetLocal: Bool = false, expectReady: Bool = true) async throws {
        if let account { self.account = account }
        app.launchEnvironment = [
            "PREVIOUSLY_QA": "1",
            "PREVIOUSLY_QA_BASE_URL": configuration.baseURL.absoluteString,
            "PREVIOUSLY_QA_ACCOUNT": self.account,
            "PREVIOUSLY_QA_CONTROL_TOKEN": configuration.controlToken
        ]
        if resetLocal { app.launchEnvironment["PREVIOUSLY_QA_RESET_LOCAL"] = "1" }
        app.launch()
        if expectReady { try requireReady(timeout: 15) }
    }

    func element(_ identifier: String) -> XCUIElement {
        if identifier == "qa.search.open" {
            let button = app.buttons.matching(identifier: identifier).firstMatch
            if button.exists { return button }
            // Discover's real Button has `.isSearchField` for VoiceOver. XCUI can therefore
            // classify the opener as SearchField; only this exact ID is a tap target.
            return app.searchFields.matching(identifier: identifier).firstMatch
        }
        if identifier == "qa.search.field" {
            let named = app.searchFields.matching(identifier: identifier).firstMatch
            if named.exists { return named }
            let actual = app.searchFields.allElementsBoundByIndex.filter {
                // The resting Discover button intentionally carries a search-field trait.
                // Activate it first; it is never a text-entry target.
                $0.identifier != "qa.search.open" && $0.exists && $0.isHittable
            }
            return actual.count == 1 ? actual[0] : named
        }
        if identifier == "qa.signin.dev.field" {
            return app.textFields.matching(identifier: identifier).firstMatch
        }
        if identifier.hasPrefix("qa.scroll.") {
            return app.scrollViews.matching(identifier: identifier).firstMatch
        }
        if identifier == "qa.detail.tab.episodes" {
            let named = app.buttons.matching(identifier: identifier).firstMatch
            if named.exists { return named }
            let buttons = app.buttons.matching(identifier: "Episodes").allElementsBoundByIndex
            return buttons.first { $0.isHittable } ?? buttons.first ?? named
        }
        let actionPrefixes = ["qa.tab.", "qa.detail.tab.", "qa.show.", "qa.profile.", "qa.signout", "qa.sync.retry.",
                              "qa.progress.mark.", "qa.progress.increment.", "qa.search.result."]
        if identifier == "qa.undo" || identifier == "qa.signin.dev.submit"
            || ["qa.delete.open", "qa.delete.confirm", "qa.delete.error.done", "qa.deletion.check", "qa.deletion.signout"].contains(identifier)
            || actionPrefixes.contains(where: { identifier.hasPrefix($0) }) {
            // A SwiftUI identifier can also be inherited by its caption's StaticText. Actions
            // select the actual Button; tapping an inherited label can produce a false success.
            return app.buttons.matching(identifier: identifier).firstMatch
        }
        return app.staticTexts.matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func require(_ identifier: String, timeout: TimeInterval? = nil) throws -> XCUIElement {
        let target = element(identifier)
        guard target.exists || target.waitForExistence(timeout: timeout ?? configuration.wait) else {
            record("wait", identifier, "timed-out", "Expected a visible app state.")
            throw QAError.assertion("Expected \(identifier) within \(timeout ?? configuration.wait)s.")
        }
        return target
    }

    func requireReady(timeout: TimeInterval? = nil) throws {
        let target = try require("qa.ready", timeout: timeout)
        if (target.value as? String) == "ready" { return }
        let predicate = NSPredicate(format: "value == %@", "ready")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)], timeout: timeout ?? configuration.wait)
        guard result == .completed else {
            throw QAError.assertion("The signed-in QA model remained loading beyond the bounded wait.")
        }
    }

    func tap(_ identifier: String) throws {
        let target = try require(identifier)
        if !target.isHittable {
            let inProfile = identifier.hasPrefix("qa.signout") || identifier.hasPrefix("qa.sync.") || identifier.hasPrefix("qa.delete.")
            let preferred = element(inProfile ? "qa.scroll.profile" : "qa.scroll.detail")
            if preferred.exists {
                for _ in 0..<6 where !target.isHittable {
                    preferred.swipeUp()
                    record("reveal", preferred.identifier, "completed", "Bounded scroll toward \(identifier).")
                }
            }
        }
        if !target.isHittable {
            let predicate = NSPredicate(format: "hittable == true")
            let ready = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)], timeout: configuration.wait)
            guard ready == .completed else {
                record("tap", identifier, "timed-out", "Control existed but never became hittable.")
                throw QAError.assertion("\(identifier) did not become hittable.")
            }
        }
        target.tap()
        record("tap", identifier, "completed")
    }

    func isAvailable(_ identifier: String) -> Bool {
        let target = element(identifier)
        return target.exists && target.isHittable && target.isEnabled
    }

    func navigate(_ tab: String) throws {
        // Scroll-away chrome may be off-screen: a named root scroller, never random coordinates.
        if !isAvailable("qa.tab.\(tab)"), let scroller = visibleScroller() { scroller.swipeDown() }
        try tap("qa.tab.\(tab)")
        // A launch/navigation transition can consume the first injected event. Observe the
        // actual selected tab before proceeding; re-tap that same real control once if needed.
        let target = element("qa.tab.\(tab)")
        if !target.isSelected {
            let selected = NSPredicate(format: "selected == true")
            let first = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: target)], timeout: 3)
            if first != .completed {
                record("navigation-observed", "qa.tab.\(tab)", "unavailable", "The injected tap did not select the destination; retrying the actual tab once.")
                try tap("qa.tab.\(tab)")
                let second = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: target)], timeout: configuration.wait)
                guard second == .completed else {
                    throw QAError.assertion("The actual \(tab) tab never became selected after two bounded taps.")
                }
            }
        }
        checkedStates.insert(tab)
    }

    func openAnime() throws {
        try navigate("library")
        // A tab switch preserves Library's NavigationStack. Returning from Home/Profile can
        // already reveal this show; only open the root card when detail is not restored.
        if !element("qa.detail.qa-anime").exists {
            try tap("qa.show.qa-anime")
        } else {
            record("restore-detail", "qa.detail.qa-anime", "completed", "Library's existing detail stack was preserved.")
        }
        try require("qa.detail.qa-anime")
        checks += 1
        checkedStates.insert("anime-detail")
    }

    func markNext() throws {
        try tap("qa.progress.mark.1001")
    }

    func openProfile() throws {
        try navigate("home")
        try tap("qa.profile.open")
        try require("qa.profile.done")
    }

    func assertAbsent(_ identifier: String, timeout: TimeInterval? = nil) throws {
        let target = element(identifier)
        if target.exists {
            let predicate = NSPredicate(format: "exists == false")
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)], timeout: timeout ?? configuration.wait)
            guard result == .completed else {
                throw QAError.assertion("Obsolete control \(identifier) remained present.")
            }
        }
        checks += 1
        record("assert-absent", identifier, "passed")
    }

    func assertValue(_ expected: String, identifier: String, timeout: TimeInterval? = nil) throws {
        let target = try require(identifier, timeout: timeout)
        if (target.value as? String) != expected {
            let predicate = NSPredicate(format: "value == %@", expected)
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)], timeout: timeout ?? configuration.wait)
            guard result == .completed else {
                throw QAError.assertion("\(identifier) expected value \(expected), observed \(String(describing: target.value)).")
            }
        }
        checks += 1
        record("assert-value", identifier, "passed", "value=\(expected)")
    }

    func openAnimeEpisodes() throws {
        try openAnime()
        try tap("qa.detail.tab.episodes")
        try require("qa.progress.increment.1001")
    }

    func progress(_ mediaID: Int = 1001) throws -> Int {
        let target = try require("qa.progress.\(mediaID)")
        let raw = (target.value as? String) ?? target.label
        guard let value = Int(raw) else {
            throw QAError.assertion("Progress selector \(mediaID) must expose a numeric accessibility value; observed \(raw).")
        }
        return value
    }

    func assertProgress(_ expected: Int, mediaID: Int = 1001) throws {
        let target = try require("qa.progress.\(mediaID)")
        if Int((target.value as? String) ?? target.label) != expected {
            let predicate = NSPredicate { object, _ in
                guard let target = object as? XCUIElement else { return false }
                return Int((target.value as? String) ?? target.label) == expected
            }
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)], timeout: configuration.wait)
            guard result == .completed else {
                throw QAError.assertion("UI progress for \(mediaID) expected \(expected), observed \(String(describing: target.value)).")
            }
        }
        checks += 1
        record("assert-progress", "qa.progress.\(mediaID)", "passed", "episodes=\(expected)")
    }

    func assertAccountSnapshot() async throws {
        let snapshot = try await oracle.state(account)
        guard snapshot.account == account, !snapshot.erased else {
            throw QAError.assertion("Scratch oracle returned the wrong or erased account.")
        }
        try require("qa.account.\(account)")
        checks += 1
        record("assert-account", "qa.account.\(account)", "passed", "fixtureVersion=\(snapshot.fixtureVersion)")
    }

    func replaceText(_ text: String, in identifier: String) throws {
        if identifier == "qa.search.field", isAvailable("qa.search.open") {
            try tap("qa.search.open")
        }
        let field = try require(identifier)
        var keyboardReady = false
        for attempt in 1...2 {
            try tap(identifier)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists {
                keyboardReady = true
                break
            }
            let predicate = NSPredicate(format: "exists == true")
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: keyboard)], timeout: 3)
            if result == .completed {
                keyboardReady = true
                break
            }
            record("focus-input", identifier, "unavailable", "Attempt \(attempt) did not produce a keyboard; re-tap the same actual field.")
        }
        guard keyboardReady else {
            record("focus-input", identifier, "timed-out")
            throw QAError.assertion("The actual field \(identifier) never acquired keyboard input after two bounded taps.")
        }
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            let clear = field.buttons["Clear text"].firstMatch
            if clear.exists && clear.isHittable {
                clear.tap()
                record("clear-input", "\(identifier).system.clear", "completed", "Actual field Clear text button; previous characters=\(value.count).")
            } else {
                // Tapping a long field can move the caret before its suffix. Repeated Delete
                // cannot reliably clear that suffix, regardless of the number of key events.
                field.press(forDuration: 1)
                let menuItem = app.menuItems["Select All"].firstMatch
                let menuButton = app.buttons["Select All"].firstMatch
                let selection = menuItem.exists ? menuItem : menuButton
                guard selection.exists || selection.waitForExistence(timeout: 3), selection.isHittable else {
                    record("clear-input", identifier, "timed-out", "No actual Clear text or Select All control; text was not replaced.")
                    throw QAError.assertion("Cannot reliably select all text in \(identifier).")
                }
                selection.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
                record("clear-input", "\(identifier).system.select-all", "completed", "Selected all before one Delete; previous characters=\(value.count).")
            }
        }
        let isEmpty = NSPredicate { object, _ in
            guard let input = object as? XCUIElement, let entered = input.value as? String else { return false }
            // UIKit exposes a placeholder as the accessibility value of some empty fields.
            return entered.isEmpty || entered == input.placeholderValue
        }
        if !isEmpty.evaluate(with: field) {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: isEmpty, object: field)], timeout: configuration.wait)
            guard result == .completed else {
                record("clear-observed", identifier, "timed-out", "entered=\(String(describing: field.value))")
                throw QAError.assertion("\(identifier) retained text after the explicit clear action.")
            }
        }
        checks += 1
        record("clear-observed", identifier, "passed", "Input is empty before any replacement characters are injected.")
        // XCTest's fast injection dropped two characters in one 120-character search. Send
        // bounded chunks and observe each exact prefix; never fill in a missing suffix or accept
        // truncated input as successful coverage. A product limit remains an assertion failure.
        let characters = Array(text)
        if characters.isEmpty { try assertValue(text, identifier: identifier) }
        for offset in stride(from: 0, to: characters.count, by: 16) {
            let end = min(offset + 16, characters.count)
            let chunk = String(characters[offset..<end])
            field.typeText(chunk)
            let expected = String(characters[..<end])
            let entered = (field.value as? String) ?? ""
            record("type-observed", identifier, "observed", "requestedPrefix=\(expected); entered=\(entered)")
            try assertValue(expected, identifier: identifier)
        }
        record("type", identifier, "completed", "requested=\(text); entered=\((field.value as? String) ?? "")")
    }

    func dismissKeyboard() throws {
        guard app.keyboards.firstMatch.exists else { return }
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap(); record("dismiss-keyboard", "system.cancel", "completed") }
        else {
            for key in ["Search", "search", "Return", "return", "Done", "done"] {
                let button = app.keyboards.buttons[key].firstMatch
                if button.exists && button.isHittable {
                    button.tap()
                    record("dismiss-keyboard", "system.keyboard.\(key)", "completed")
                    break
                }
            }
        }
        // Submit can leave a searchable field focused. Use the actual named results scroller's
        // `.scrollDismissesKeyboard(.interactively)` gesture, bounded to three attempts.
        for _ in 0..<3 where app.keyboards.firstMatch.exists {
            let search = element("qa.scroll.search")
            let discover = element("qa.scroll.discover")
            let scroller = search.exists && search.isHittable ? search : discover
            guard scroller.exists && scroller.isHittable else { break }
            scroller.swipeDown()
            record("dismiss-keyboard", scroller.identifier, "completed", "Named interactive keyboard-dismiss gesture.")
        }
        if app.keyboards.firstMatch.exists {
            let predicate = NSPredicate(format: "exists == false")
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app.keyboards.firstMatch)], timeout: 2)
            guard result == .completed else {
                record("dismiss-keyboard", "system.keyboard", "timed-out")
                throw QAError.assertion("Keyboard remained visible after submit and bounded named scroll gestures.")
            }
        }
    }

    func visibleScroller() -> XCUIElement? {
        let named = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "qa.scroll.")).allElementsBoundByIndex
        return named.first { $0.exists && $0.isHittable }
    }

    func record(_ action: String, _ target: String, _ outcome: String, _ detail: String = "") {
        trace.append(QAActionRecord(index: trace.count, timestamp: ISO8601DateFormatter().string(from: .now),
                                    action: action, target: target, outcome: outcome, detail: detail))
        if outcome == "completed" { completed += 1 }
        if outcome == "unavailable" { unavailable += 1 }
    }

    func attachEvidence(name: String) {
        struct Summary: Encodable {
            let version: Int
            let caseName: String
            let seed: UInt64
            let durationSeconds: Double
            let completedActions: Int
            let unavailableActions: Int
            let assertions: Int
            let states: [String]
        }
        struct Report: Encodable {
            let version: Int
            let seed: UInt64
            let durationSeconds: Double
            let completedActions: Int
            let unavailableActions: Int
            let assertions: Int
            let states: [String]
            let account: String
            let operatingSystem: String
            let trace: [QAActionRecord]
        }
        let report = Report(version: 1, seed: configuration.seed, durationSeconds: Date().timeIntervalSince(started),
                            completedActions: completed, unavailableActions: unavailable, assertions: checks,
                            states: checkedStates.sorted(), account: account,
                            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, trace: trace)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summary = Summary(version: 1, caseName: name, seed: configuration.seed,
                              durationSeconds: report.durationSeconds, completedActions: completed,
                              unavailableActions: unavailable, assertions: checks, states: checkedStates.sorted())
        let summaryEncoder = JSONEncoder()
        summaryEncoder.outputFormatting = [.sortedKeys]
        if let data = try? summaryEncoder.encode(summary), let line = String(data: data, encoding: .utf8) {
            // A compact machine-readable line survives ordinary test logs. The XCTest result
            // determines pass/fail; this line reports coverage evidence only, never a verdict.
            print("QA_SUMMARY " + line)
        }
        if let data = try? encoder.encode(report) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "\(name)-actions-seed-\(configuration.seed)"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        if app.state == .runningForeground {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(name)-last-screen"
            screenshot.lifetime = .keepAlways
            test.add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "\(name)-last-hierarchy"
            hierarchy.lifetime = .keepAlways
            test.add(hierarchy)
        }
    }
}
