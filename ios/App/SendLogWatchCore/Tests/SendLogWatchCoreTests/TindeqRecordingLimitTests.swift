import XCTest
@testable import SendLogWatchCore

final class TindeqRecordingLimitTests: XCTestCase {
    func testDoesNotStopAtOldTwoMinuteLimit() {
        XCTAssertFalse(TindeqRecordingLimit.shouldStop(elapsedMs: 120_000))
    }

    func testStopsAtThirtyMinuteLimit() {
        XCTAssertEqual(TindeqRecordingLimit.maxRecordingMs, 30 * 60 * 1_000)
        XCTAssertFalse(
            TindeqRecordingLimit.shouldStop(
                elapsedMs: TindeqRecordingLimit.maxRecordingMs - 1
            )
        )
        XCTAssertTrue(
            TindeqRecordingLimit.shouldStop(
                elapsedMs: TindeqRecordingLimit.maxRecordingMs
            )
        )
    }
}
