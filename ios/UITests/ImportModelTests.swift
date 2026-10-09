import XCTest

/// Compiles the real production import-progress contract. No provider or catalogue calls.
final class ImportModelTests: XCTestCase {
    func testOlderSavedProgressWithoutOmissionsRestoresAsZero() throws {
        let data = Data(#"{"id":"import-old","state":"fetching","shows":4,"remaining":2,"failed":1}"#.utf8)
        let progress = try JSONDecoder().decode(ImportProgress.self, from: data)
        XCTAssertNil(progress.skipped)
        XCTAssertEqual(progress.adultSkipped, 0)
        XCTAssertEqual(progress.shows, 4)
        XCTAssertEqual(progress.failed, 1)
        let abandoned = progress.abandoned
        XCTAssertTrue(abandoned.isDone)
        XCTAssertEqual(abandoned.remaining, 0)
        XCTAssertEqual(abandoned.failed, 3)
        XCTAssertEqual(abandoned.adultSkipped, 0)
    }

    func testAdultOmissionsSurvivePersistenceAndInterruptedConversionSeparately() throws {
        let data = Data(#"{"id":"import-policy","state":"fetching","shows":4,"remaining":2,"failed":1,"skipped":{"count":3,"reasons":{"adult_content":3}}}"#.utf8)
        let progress = try JSONDecoder().decode(ImportProgress.self, from: data)
        XCTAssertEqual(progress.adultSkipped, 3)
        XCTAssertEqual(progress.skipped?.count, 3)
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.remaining, 2)
        let restored = try JSONDecoder().decode(ImportProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(restored, progress)
        let abandoned = restored.abandoned
        XCTAssertTrue(abandoned.isDone)
        XCTAssertEqual(abandoned.shows, 4)
        XCTAssertEqual(abandoned.failed, 3, "Only queued fetches become failures; policy omissions stay separate.")
        XCTAssertEqual(abandoned.skipped, restored.skipped)
        XCTAssertEqual(abandoned.adultSkipped, 3)
        let futureReason = try JSONDecoder().decode(ImportSkipped.self,
            from: Data(#"{"count":2,"reasons":{"future_policy":2}}"#.utf8))
        XCTAssertEqual(futureReason.adultCount, 0, "Unknown policies must not be described as adult content.")
    }
}
