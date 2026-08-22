import XCTest
@testable import SendLogWatchCore

final class TindeqRecordingLimitTests: XCTestCase {
    func testDoesNotStopAtOldTwoMinuteLimit() {
        XCTAssertFalse(TindeqRecordingLimit.shouldStop(elapsedMs: 120_000))
    }

    func testStopsAtTenMinuteLimitNotThirty() {
        // #682: the always-armed recording cap is 10 minutes, not 30.
        XCTAssertEqual(TindeqRecordingLimit.maxRecordingMs, 10 * 60 * 1_000)
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

    func testMovementNormalizationLeavesBoundaryHeadroom() {
        XCTAssertEqual(TindeqRecordingLimit.maxMovementSetS, 599)
        XCTAssertEqual(
            TindeqRecordingLimit.maxMovementReps(
                cadenceOutS: 30,
                cadenceReturnS: 30
            ),
            9
        )
        XCTAssertLessThan(
            Double(
                TindeqRecordingLimit.maxMovementReps(
                    cadenceOutS: 30,
                    cadenceReturnS: 30
                )
            ) * 60,
            maxRecordingSeconds
        )
    }

    private var maxRecordingSeconds: Double { TindeqRecordingLimit.maxRecordingMs / 1_000 }
}
