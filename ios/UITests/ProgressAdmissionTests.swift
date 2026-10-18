import XCTest

final class ProgressAdmissionTests: XCTestCase {
    func testCancelDiscardsSelectionWithoutAcceptingIt() {
        var ticket = ProgressAdmissionTicket(parts: [.init(mediaId: 2001, episodes: 5)], accountID: "a", accountEpoch: 1)
        ticket.cancel()
        XCTAssertNil(ticket.accept(accountID: "a", accountEpoch: 1))
    }

    func testAcceptKeepsExactEpisodeAndCanOnlyBeConsumedOnce() {
        let selected = [FranchiseProgressValue(mediaId: 2001, episodes: 5)]
        var ticket = ProgressAdmissionTicket(parts: selected, accountID: "a", accountEpoch: 1)
        XCTAssertEqual(ticket.accept(accountID: "a", accountEpoch: 1), selected)
        XCTAssertNil(ticket.accept(accountID: "a", accountEpoch: 1))
    }

    func testBulkSelectionDoesNotFillUnselectedEarlierSeasons() throws {
        let selected = [FranchiseProgressValue(mediaId: 2002, episodes: 8), .init(mediaId: 2003, episodes: 4)]
        var ticket = ProgressAdmissionTicket(parts: selected, accountID: "a", accountEpoch: 1)
        let accepted = try XCTUnwrap(ticket.accept(accountID: "a", accountEpoch: 1))
        XCTAssertEqual(accepted, selected)
        XCTAssertFalse(accepted.contains { $0.mediaId == 2001 })
        // The retry/journal representation keeps these exact values; it does not derive ep1.
        XCTAssertEqual(try JSONDecoder().decode([FranchiseProgressValue].self,
            from: JSONEncoder().encode(accepted)), selected)
    }

    func testDifferentAccountCannotAcceptAndDoesNotLeaveReusableTicket() {
        var ticket = ProgressAdmissionTicket(parts: [.init(mediaId: 2001, episodes: 7)], accountID: "a", accountEpoch: 1)
        XCTAssertNil(ticket.accept(accountID: "b", accountEpoch: 2))
        XCTAssertNil(ticket.accept(accountID: "a", accountEpoch: 1))
    }

    func testSameAccountNewLifecycleCannotAcceptOldConfirmation() {
        var ticket = ProgressAdmissionTicket(parts: [.init(mediaId: 2001, episodes: 7)], accountID: "a", accountEpoch: 1)
        XCTAssertNil(ticket.accept(accountID: "a", accountEpoch: 2))
    }
}
