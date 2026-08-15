import XCTest
@testable import SendmeterCore

final class WorkoutEngineTests: XCTestCase {
    func testWorkoutUsesStableIDsAndFinishesRunningAttempt() throws {
        let userID = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var engine = PhoneWorkoutEngine(accountUserID: userID, phase: .power, startedAt: start)
        let sessionID = engine.draft.sessionID
        let workoutID = engine.draft.workoutID

        try engine.startAttempt(at: start.addingTimeInterval(10))
        let finished = try engine.finish(at: start.addingTimeInterval(40))

        XCTAssertEqual(finished.sessionID, sessionID)
        XCTAssertEqual(finished.workoutID, workoutID)
        XCTAssertEqual(finished.attempts.count, 1)
        XCTAssertEqual(finished.attempts[0].durationSeconds, 30)
        XCTAssertEqual(engine.durationMinutes, 1)
    }

    func testWorkoutRejectsDoubleStartAndEmptyFinish() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var engine = PhoneWorkoutEngine(accountUserID: UUID(), phase: .capacity, startedAt: start)
        try engine.startAttempt(at: start)
        XCTAssertThrowsError(try engine.startAttempt(at: start)) { error in
            XCTAssertEqual(error as? WorkoutEngineError, .attemptAlreadyRunning)
        }
        engine.cancelAttempt()
        XCTAssertThrowsError(try engine.finish(at: start.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? WorkoutEngineError, .emptyWorkout)
        }
    }

    func testRoutineStepDecodesSharedTypeScriptJSONShape() throws {
        let json = Data(#"{"label":"Hollow hold","detail":"Posterior tilt","s":20,"reps":3,"restS":10}"#.utf8)
        let step = try JSONDecoder().decode(RoutineStep.self, from: json)
        XCTAssertEqual(step.label, "Hollow hold")
        XCTAssertEqual(step.detail, "Posterior tilt")
        XCTAssertEqual(step.seconds, 20)
        XCTAssertEqual(step.repetitions, 3)
        XCTAssertEqual(step.restSeconds, 10)

        let encoded = try JSONEncoder().encode(step)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["id"])
        XCTAssertEqual(object["s"] as? Int, 20)
        XCTAssertEqual(object["reps"] as? Int, 3)
        XCTAssertEqual(object["restS"] as? Int, 10)
    }

    func testRoutineScheduleExpandsRepetitionsAndRests() {
        let preset = RoutinePreset(
            name: "Warmup",
            steps: [RoutineStep(label: "Hollow hold", seconds: 10, repetitions: 3, restSeconds: 5)]
        )
        let stages = RoutineEngine.stages(for: preset)
        XCTAssertEqual(stages.map(\.kind), [.work, .rest, .work, .rest, .work, .complete])
    }
}
