import XCTest

/// Fast harness checks need no UI server; these do not count as native app QA.
final class QAHarnessTests: XCTestCase {
    func testSeedProducesStableActionSelection() {
        var random = SeededRandom(seed: 0)
        XCTAssertEqual(random.next(), 0xE220A8397B1DCDAF)
        XCTAssertEqual(random.next(), 0x6E789E6AA1B965F4)
        var first = SeededRandom(seed: 20261006)
        var replay = SeededRandom(seed: 20261006)
        XCTAssertEqual((0..<100).map { _ in first.index(100) }, (0..<100).map { _ in replay.index(100) })
    }

    func testPublicAndMalformedQAEndpointsAreRefused() {
        for url in ["https://anime.cognipin.com", "http://192.168.1.10:18787", "http://localhost:18787", "http://[::1]:18787", "http://127.0.0.1.evil.invalid", "http://127.0.0.1:18787?override=1", "http://user:pass@127.0.0.1:18787"] {
            XCTAssertThrowsError(try QAConfiguration(environment: ["PREVIOUSLY_QA_BASE_URL": url, "PREVIOUSLY_QA_CONTROL_TOKEN": "fixture-only"]))
        }
    }

    func testExplicitTokenAndBoundedRunBudget() throws {
        XCTAssertThrowsError(try QAConfiguration(environment: [:]))
        let configuration = try QAConfiguration(environment: ["PREVIOUSLY_QA_CONTROL_TOKEN": "fixture-only", "PREVIOUSLY_QA_DURATION_SECONDS": "3600", "PREVIOUSLY_QA_MAX_ACTIONS": "999999"])
        XCTAssertEqual(configuration.duration, 300)
        XCTAssertEqual(configuration.maxActions, 1000)
    }
}
