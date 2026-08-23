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

    func testIntentApplicationTransitionsNativelyAndIsIdempotent() {
        let start = Date(timeIntervalSince1970: 5_000)
        var snapshot = ManualWorkoutActivitySnapshot(
            phase: .resting,
            phaseStartedAt: start,
            restTargetSeconds: 180,
            boulderCount: 0
        )

        snapshot = snapshot.applying(
            ManualWorkoutActivityEvent(action: .beginBoulder, at: start.addingTimeInterval(5))
        )
        XCTAssertEqual(snapshot.phase, .climbing)
        XCTAssertEqual(snapshot.phaseStartedAt, start.addingTimeInterval(5))
        XCTAssertEqual(snapshot.boulderCount, 0)

        let duplicate = snapshot.applying(
            ManualWorkoutActivityEvent(action: .beginBoulder, at: start.addingTimeInterval(6))
        )
        XCTAssertEqual(duplicate, snapshot)

        snapshot = snapshot.applying(
            ManualWorkoutActivityEvent(action: .endBoulder, at: start.addingTimeInterval(30))
        )
        XCTAssertEqual(snapshot.phase, .resting)
        XCTAssertEqual(snapshot.phaseStartedAt, start.addingTimeInterval(30))
        XCTAssertEqual(snapshot.boulderCount, 1)

        let duplicateStop = snapshot.applying(
            ManualWorkoutActivityEvent(action: .endBoulder, at: start.addingTimeInterval(31))
        )
        XCTAssertEqual(duplicateStop, snapshot)
    }
}
