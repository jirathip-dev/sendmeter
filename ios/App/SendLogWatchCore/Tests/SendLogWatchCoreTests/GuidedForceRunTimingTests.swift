import XCTest
import SendLogWatchCore

final class GuidedForceRunTimingTests: XCTestCase {
    func testMovementDurationBoundsLateTickToSetEnd() {
        XCTAssertEqual(
            guidedMovementDurationMs(
                protocolValue: .movementStarter,
                set: 1,
                startedS: 5,
                elapsedS: 45
            ),
            40_000
        )
        XCTAssertEqual(
            guidedMovementDurationMs(
                protocolValue: .movementStarter,
                set: 1,
                startedS: 5,
                elapsedS: 105.1
            ),
            40_000
        )
    }

    func testMovementDurationKeepsHonestEarlyStop() {
        XCTAssertEqual(
            guidedMovementDurationMs(
                protocolValue: .movementStarter,
                set: 1,
                startedS: 5,
                elapsedS: 12.25
            ),
            7_250
        )
    }

    func testFixedKgTargetBandUsesPercentToleranceAndStaysConstant() {
        let protocolValue = WatchForceProtocol(
            id: "fixed",
            name: "Fixed target",
            holdS: 8,
            reps: 2,
            sets: 3,
            restRepsS: 0,
            restSetsS: 30,
            targetKg: 20,
            mode: .reverseAction,
            toleranceMode: .percent,
            toleranceValue: 10
        )

        let band = fixedMovementTargetBand(for: protocolValue)
        XCTAssertEqual(band, MovementTargetBand(kg: 20, lowKg: 18, highKg: 22))
        XCTAssertEqual(fixedMovementTargetBand(for: protocolValue), band)
    }

    func testFixedKgTargetBandUsesKgTolerance() {
        let protocolValue = WatchForceProtocol(
            id: "fixed-kg",
            name: "Fixed target",
            holdS: 8,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            targetKg: 20,
            toleranceMode: .kg,
            toleranceValue: 2.5
        )

        XCTAssertEqual(
            fixedMovementTargetBand(for: protocolValue),
            MovementTargetBand(kg: 20, lowKg: 17.5, highKg: 22.5)
        )
    }

    func testReferenceTargetsAndCurvesStayTargetFree() {
        let pr = WatchForceProtocol(
            id: "pr-percent",
            name: "PR percent",
            holdS: 8,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            targetPct: 80,
            percentBasis: .pr,
            targetCurve: false
        )
        let cf = WatchForceProtocol(
            id: "cf-percent",
            name: "CF percent",
            holdS: 8,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            targetPct: 80,
            percentBasis: .cf,
            targetCurve: false
        )
        let curve = WatchForceProtocol(
            id: "curve",
            name: "Curve",
            holdS: 8,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            targetKg: 20,
            targetCurve: true
        )
        let percentageOverridesFixed = WatchForceProtocol(
            id: "mixed",
            name: "Percentage overrides fixed",
            holdS: 8,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            targetKg: 20,
            targetPct: 80,
            percentBasis: .cf,
            targetCurve: false
        )

        XCTAssertNil(fixedMovementTargetBand(for: pr))
        XCTAssertNil(fixedMovementTargetBand(for: cf))
        XCTAssertNil(fixedMovementTargetBand(for: curve))
        XCTAssertNil(fixedMovementTargetBand(for: percentageOverridesFixed))
    }
}
