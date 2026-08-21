import XCTest
@testable import SendmeterCore

final class ManualWorkoutRestTests: XCTestCase {
    func testRestTargetsArePersistedChoicesWithThreeMinuteDefault() {
        XCTAssertEqual(ManualWorkoutRest.restTargets, [60, 120, 180, 300])
        XCTAssertEqual(ManualWorkoutRest.defaultRestTarget, 180)
        XCTAssertEqual(ManualWorkoutRest.validatedTarget(120), 120)
        XCTAssertEqual(ManualWorkoutRest.validatedTarget(0), 180)
        XCTAssertEqual(ManualWorkoutRest.validatedTarget(90), 180)
    }

    func testRestStartsAtWorkoutStartThenAtLastDropOff() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let userID = UUID()
        var engine = PhoneWorkoutEngine(accountUserID: userID, phase: .power, startedAt: start)

        XCTAssertEqual(
            ManualWorkoutRest.restStartedAt(workoutStartedAt: start, attempts: engine.draft.attempts),
            start
        )
        try engine.startAttempt(at: start.addingTimeInterval(10))
        _ = try engine.endAttempt(at: start.addingTimeInterval(25))

        XCTAssertEqual(
            ManualWorkoutRest.restStartedAt(workoutStartedAt: start, attempts: engine.draft.attempts),
            start.addingTimeInterval(25)
        )
    }

    func testCountdownAndRingClampAtTheRestTarget() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        var engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .capacity, startedAt: start)
        try engine.startAttempt(at: start)
        _ = try engine.endAttempt(at: start.addingTimeInterval(30))
        let attempts = engine.draft.attempts

        XCTAssertEqual(
            ManualWorkoutRest.remainingSeconds(
                now: start.addingTimeInterval(90),
                workoutStartedAt: start,
                attempts: attempts,
                targetSeconds: 120
            ),
            60
        )
        XCTAssertEqual(
            ManualWorkoutRest.progress(
                now: start.addingTimeInterval(90),
                workoutStartedAt: start,
                attempts: attempts,
                targetSeconds: 120
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ManualWorkoutRest.remainingSeconds(
                now: start.addingTimeInterval(200),
                workoutStartedAt: start,
                attempts: attempts,
                targetSeconds: 120
            ),
            0
        )
        XCTAssertEqual(
            ManualWorkoutRest.progress(
                now: start.addingTimeInterval(200),
                workoutStartedAt: start,
                attempts: attempts,
                targetSeconds: 120
            ),
            1
        )
    }

    func testPhaseGivesClimbingPriorityAndMarksRestOverAtZero() {
        XCTAssertEqual(
            ManualWorkoutRest.phase(attemptStartedAt: Date(), restRemaining: 0),
            .climbing
        )
        XCTAssertEqual(
            ManualWorkoutRest.phase(attemptStartedAt: nil, restRemaining: 0.1),
            .resting
        )
        XCTAssertEqual(
            ManualWorkoutRest.phase(attemptStartedAt: nil, restRemaining: 0),
            .restOver
        )
    }

    func testAlertKeyChangesWhenTargetChanges() {
        let restStart = Date(timeIntervalSince1970: 3_000)
        XCTAssertEqual(
            ManualWorkoutRest.alertKey(restStartedAt: restStart, targetSeconds: 90),
            "3000.0-180"
        )
        XCTAssertNotEqual(
            ManualWorkoutRest.alertKey(restStartedAt: restStart, targetSeconds: 60),
            ManualWorkoutRest.alertKey(restStartedAt: restStart, targetSeconds: 120)
        )
    }
}
