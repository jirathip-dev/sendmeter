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

    func testScheduleOwnsDropOffDeadlineAndValidatesTarget() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        var engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .power, startedAt: start)
        try engine.startAttempt(at: start.addingTimeInterval(10))
        _ = try engine.endAttempt(at: start.addingTimeInterval(25))

        let schedule = ManualWorkoutRest.schedule(
            workoutStartedAt: start,
            attempts: engine.draft.attempts,
            targetSeconds: 90
        )

        XCTAssertEqual(schedule.restStartedAt, start.addingTimeInterval(25))
        XCTAssertEqual(schedule.targetSeconds, 180)
        XCTAssertEqual(schedule.deadline, start.addingTimeInterval(205))
        XCTAssertEqual(schedule.key, "4025.0-180")
    }

    func testNotificationDelayAvoidsTooShortAndExpiredRequests() {
        let now = Date(timeIntervalSince1970: 5_000)
        let deadline = now.addingTimeInterval(0.25)

        XCTAssertEqual(
            ManualWorkoutRest.notificationDelay(now: now, deadline: deadline),
            1
        )
        XCTAssertNil(
            ManualWorkoutRest.notificationDelay(now: deadline, deadline: deadline)
        )
        XCTAssertNil(
            ManualWorkoutRest.notificationDelay(
                now: now,
                deadline: deadline,
                minimumDelay: 0
            )
        )
    }

    func testFeedbackDecisionDeduplicatesAndSeparatesBackgroundDelivery() {
        let start = Date(timeIntervalSince1970: 6_000)
        let schedule = ManualWorkoutRest.Schedule(restStartedAt: start, targetSeconds: 60)
        let due = schedule.deadline

        XCTAssertEqual(
            ManualWorkoutRest.feedbackDecision(
                now: due.addingTimeInterval(-1),
                schedule: schedule,
                sceneIsActive: true,
                deadlinePassedWhileBackground: false,
                notificationWasScheduled: true,
                lastFeedbackKey: nil
            ),
            .none
        )
        XCTAssertEqual(
            ManualWorkoutRest.feedbackDecision(
                now: due,
                schedule: schedule,
                sceneIsActive: true,
                deadlinePassedWhileBackground: false,
                notificationWasScheduled: false,
                lastFeedbackKey: nil
            ),
            .playForeground
        )
        XCTAssertEqual(
            ManualWorkoutRest.feedbackDecision(
                now: due,
                schedule: schedule,
                sceneIsActive: true,
                deadlinePassedWhileBackground: false,
                notificationWasScheduled: false,
                lastFeedbackKey: schedule.key
            ),
            .none
        )
        XCTAssertEqual(
            ManualWorkoutRest.feedbackDecision(
                now: due,
                schedule: schedule,
                sceneIsActive: true,
                deadlinePassedWhileBackground: true,
                notificationWasScheduled: true,
                lastFeedbackKey: nil
            ),
            .suppressForBackgroundNotification
        )
        XCTAssertEqual(
            ManualWorkoutRest.feedbackDecision(
                now: due,
                schedule: schedule,
                sceneIsActive: true,
                deadlinePassedWhileBackground: true,
                notificationWasScheduled: false,
                lastFeedbackKey: nil
            ),
            .playForeground
        )
        XCTAssertEqual(
            ManualWorkoutRest.feedbackDecision(
                now: due,
                schedule: schedule,
                sceneIsActive: false,
                deadlinePassedWhileBackground: false,
                notificationWasScheduled: true,
                lastFeedbackKey: nil
            ),
            .none
        )
    }

    func testNotificationLedgerLeavesNewRequestSafeFromLateOldCompletion() {
        var ledger = ManualWorkoutNotificationLedger()
        let requestA = ManualWorkoutNotificationLedger.Request(
            identifier: "rest-a",
            scheduleKey: "schedule-a",
            token: UUID()
        )
        let requestB = ManualWorkoutNotificationLedger.Request(
            identifier: "rest-b",
            scheduleKey: "schedule-b",
            token: UUID()
        )

        XCTAssertTrue(ledger.submit(requestA))
        XCTAssertEqual(ledger.cancelAll(), ["rest-a"])
        XCTAssertTrue(ledger.submit(requestB))

        XCTAssertEqual(
            ledger.complete(requestA, succeeded: true),
            .stale
        )
        XCTAssertNil(ledger.scheduledKey)
        XCTAssertEqual(ledger.ownedIdentifiers, ["rest-b"])

        XCTAssertEqual(
            ledger.complete(requestB, succeeded: true),
            .scheduled
        )
        XCTAssertEqual(ledger.scheduledKey, "schedule-b")
        XCTAssertEqual(ledger.cancelAll(), ["rest-b"])
        XCTAssertNil(ledger.scheduledKey)
        XCTAssertTrue(ledger.ownedIdentifiers.isEmpty)
    }

    func testNotificationLedgerDropsFailedRequestForRetry() {
        var ledger = ManualWorkoutNotificationLedger()
        let request = ManualWorkoutNotificationLedger.Request(
            identifier: "rest-failed",
            scheduleKey: "schedule-failed",
            token: UUID()
        )

        XCTAssertTrue(ledger.submit(request))
        XCTAssertEqual(
            ledger.complete(request, succeeded: false),
            .failed
        )
        XCTAssertNil(ledger.scheduledKey)
        XCTAssertTrue(ledger.ownedIdentifiers.isEmpty)
    }
}
