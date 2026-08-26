import XCTest
@testable import SendmeterCore

final class RoutineAudioTests: XCTestCase {
    private let work = RoutineStage(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        kind: .work,
        label: "Front lever",
        detail: nil,
        stepIndex: 0,
        repetition: 1,
        durationSeconds: 10
    )
    private let rest = RoutineStage(
        id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        kind: .rest,
        label: "Rest",
        detail: "Before Front lever 2/2",
        stepIndex: 0,
        repetition: 1,
        durationSeconds: 3
    )

    func testWorkTicksOncePerSecondAndUsesSoundOnlyCountdownAtThreeTwoOne() {
        var controller = RoutineAudioCueController()

        XCTAssertNil(controller.observe(stage: work, remainingSeconds: 10, isPaused: false))
        XCTAssertEqual(
            controller.observe(stage: work, remainingSeconds: 9, isPaused: false),
            .clockTick
        )
        XCTAssertNil(controller.observe(stage: work, remainingSeconds: 9, isPaused: false))
        XCTAssertEqual(
            controller.observe(stage: work, remainingSeconds: 3, isPaused: false),
            .countdown(second: 3)
        )
        XCTAssertEqual(
            controller.observe(stage: work, remainingSeconds: 2, isPaused: false),
            .countdown(second: 2)
        )
        XCTAssertEqual(
            controller.observe(stage: work, remainingSeconds: 1, isPaused: false),
            .countdown(second: 1)
        )
    }

    func testRestGetsThreeTwoOneAndPhaseEndWithoutAVisualTransitionCue() {
        var controller = RoutineAudioCueController()

        XCTAssertEqual(
            controller.observe(stage: rest, remainingSeconds: 3, isPaused: false),
            .countdown(second: 3)
        )
        XCTAssertEqual(
            controller.observe(stage: rest, remainingSeconds: 2, isPaused: false),
            .countdown(second: 2)
        )
        XCTAssertEqual(
            controller.observe(stage: rest, remainingSeconds: 1, isPaused: false),
            .countdown(second: 1)
        )
        XCTAssertEqual(controller.phaseEnded(stageID: rest.id), .phaseEnd)
        XCTAssertNil(controller.phaseEnded(stageID: rest.id))
    }

    func testStageEndIsNotDoublePlayedAcrossObservationAndSkip() {
        var controller = RoutineAudioCueController()
        XCTAssertNil(controller.observe(stage: work, remainingSeconds: 4, isPaused: false))
        controller.skipped(stageID: work.id)

        XCTAssertNil(controller.observe(stage: rest, remainingSeconds: 3, isPaused: false))
        XCTAssertNil(controller.phaseEnded(stageID: work.id))
    }

    func testPauseAndBackgroundReanchorWithoutCatchUpOrReplay() {
        var controller = RoutineAudioCueController()
        XCTAssertNil(controller.observe(stage: work, remainingSeconds: 10, isPaused: false))
        controller.suspend()
        XCTAssertNil(controller.observe(stage: work, remainingSeconds: 3, isPaused: false))
        controller.reanchor(stage: work, remainingSeconds: 3)
        XCTAssertNil(controller.observe(stage: work, remainingSeconds: 3, isPaused: false))
        controller.resume(stage: work, remainingSeconds: 3)
        XCTAssertNil(controller.observe(stage: work, remainingSeconds: 3, isPaused: false))
        XCTAssertEqual(
            controller.observe(stage: work, remainingSeconds: 2, isPaused: false),
            .countdown(second: 2)
        )
    }

    func testForegroundCatchUpKeepsPhaseEndsSilentAcrossMultipleExpiredStages() {
        let preset = RoutinePreset(
            name: "Catch-up",
            steps: [
                RoutineStep(label: "First", seconds: 2),
                RoutineStep(label: "Second", seconds: 2),
                RoutineStep(label: "Settled", seconds: 10)
            ]
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let foreground = start.addingTimeInterval(5)
        var run = RoutineRun(preset: preset)
        run.start(at: start)

        var controller = RoutineAudioCueController()
        XCTAssertEqual(
            controller.observe(stage: run.currentStage, remainingSeconds: 2, isPaused: false),
            .countdown(second: 2)
        )
        controller.suspend()

        while !run.isComplete, run.remainingSeconds(at: foreground) <= 0 {
            controller.reanchor(
                stage: run.currentStage,
                remainingSeconds: run.remainingSeconds(at: foreground)
            )
            XCTAssertNil(controller.phaseEnded(stageID: run.currentStage.id))
            XCTAssertTrue(run.advanceIfNeeded(at: foreground))
        }

        XCTAssertEqual(run.currentStage.label, "Settled")
        controller.resume(
            stage: run.currentStage,
            remainingSeconds: run.remainingSeconds(at: foreground)
        )
        XCTAssertNil(controller.observe(
            stage: run.currentStage,
            remainingSeconds: run.remainingSeconds(at: foreground),
            isPaused: false
        ))
        XCTAssertEqual(
            controller.observe(
                stage: run.currentStage,
                remainingSeconds: run.remainingSeconds(at: foreground.addingTimeInterval(1)),
                isPaused: false
            ),
            .clockTick
        )
    }

    func testAudioStatusSeparatesMutedAndUnavailableWithoutChangingRunPersistence() {
        XCTAssertEqual(
            RoutineAudioPolicy.status(userMuted: false, systemMuted: false, systemAvailable: true),
            .on
        )
        XCTAssertEqual(
            RoutineAudioPolicy.status(userMuted: true, systemMuted: false, systemAvailable: true),
            .muted
        )
        XCTAssertEqual(
            RoutineAudioPolicy.status(userMuted: false, systemMuted: true, systemAvailable: true),
            .muted
        )
        XCTAssertEqual(
            RoutineAudioPolicy.status(userMuted: false, systemMuted: false, systemAvailable: false),
            .unavailable
        )
        XCTAssertFalse(RoutineAudioPolicy.shouldPlay(.clockTick, status: .muted))
        XCTAssertFalse(RoutineAudioPolicy.shouldPlay(.phaseEnd, status: .unavailable))
        XCTAssertTrue(RoutineAudioPolicy.shouldPlay(.countdown(second: 1), status: .on))
    }
}
