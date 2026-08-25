import XCTest
@testable import SendmeterCore

final class ManualWorkoutActivityContentTests: XCTestCase {
    func testInitialSnapshotIsRestingFromWorkoutStartWithValidatedTarget() {
        let start = Date(timeIntervalSince1970: 1_000)
        let engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .power, startedAt: start)

        let snapshot = ManualWorkoutActivitySnapshot(
            engine: engine,
            restTarget: 90,
            now: start.addingTimeInterval(30)
        )

        XCTAssertEqual(snapshot.phase, .resting)
        XCTAssertEqual(snapshot.phaseStartedAt, start)
        XCTAssertEqual(snapshot.restTargetSeconds, 180)
        XCTAssertEqual(snapshot.boulderCount, 0)
    }

    func testOpenAttemptMapsToClimbingFromAttemptStart() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        var engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .capacity, startedAt: start)
        try engine.startAttempt(at: start.addingTimeInterval(20))

        let snapshot = ManualWorkoutActivitySnapshot(
            engine: engine,
            restTarget: 120,
            now: start.addingTimeInterval(50)
        )

        XCTAssertEqual(snapshot.phase, .climbing)
        XCTAssertEqual(snapshot.phaseStartedAt, start.addingTimeInterval(20))
        XCTAssertEqual(snapshot.boulderCount, 0)
    }

    func testDropOffReArmsRestAtAttemptEndAndCountsTheBoulder() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        var engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .strength, startedAt: start)
        try engine.startAttempt(at: start.addingTimeInterval(10))
        _ = try engine.endAttempt(at: start.addingTimeInterval(40))

        let snapshot = ManualWorkoutActivitySnapshot(
            engine: engine,
            restTarget: 60,
            now: start.addingTimeInterval(100)
        )

        XCTAssertEqual(snapshot.phase, .resting)
        XCTAssertEqual(snapshot.phaseStartedAt, start.addingTimeInterval(40))
        XCTAssertEqual(snapshot.restTargetSeconds, 60)
        XCTAssertEqual(snapshot.boulderCount, 1)
    }

    func testRestOverStillUsesCapacitorRestingWirePhase() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        var engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .execution, startedAt: start)
        try engine.startAttempt(at: start.addingTimeInterval(5))
        _ = try engine.endAttempt(at: start.addingTimeInterval(15))

        let snapshot = ManualWorkoutActivitySnapshot(
            engine: engine,
            restTarget: 60,
            now: start.addingTimeInterval(200)
        )

        XCTAssertEqual(snapshot.phase, .resting)
        XCTAssertEqual(snapshot.phaseStartedAt, start.addingTimeInterval(15))
        XCTAssertEqual(snapshot.restTargetSeconds, 60)
    }

    func testRestTargetChangeMidRestUpdatesSnapshotTargetOnly() throws {
        let start = Date(timeIntervalSince1970: 4_500)
        var engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .capacity, startedAt: start)
        try engine.startAttempt(at: start.addingTimeInterval(5))
        _ = try engine.endAttempt(at: start.addingTimeInterval(15))

        let before = ManualWorkoutActivitySnapshot(
            engine: engine,
            restTarget: 60,
            now: start.addingTimeInterval(30)
        )
        let after = ManualWorkoutActivitySnapshot(
            engine: engine,
            restTarget: 120,
            now: start.addingTimeInterval(30)
        )

        XCTAssertEqual(before.phase, .resting)
        XCTAssertEqual(before.restTargetSeconds, 60)
        XCTAssertEqual(after.phase, .resting)
        XCTAssertEqual(after.restTargetSeconds, 120)
        XCTAssertEqual(after.phaseStartedAt, start.addingTimeInterval(15))
    }

    func testIntentApplicationTransitionsNativelyAndIsIdempotent() {
        let start = Date(timeIntervalSince1970: 5_000)
        var snapshot = ManualWorkoutActivitySnapshot(
            phase: .resting,
            phaseStartedAt: start,
            restTargetSeconds: 180,
            boulderCount: 0
        )

        snapshot = snapshot.applying(
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .beginBoulder,
                at: start.addingTimeInterval(5)
            )
        )
        XCTAssertEqual(snapshot.phase, .climbing)
        XCTAssertEqual(snapshot.phaseStartedAt, start.addingTimeInterval(5))
        XCTAssertEqual(snapshot.boulderCount, 0)

        let duplicate = snapshot.applying(
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .beginBoulder,
                at: start.addingTimeInterval(6)
            )
        )
        XCTAssertEqual(duplicate, snapshot)

        snapshot = snapshot.applying(
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .endBoulder,
                at: start.addingTimeInterval(30)
            )
        )
        XCTAssertEqual(snapshot.phase, .resting)
        XCTAssertEqual(snapshot.phaseStartedAt, start.addingTimeInterval(30))
        XCTAssertEqual(snapshot.boulderCount, 1)

        let duplicateStop = snapshot.applying(
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .endBoulder,
                at: start.addingTimeInterval(31)
            )
        )
        XCTAssertEqual(duplicateStop, snapshot)
    }

    func testReplayKeepsEarlierEventsWhenALaterDuplicateIsRejected() {
        let start = Date(timeIntervalSince1970: 5_500)
        let engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .power, startedAt: start)
        let events = [
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .beginBoulder,
                at: start.addingTimeInterval(5)
            ),
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .beginBoulder,
                at: start.addingTimeInterval(6)
            ),
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .endBoulder,
                at: start.addingTimeInterval(30)
            ),
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .endBoulder,
                at: start.addingTimeInterval(31)
            )
        ]

        let replayed = ManualWorkoutActivityReplay.applying(events, to: engine)

        XCTAssertNil(replayed.attemptStartedAt)
        XCTAssertEqual(replayed.draft.attempts.count, 1)
        XCTAssertEqual(replayed.draft.attempts[0].startedAt, start.addingTimeInterval(5))
        XCTAssertEqual(replayed.draft.attempts[0].durationSeconds, 25)
    }

    func testStaleQueuedEventsAreDroppedForNewWorkout() {
        let oldStart = Date(timeIntervalSince1970: 6_000)
        let newStart = Date(timeIntervalSince1970: 7_000)
        let oldEvent = ManualWorkoutActivityEvent(
            workoutStartedAt: oldStart,
            action: .beginBoulder,
            at: oldStart.addingTimeInterval(10)
        )
        let currentEvent = ManualWorkoutActivityEvent(
            workoutStartedAt: newStart,
            action: .beginBoulder,
            at: newStart.addingTimeInterval(10)
        )

        let filtered = ManualWorkoutActivityDrain.matching(
            [oldEvent, currentEvent],
            workoutStartedAt: newStart
        )

        XCTAssertEqual(filtered, [currentEvent])
        XCTAssertFalse(oldEvent.matches(workoutStartedAt: newStart))
    }

    func testQueuedEventIdentitySurvivesUserDefaultsCodableRoundTrip() throws {
        let startedAt = Date(timeIntervalSince1970: 6_500)
        let event = ManualWorkoutActivityEvent(
            workoutStartedAt: startedAt,
            action: .endBoulder,
            at: startedAt.addingTimeInterval(30)
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ManualWorkoutActivityEvent.self, from: data)

        XCTAssertEqual(decoded.workoutStartedAt, startedAt)
        XCTAssertTrue(decoded.matches(workoutStartedAt: startedAt))
    }

    func testReconcileGuardProtectsActiveWorkoutFromOrphanSweep() {
        let activeWorkout = Date(timeIntervalSince1970: 8_000)

        XCTAssertTrue(
            ManualWorkoutActivityReconcileGuard.shouldReconcile(
                isActive: false,
                activeWorkoutStartedAt: nil
            )
        )
        XCTAssertFalse(
            ManualWorkoutActivityReconcileGuard.shouldReconcile(
                isActive: false,
                activeWorkoutStartedAt: activeWorkout
            )
        )
        XCTAssertFalse(
            ManualWorkoutActivityReconcileGuard.shouldReconcile(
                isActive: true,
                activeWorkoutStartedAt: nil
            )
        )
    }
}
