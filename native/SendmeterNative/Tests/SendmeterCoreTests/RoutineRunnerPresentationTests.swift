import XCTest
@testable import SendmeterCore

final class RoutineRunnerPresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func preset() -> RoutinePreset {
        RoutinePreset(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Strength primer",
            steps: [
                RoutineStep(label: "Front lever", seconds: 10, repetitions: 2, restSeconds: 3),
                RoutineStep(label: "Scapular pull", seconds: 8)
            ]
        )
    }

    private func wallClock(_ preset: RoutinePreset) -> PersistedRoutineRun {
        PersistedRoutineRun(
            presetID: preset.id,
            startedMs: start.millisecondsSince1970,
            skippedS: 0,
            pausedAtMs: nil,
            pausedTotalMs: 0,
            lastSeenMs: start.millisecondsSince1970
        )
    }

    func testWorkingSnapshotCarriesCurrentAndNextRepContext() {
        let routine = preset()
        var run = RoutineRun(preset: routine)
        run.start(at: start)

        let snapshot = RoutineRunnerSnapshot(
            run: run,
            preset: routine,
            wallClock: wallClock(routine),
            at: start.addingTimeInterval(2)
        )

        XCTAssertEqual(snapshot.visualState, .working)
        XCTAssertEqual(snapshot.visualState.title, "WORKING OUT")
        XCTAssertEqual(snapshot.current.stepNumber, 1)
        XCTAssertEqual(snapshot.current.stepCount, 2)
        XCTAssertEqual(snapshot.current.repetitionNumber, 1)
        XCTAssertEqual(snapshot.current.repetitionCount, 2)
        XCTAssertEqual(snapshot.current.repetitionsRemaining, 2)
        XCTAssertEqual(snapshot.next?.stage.kind, .rest)
        XCTAssertEqual(snapshot.stageNumber, 1)
        XCTAssertEqual(snapshot.stageCount, 4)
        XCTAssertEqual(snapshot.totalRoutineSeconds, 31)
        XCTAssertEqual(snapshot.timelineElapsedSeconds, 2)
        XCTAssertEqual(snapshot.currentRemainingSeconds, 8)
        XCTAssertEqual(snapshot.actualElapsedSeconds, 2)
        XCTAssertEqual(snapshot.timelineRemainingSeconds, 29)
    }

    func testRestSnapshotPointsAtTheNextRepWithoutInventingATransitionState() {
        let routine = preset()
        var run = RoutineRun(preset: routine)
        run.start(at: start)
        run.advance(at: start.addingTimeInterval(10))

        let snapshot = RoutineRunnerSnapshot(
            run: run,
            preset: routine,
            wallClock: wallClock(routine),
            at: start.addingTimeInterval(11)
        )

        XCTAssertEqual(snapshot.visualState, .rest)
        XCTAssertEqual(snapshot.visualState.title, "REST")
        XCTAssertEqual(snapshot.current.repetitionNumber, 2)
        XCTAssertEqual(snapshot.current.repetitionsRemaining, 1)
        XCTAssertEqual(snapshot.next?.stage.label, "Front lever")
        XCTAssertEqual(snapshot.next?.stage.kind, .work)
        XCTAssertEqual(Set([
            RoutineRunnerVisualState.working,
            .rest,
            .paused,
            .done
        ]).count, 4)
    }

    func testToGoIncludesTheDisplayedRepForTheApprovedRepThreeOfEightCopy() {
        let routine = RoutinePreset(
            name: "Rep context",
            steps: [RoutineStep(label: "Hang", seconds: 10, repetitions: 8)]
        )
        let stage = RoutineStage(
            kind: .work,
            label: "Hang",
            detail: nil,
            stepIndex: 0,
            repetition: 3,
            durationSeconds: 10
        )

        let context = RoutineRunnerStageContext(stage: stage, preset: routine)

        XCTAssertEqual(context.repetitionNumber, 3)
        XCTAssertEqual(context.repetitionCount, 8)
        XCTAssertEqual(context.repetitionsRemaining, 6)
    }

    func testPausedAndDoneSnapshotsUseOnlyTheApprovedVisualStates() {
        let routine = preset()
        var run = RoutineRun(preset: routine)
        run.start(at: start)
        run.pause(at: start.addingTimeInterval(4))
        let paused = RoutineRunnerSnapshot(
            run: run,
            preset: routine,
            wallClock: PersistedRoutineRun(
                presetID: routine.id,
                startedMs: start.millisecondsSince1970,
                skippedS: 0,
                pausedAtMs: start.addingTimeInterval(4).millisecondsSince1970,
                pausedTotalMs: 0,
                lastSeenMs: start.millisecondsSince1970
            ),
            at: start.addingTimeInterval(90)
        )
        XCTAssertEqual(paused.visualState, .paused)
        XCTAssertEqual(paused.actualElapsedSeconds, 4)

        while !run.isComplete {
            run.advance(at: start)
        }
        let done = RoutineRunnerSnapshot(
            run: run,
            preset: routine,
            wallClock: wallClock(routine),
            at: start.addingTimeInterval(20)
        )
        XCTAssertEqual(done.visualState, .done)
        XCTAssertEqual(done.visualState.title, "DONE")
    }

    func testLightRunnerBodyTreatmentsClearComputedContrastInEveryState() {
        let states: [RoutineRunnerVisualState] = [.working, .rest, .paused, .done]

        for state in states {
            let field = RoutineRunnerContrastPalette.field(for: state)
            let foreground = RoutineRunnerContrastPalette.foreground(for: state)
            let glass = RoutineRunnerContrastPalette.treatedGlassSurface(for: state)

            let glassCaption = RoutineRunnerContrastPalette.bodyText(on: glass, state: state)
            XCTAssertGreaterThanOrEqual(
                glassCaption.contrastRatio(to: glass),
                RoutineRunnerContrastPalette.minimumBodyContrast,
                "\(state) glass caption"
            )
            XCTAssertGreaterThanOrEqual(
                foreground.contrastRatio(to: field),
                RoutineRunnerContrastPalette.minimumLargeTextContrast,
                "\(state) countdown"
            )

            if state != .done {
                let bareCaption = foreground.over(
                    field,
                    opacity: RoutineRunnerContrastPalette.bodyTextOpacity
                )
                XCTAssertGreaterThanOrEqual(
                    bareCaption.contrastRatio(to: field),
                    RoutineRunnerContrastPalette.minimumBodyContrast,
                    "\(state) bare phase detail"
                )
            }
        }
    }

    func testDoneCompletionUsesDarkForegroundOnTheIdentityField() {
        let field = RoutineRunnerContrastPalette.field(for: .done)
        let completion = RoutineRunnerContrastPalette.doneCompletionForeground

        XCTAssertGreaterThanOrEqual(
            completion.contrastRatio(to: field),
            RoutineRunnerContrastPalette.minimumBodyContrast
        )
        XCTAssertLessThan(
            RoutineRunnerRGB.white.contrastRatio(to: field),
            RoutineRunnerContrastPalette.minimumBodyContrast,
            "white alone cannot clear body-text contrast on the DONE field"
        )
    }

    func testPhaseForegroundClearsTheCloseChipCasesThatRawAlertFails() {
        let rawAlert = RoutineRunnerRGB(hex: 0xE5743A)
        let restGlass = RoutineRunnerContrastPalette.treatedGlassSurface(for: .rest)
        XCTAssertLessThan(
            rawAlert.contrastRatio(to: restGlass),
            RoutineRunnerContrastPalette.minimumBodyContrast,
            "the former raw alert-orange Close label must remain a failing regression vector"
        )

        for state in [RoutineRunnerVisualState.working, .rest, .paused, .done] {
            let glass = RoutineRunnerContrastPalette.treatedGlassSurface(for: state)
            let foreground = RoutineRunnerContrastPalette.foreground(for: state)
            XCTAssertGreaterThanOrEqual(
                foreground.contrastRatio(to: glass),
                RoutineRunnerContrastPalette.minimumBodyContrast,
                "\(state) Close label"
            )
        }
    }
}
