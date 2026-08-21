import XCTest
@testable import SendmeterCore

final class GuidedForceFullscreenPresentationTests: XCTestCase {
    private func preset(
        mode: ForceProtocolMode = .hold,
        repetitions: Int = 2,
        cadenceOut: Double = 3,
        cadenceReturn: Double = 1
    ) -> TindeqPreset {
        TindeqPreset(
            name: "Test protocol",
            holdSeconds: 10,
            repetitions: repetitions,
            sets: 2,
            restBetweenRepetitionsSeconds: 30,
            restBetweenSetsSeconds: 60,
            alternateSides: true,
            protocolMode: mode,
            cadenceOutSeconds: cadenceOut,
            cadenceReturnSeconds: cadenceReturn,
            prepareSeconds: 5
        )
    }

    func testStaticStageLabelsUseTheGuidedVocabulary() {
        let stages = ForceProtocolSchedule.stages(preset: preset(), startingSide: .left)

        let prepare = GuidedForceFullscreenPresentation.stage(stages[0], preset: preset(), elapsedSeconds: 1)
        XCTAssertEqual(prepare.label, "GET READY")
        XCTAssertEqual(prepare.phase, .prepare)
        XCTAssertEqual(prepare.accent, .caution)

        let hold = GuidedForceFullscreenPresentation.stage(stages[1], preset: preset(), elapsedSeconds: 4)
        XCTAssertEqual(hold.label, "HOLD")
        XCTAssertTrue(hold.detail.contains("Left"))
        XCTAssertEqual(hold.progress, 0.4, accuracy: 0.000_001)

        let switchStage = stages.first { $0.kind == .switchSide }!
        let switched = GuidedForceFullscreenPresentation.stage(switchStage, preset: preset(), elapsedSeconds: 0)
        XCTAssertEqual(switched.label, "SWITCH HANDS")
        XCTAssertEqual(switched.phase, .switchSide)
    }

    func testReverseActionSeparatesOutAndReturnWithoutChangingPersistenceStage() {
        let protocolValue = preset(mode: .reverseAction)
        let stage = ForceProtocolSchedule.stages(preset: protocolValue, startingSide: .left)
            .first { $0.kind == .work }!

        let out = GuidedForceFullscreenPresentation.stage(stage, preset: protocolValue, elapsedSeconds: 0.25)
        XCTAssertEqual(out.phase, .reverseOut)
        XCTAssertEqual(out.label, "OUT")
        XCTAssertTrue(out.detail.contains("Rep 1/2"))

        let returned = GuidedForceFullscreenPresentation.stage(stage, preset: protocolValue, elapsedSeconds: 3.25)
        XCTAssertEqual(returned.phase, .reverseReturn)
        XCTAssertEqual(returned.label, "RETURN")

        let secondOut = GuidedForceFullscreenPresentation.stage(stage, preset: protocolValue, elapsedSeconds: 4.01)
        XCTAssertEqual(secondOut.phase, .reverseOut)
        XCTAssertTrue(secondOut.detail.contains("Rep 2/2"))

        let finalDirection = GuidedForceFullscreenPresentation.stage(
            stage,
            preset: protocolValue,
            elapsedSeconds: stage.durationSeconds
        )
        XCTAssertEqual(finalDirection.phase, .reverseReturn)
    }

    func testPausedPresentationKeepsStageDetailAndUsesPauseLabel() {
        let stage = ForceProtocolSchedule.stages(preset: preset(), startingSide: .left)[1]
        let paused = GuidedForceFullscreenPresentation.stage(stage, preset: preset(), elapsedSeconds: 2, isPaused: true)

        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.label, "PAUSED")
        XCTAssertTrue(paused.detail.contains("resume when ready"))
        XCTAssertEqual(paused.progress, 0.2, accuracy: 0.000_001)
    }

    func testLayoutKeepsReadableFloorsOnSmallPortraitAndLandscape() {
        let portrait = GuidedForceLayout.resolve(width: 320, height: 568)
        XCTAssertGreaterThanOrEqual(portrait.actionDiameter, 96)
        XCTAssertGreaterThanOrEqual(portrait.chartMinimumHeight, 96)

        let landscape = GuidedForceLayout.resolve(width: 667, height: 375)
        XCTAssertGreaterThanOrEqual(landscape.actionDiameter, 96)
        XCTAssertGreaterThanOrEqual(landscape.chartMinimumHeight, 96)
        XCTAssertLessThan(landscape.actionDiameter, 184)

        let largeText = GuidedForceLayout.resolve(width: 320, height: 568, textScale: 1.5)
        XCTAssertLessThanOrEqual(largeText.actionDiameter, portrait.actionDiameter)
        XCTAssertGreaterThanOrEqual(largeText.chartMinimumHeight, 96)
    }

    func testLayoutAggregateFitIdentifiesPinnedPrimaryActionCases() {
        let compactPortrait = GuidedForceLayout.resolve(width: 320, height: 568)
        XCTAssertFalse(compactPortrait.essentialContentFits)
        XCTAssertGreaterThan(compactPortrait.essentialContentHeight, compactPortrait.viewportHeight)

        let roomyPortrait = GuidedForceLayout.resolve(width: 430, height: 932)
        XCTAssertTrue(roomyPortrait.essentialContentFits)

        let compactLandscape = GuidedForceLayout.resolve(width: 667, height: 375, textScale: 1.5)
        XCTAssertFalse(compactLandscape.essentialContentFits)
    }

    func testTerminalClaimPreventsAdvanceAndRepeatedTerminalClaims() {
        var policy = GuidedForceSessionPolicy()

        XCTAssertTrue(policy.claimAdvance())
        XCTAssertFalse(policy.claimAdvance())
        XCTAssertTrue(policy.canCommitAdvance)

        XCTAssertTrue(policy.claimTerminal())
        XCTAssertFalse(policy.canTick)
        XCTAssertFalse(policy.canStartStage)
        XCTAssertFalse(policy.canCommitAdvance)
        XCTAssertFalse(policy.claimAdvance())
        XCTAssertFalse(policy.claimTerminal())
    }

    func testAdvanceCanCommitOnlyBeforeTerminalClaim() {
        var policy = GuidedForceSessionPolicy()
        XCTAssertTrue(policy.claimAdvance())
        policy.finishAdvance()
        XCTAssertFalse(policy.canCommitAdvance)
        XCTAssertTrue(policy.claimAdvance())
        XCTAssertTrue(policy.claimTerminal())
        XCTAssertFalse(policy.canCommitAdvance)
    }

    func testHandsFreeMeasurementReanchorsWorkStageForFullDuration() {
        let protocolValue = preset(repetitions: 1)
        var run = ForceProtocolRun(preset: protocolValue, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        run.advance(at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(run.currentStage.kind, ForceProtocolStageKind.work)

        // The user was armed but did not pull until the old wall-clock stage
        // would already have expired. Re-anchoring gives the real pull the
        // complete work duration instead of an immediate stage advance.
        run.restartCurrentStage(at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(run.elapsedSeconds(at: Date(timeIntervalSince1970: 20.5)), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(run.remainingSeconds(at: Date(timeIntervalSince1970: 20.5)), 9.5, accuracy: 0.000_001)
    }

    func testHandsFreeTimingPolicyTransitionsFromWaitingToReanchorOnce() {
        XCTAssertTrue(
            GuidedForceHandsFreeTimingPolicy.isWaitingForPull(
                handsFreeEnabled: true,
                measurementObserved: false
            )
        )
        XCTAssertFalse(
            GuidedForceHandsFreeTimingPolicy.shouldReanchor(
                handsFreeEnabled: true,
                isMeasuring: false,
                measurementObserved: false
            )
        )
        XCTAssertTrue(
            GuidedForceHandsFreeTimingPolicy.shouldReanchor(
                handsFreeEnabled: true,
                isMeasuring: true,
                measurementObserved: false
            )
        )
        XCTAssertFalse(
            GuidedForceHandsFreeTimingPolicy.shouldReanchor(
                handsFreeEnabled: true,
                isMeasuring: true,
                measurementObserved: true
            )
        )
    }
}
