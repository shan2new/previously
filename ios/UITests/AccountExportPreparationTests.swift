import XCTest

@MainActor
final class AccountExportPreparationTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    func testConcurrentDestinationLoadsAndCachedReadUseOneRequest() async throws {
        let preparation = AccountExportPreparation<String>()
        var requests = 0
        let load: @MainActor () async throws -> String = {
            requests += 1
            await Task.yield()
            return "the same account copy"
        }
        async let first = preparation.value(isCurrent: { true }, load: load)
        async let second = preparation.value(isCurrent: { true }, load: load)
        let values = try await [first, second]
        XCTAssertEqual(values, ["the same account copy", "the same account copy"])
        let cached = try await preparation.value(isCurrent: { true }, load: load)
        XCTAssertEqual(cached, values[0])
        XCTAssertEqual(requests, 1)
    }

    func testFailedRequestDoesNotPreventExplicitRetry() async throws {
        let preparation = AccountExportPreparation<String>()
        var requests = 0
        do {
            _ = try await preparation.value(isCurrent: { true }) {
                requests += 1
                throw Failure.unavailable
            }
            XCTFail("A failed export unexpectedly returned a copy.")
        } catch Failure.unavailable { }
        let recovered = try await preparation.value(isCurrent: { true }) {
            requests += 1
            return "recovered"
        }
        XCTAssertEqual(recovered, "recovered")
        XCTAssertEqual(requests, 2)
    }

    func testStaleOwnerCannotStartOrReadCachedPayload() async throws {
        let preparation = AccountExportPreparation<String>()
        var requests = 0
        for current in [false, true, false] {
            do {
                let value = try await preparation.value(isCurrent: { current }) {
                    requests += 1
                    return "account A only"
                }
                XCTAssertTrue(current)
                XCTAssertEqual(value, "account A only")
            } catch is CancellationError { XCTAssertFalse(current) }
        }
        XCTAssertEqual(requests, 1)
    }

    func testAccountChangeDuringRequestRejectsItsLateResult() async throws {
        let preparation = AccountExportPreparation<String>()
        var current = true
        do {
            _ = try await preparation.value(isCurrent: { current }) {
                current = false
                await Task.yield()
                return "late account A copy"
            }
            XCTFail("A late account copy escaped its owner check.")
        } catch is CancellationError { }
        do {
            _ = try await preparation.value(isCurrent: { current }) { "must not run" }
            XCTFail("A stale export item became reusable after account change.")
        } catch is CancellationError { }
    }
}
