import XCTest
@testable import SendLogWatchCore

final class CoalescingDrainTests: XCTestCase {
    func testRequestDuringPassSchedulesFollowUp() {
        var drain = CoalescingDrain()
        XCTAssertEqual(drain.request(), .start)
        XCTAssertEqual(drain.request(), .queued)
        XCTAssertEqual(drain.completePass(), .rerun)
        XCTAssertEqual(drain.completePass(), .idle)
    }

    func testManyRequestsCoalesceToOneFollowUpPass() {
        var drain = CoalescingDrain()
        XCTAssertEqual(drain.request(), .start)
        for _ in 0..<10 { XCTAssertEqual(drain.request(), .queued) }
        XCTAssertEqual(drain.completePass(), .rerun)
        XCTAssertEqual(drain.completePass(), .idle)
        XCTAssertEqual(drain.request(), .start)
    }

    func testRequestDuringFollowUpSchedulesAnotherPass() {
        var drain = CoalescingDrain()
        XCTAssertEqual(drain.request(), .start)
        XCTAssertEqual(drain.request(), .queued)
        XCTAssertEqual(drain.completePass(), .rerun)
        XCTAssertEqual(drain.request(), .queued)
        XCTAssertEqual(drain.completePass(), .rerun)
        XCTAssertEqual(drain.completePass(), .idle)
    }
}
