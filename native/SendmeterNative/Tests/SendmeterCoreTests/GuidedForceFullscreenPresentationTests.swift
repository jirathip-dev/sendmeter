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

    func testLayoutKeepsAReadableChartFloorOnSmallPortraitAndLandscape() {
        let portrait = GuidedForceLayout.resolve(width: 320, height: 568)
        XCTAssertGreaterThanOrEqual(portrait.chartMinimumHeight, 96)

        let landscape = GuidedForceLayout.resolve(width: 667, height: 375)
        XCTAssertGreaterThanOrEqual(landscape.chartMinimumHeight, 96)

        let largeText = GuidedForceLayout.resolve(width: 320, height: 568, textScale: 1.5)
        XCTAssertGreaterThanOrEqual(largeText.chartMinimumHeight, 96)
    }

    func testLayoutAggregateFitKeepsTheCompactScrollBoundary() {
        let compactPortrait = GuidedForceLayout.resolve(width: 320, height: 568)
        XCTAssertFalse(compactPortrait.essentialContentFits)
        XCTAssertGreaterThan(compactPortrait.essentialContentHeight, compactPortrait.viewportHeight)

        let roomyPortrait = GuidedForceLayout.resolve(width: 430, height: 932)
        XCTAssertTrue(roomyPortrait.essentialContentFits)
        XCTAssertGreaterThan(roomyPortrait.flexibleChartHeight, roomyPortrait.chartMinimumHeight)
        XCTAssertEqual(compactPortrait.flexibleChartHeight, compactPortrait.chartMinimumHeight)

        let compactLandscape = GuidedForceLayout.resolve(width: 667, height: 375, textScale: 1.5)
        XCTAssertFalse(compactLandscape.essentialContentFits)
    }

    // MARK: - #993: the budget must cover what the screen renders

    /// #993: the rendered heights of every fixed section, measured on the
    /// smallest supported phone (iPhone SE 3rd generation, 375×667 pt screen /
    /// 375×647 pt safe-area rect, default text size) with the SET REST fixture
    /// — `docs/evidence/issue-993/measurement-se3-default.log.gz`:
    /// `topBar=56.0 identityHeader=103.0 phaseBanner=199.0 statusRow=27.5
    /// targetCoach=92.5 liveChartCard=227.0 chart=116.5 controlsBar=64.0`
    /// (the live card's readout is its 227.0 minus the 116.5 trace). Before
    /// #993 the budget reserved 160 for the banner and 46 for the identity
    /// header, so it claimed a fit for a stack that overflowed and the
    /// controls row landed past the screen edge.
    func testLayoutBudgetReservesTheMeasuredSectionFloorsOfTheSmallestPhone() {
        let layout = GuidedForceLayout.resolve(width: 375, height: 647)
        let measuredFloors: [GuidedForceLayoutSection: Double] = [
            .topBar: 56.0,
            .identityHeader: 103.0,
            .phaseBanner: 199.0,
            .statusRow: 27.5,
            .targetCoach: 92.5,
            .chartHeader: 110.5,
            .controlsBar: 64.0,
        ]
        for (section, floor) in measuredFloors {
            XCTAssertGreaterThanOrEqual(
                layout.reservedHeight(for: section),
                floor,
                "\(section.rawValue) reserves less height than it renders on the smallest supported phone"
            )
        }
        XCTAssertGreaterThanOrEqual(layout.reservedHeight(for: .chartFloor), layout.chartMinimumHeight)

        // The budget is exactly the sections it claims to cover, the five gaps
        // the scroll stack spends, and the container padding — no section can
        // be dropped from the sum without failing here.
        let sectionTotal = layout.sectionBudgets.map(\.reservedHeight).reduce(0, +)
        XCTAssertEqual(
            layout.essentialContentHeight,
            sectionTotal + layout.sectionGap * 5 + 20,
            accuracy: 0.001
        )
    }

    /// #993: once the view has reported what it rendered, that measurement
    /// decides the fit — a stack taller than the viewport is never claimed as
    /// fitting, and the chart stays at its floor instead of absorbing the
    /// difference.
    func testMeasuredStackReplacesTheStaticBudgetInTheFitDecision() {
        // The SE rest screen's measured stack: 785.0 of padded content with
        // the trace at 116.5, plus the 64.0 pinned controls bar.
        let seMeasurement = GuidedForceLayoutMeasurement(
            scrollContentHeight: 785.0,
            chartHeight: 116.5,
            controlsBarHeight: 64.0
        )

        let smallest = GuidedForceLayout.resolve(width: 375, height: 647, measurement: seMeasurement)
        XCTAssertFalse(smallest.essentialContentFits, "the measured stack overflows the smallest phone")
        XCTAssertEqual(smallest.flexibleChartHeight, smallest.chartMinimumHeight)

        // The same rendered stack on a viewport that genuinely has room: the
        // trace grows into the slack but stops at its visual maximum.
        let roomy = GuidedForceLayout.resolve(width: 402, height: 1000, measurement: seMeasurement)
        XCTAssertTrue(roomy.essentialContentFits)
        XCTAssertGreaterThan(roomy.flexibleChartHeight, roomy.chartMinimumHeight)
        XCTAssertLessThanOrEqual(roomy.flexibleChartHeight, roomy.chartMaximumHeight)

        // A static budget alone can still claim a fit the rendered screen does
        // not have (this viewport's 890 pt budget fits in 900 pt, while the
        // 900 pt stack measured there does not): the measurement must win.
        let staticOnly = GuidedForceLayout.resolve(width: 375, height: 900)
        XCTAssertTrue(staticOnly.essentialContentFits)
        let overflowing = GuidedForceLayoutMeasurement(
            scrollContentHeight: 900.0,
            chartHeight: 116.5,
            controlsBarHeight: 64.0
        )
        let measured = GuidedForceLayout.resolve(width: 375, height: 900, measurement: overflowing)
        XCTAssertFalse(measured.essentialContentFits, "a rendered overflow must never be claimed as a fit")
        XCTAssertEqual(measured.flexibleChartHeight, measured.chartMinimumHeight)
    }

    /// #993: the trace stops at its intended visual maximum instead of taking
    /// every point the viewport has left.
    func testFlexibleChartStopsAtItsVisualMaximum() {
        let tall = GuidedForceLayout.resolve(width: 402, height: 1400)
        XCTAssertTrue(tall.essentialContentFits)
        XCTAssertEqual(tall.flexibleChartHeight, tall.chartMaximumHeight)
        XCTAssertLessThan(
            tall.flexibleChartHeight,
            tall.chartMinimumHeight + (tall.viewportHeight - tall.essentialContentHeight)
        )

        for height in [320.0, 568, 647, 780, 932, 1400] {
            let layout = GuidedForceLayout.resolve(width: 375, height: height)
            XCTAssertGreaterThanOrEqual(layout.chartMaximumHeight, layout.chartMinimumHeight)
            XCTAssertLessThanOrEqual(layout.flexibleChartHeight, layout.chartMaximumHeight)
        }
    }

    /// #993: a larger text size reserves MORE, never less — the estimate must
    /// not claim a fit an accessibility-sized stack does not have.
    func testLargerTextReservesMoreAndNeverClaimsAFitOnTheSmallestPhone() {
        let base = GuidedForceLayout.resolve(width: 375, height: 647)
        let large = GuidedForceLayout.resolve(width: 375, height: 647, textScale: 1.5)
        let accessibility = GuidedForceLayout.resolve(width: 375, height: 647, textScale: 3.1)

        XCTAssertGreaterThan(large.essentialContentHeight, base.essentialContentHeight)
        XCTAssertGreaterThan(accessibility.essentialContentHeight, large.essentialContentHeight)
        XCTAssertFalse(large.essentialContentFits)
        XCTAssertFalse(accessibility.essentialContentFits)
    }

    /// #993: the essential height does not depend on how tall the flexible
    /// chart happens to be — the measurement substitutes the chart's floor for
    /// the chart, so the fit decision cannot feed back into itself.
    func testMeasurementKeepsTheFlexibleChartOutOfTheEssentialHeight() {
        let chartFloor = 116.5
        let longChart = GuidedForceLayoutMeasurement(
            scrollContentHeight: 785.0,
            chartHeight: 240.0,
            controlsBarHeight: 64.0
        )
        let floorChart = GuidedForceLayoutMeasurement(
            scrollContentHeight: 661.5,
            chartHeight: 116.5,
            controlsBarHeight: 64.0
        )
        XCTAssertEqual(
            longChart.essentialHeight(chartFloor: chartFloor),
            floorChart.essentialHeight(chartFloor: chartFloor),
            accuracy: 0.001
        )
        XCTAssertEqual(
            longChart.essentialHeight(chartFloor: chartFloor),
            785.0 - 240.0 + chartFloor + 64.0,
            accuracy: 0.001
        )
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

    func testPauseClaimFreezesTicksUntilPersistenceFinishes() {
        var policy = GuidedForceSessionPolicy()

        XCTAssertTrue(policy.claimPause())
        XCTAssertFalse(policy.canTick)
        XCTAssertFalse(policy.claimAdvance())
        XCTAssertFalse(policy.claimPause())

        policy.finishPause()
        XCTAssertTrue(policy.canTick)
        XCTAssertTrue(policy.claimAdvance())
    }

    func testSkipMarksAnActiveWorkSavePartial() {
        XCTAssertFalse(GuidedForceSessionPolicy.recordingIsPartial(for: .scheduled))
        XCTAssertTrue(GuidedForceSessionPolicy.recordingIsPartial(for: .skip))
    }

    func testPauseAndTickerInterleavingCannotAdvanceUntilPausePersistenceFinishes() {
        var policy = GuidedForceSessionPolicy()

        XCTAssertTrue(policy.claimPause())
        XCTAssertFalse(policy.claimAdvance(), "a ticker continuation must not claim the paused stage")

        policy.finishPause()
        XCTAssertTrue(policy.claimAdvance(), "the next tick may advance only after persistence completes")
    }

    func testAuthTransitionTeardownPrecedesAccountRevocation() {
        XCTAssertEqual(
            GuidedForceAuthTransitionPolicy.steps(hasActiveProtocol: true),
            [.teardownGuidedProtocol, .drainQueue, .revokeAuth]
        )
        XCTAssertEqual(
            GuidedForceAuthTransitionPolicy.steps(hasActiveProtocol: false),
            [.drainQueue, .revokeAuth]
        )

        let accountA = UUID()
        let accountB = UUID()
        XCTAssertTrue(
            GuidedForceAuthTransitionPolicy.passwordRecoveryNeedsTeardown(
                currentUserID: accountA,
                nextUserID: accountB
            )
        )
        XCTAssertTrue(
            GuidedForceAuthTransitionPolicy.passwordRecoveryNeedsTeardown(
                currentUserID: accountA,
                nextUserID: nil
            )
        )
        XCTAssertFalse(
            GuidedForceAuthTransitionPolicy.passwordRecoveryNeedsTeardown(
                currentUserID: accountA,
                nextUserID: accountA
            )
        )
        XCTAssertFalse(
            GuidedForceAuthTransitionPolicy.passwordRecoveryNeedsTeardown(
                currentUserID: nil,
                nextUserID: accountB
            )
        )

        XCTAssertTrue(
            GuidedForceAuthTransitionPolicy.canClearGuidedOwner(
                currentOwnerID: accountA,
                settledOwnerID: accountA
            )
        )
        XCTAssertFalse(
            GuidedForceAuthTransitionPolicy.canClearGuidedOwner(
                currentOwnerID: accountB,
                settledOwnerID: accountA
            ),
            "an old terminal callback must not clear a newer guided owner"
        )
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
        XCTAssertFalse(
            GuidedForceHandsFreeTimingPolicy.isWaitingForPull(
                handsFreeEnabled: true,
                measurementObserved: true
            )
        )
        XCTAssertFalse(
            GuidedForceHandsFreeTimingPolicy.shouldReanchor(
                handsFreeEnabled: true,
                isMeasuring: false,
                measurementObserved: true
            )
        )
    }

    func testResumedHandsFreeRunKeepsAlreadyElapsedWorkTime() {
        let protocolValue = preset(repetitions: 1)
        var run = ForceProtocolRun(preset: protocolValue, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        run.advance(at: Date(timeIntervalSince1970: 5))
        run.pause(at: Date(timeIntervalSince1970: 8))
        run.resume(at: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(run.elapsedSeconds(at: Date(timeIntervalSince1970: 20)), 3, accuracy: 0.000_001)
        XCTAssertEqual(run.remainingSeconds(at: Date(timeIntervalSince1970: 20)), 7, accuracy: 0.000_001)
    }

    func testObservedHandsFreeReleaseKeepsTheScheduledClockMoving() {
        let protocolValue = preset(repetitions: 1)
        var run = ForceProtocolRun(preset: protocolValue, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        run.advance(at: Date(timeIntervalSince1970: 5))
        run.restartCurrentStage(at: Date(timeIntervalSince1970: 10))

        // The controller may already report not-measuring after release, but
        // the observed pull owns the rest of this scheduled work window.
        XCTAssertFalse(
            GuidedForceHandsFreeTimingPolicy.isWaitingForPull(
                handsFreeEnabled: true,
                measurementObserved: true
            )
        )
        XCTAssertEqual(run.remainingSeconds(at: Date(timeIntervalSince1970: 13)), 7, accuracy: 0.000_001)
    }

    // MARK: - #939 — rest lines hand off to the NEXT set/rep

    private func rampedPreset(
        mode: ForceProtocolMode = .hold,
        repetitions: Int = 2,
        sets: Int = 2,
        holdSeconds: Int = 10,
        holdSecondsBySet: [Int]? = nil,
        restBetweenRepetitionsSeconds: Int = 30,
        alternateSides: Bool = true,
        prepareSeconds: Int = 5,
        cadenceOut: Double = 3,
        cadenceReturn: Double = 1
    ) -> TindeqPreset {
        TindeqPreset(
            name: "Shape",
            holdSeconds: holdSeconds,
            holdSecondsBySet: holdSecondsBySet,
            repetitions: repetitions,
            sets: sets,
            restBetweenRepetitionsSeconds: restBetweenRepetitionsSeconds,
            restBetweenSetsSeconds: 60,
            alternateSides: alternateSides,
            protocolMode: mode,
            cadenceOutSeconds: cadenceOut,
            cadenceReturnSeconds: cadenceReturn,
            prepareSeconds: prepareSeconds
        )
    }

    func testRepRestDetailShowsTheNextRepAndItsHold() {
        let protocolValue = preset(repetitions: 3)
        let run = ForceProtocolRun(preset: protocolValue, startingSide: .left, selectedSide: .both)
        let rest = run.stages.first { $0.kind == .restBetweenRepetitions }!

        let presentation = GuidedForceFullscreenPresentation.stage(rest, preset: protocolValue, elapsedSeconds: 4)

        XCTAssertEqual(presentation.phase, .rest)
        XCTAssertEqual(presentation.label, "REST")
        XCTAssertEqual(presentation.detail, "Next: Rep 2/3 · 10s hold · Left")
    }

    func testSetRestDetailShowsTheNextSetAndRep() {
        let protocolValue = preset()
        let run = ForceProtocolRun(preset: protocolValue, startingSide: .left, selectedSide: .both)
        let rest = run.stages.first { $0.kind == .restBetweenSets }!

        let presentation = GuidedForceFullscreenPresentation.stage(rest, preset: protocolValue, elapsedSeconds: 4)

        XCTAssertEqual(presentation.phase, .setRest)
        XCTAssertEqual(presentation.label, "SET REST")
        XCTAssertEqual(presentation.detail, "Next: Set 2 · Rep 1 · 10s hold · Left")
    }

    func testSetRestDetailQuotesTheNextSetsRampedHold() {
        let protocolValue = rampedPreset(holdSeconds: 10, holdSecondsBySet: [12, 18], alternateSides: false)
        let run = ForceProtocolRun(preset: protocolValue, startingSide: .left)
        let rest = run.stages.first { $0.kind == .restBetweenSets }!

        let presentation = GuidedForceFullscreenPresentation.stage(rest, preset: protocolValue, elapsedSeconds: 4)

        // The NEXT set's ramp — not the preset's base hold — and no side,
        // because this preset's work stages stay unspecified for a Both run.
        XCTAssertEqual(presentation.detail, "Next: Set 2 · Rep 1 · 18s hold")
    }

    func testSingleSideSelectionNamesTheSideTheRestHandsOffTo() {
        // #901: a Left/Right selection runs that side only even when the
        // preset alternates, so the hand-off must name it.
        let protocolValue = preset(repetitions: 3)
        for selectedSide: TindeqSide in [.left, .right] {
            let run = ForceProtocolRun(
                preset: protocolValue,
                startingSide: selectedSide == .right ? .right : .left,
                selectedSide: selectedSide
            )
            let rest = run.stages.first { $0.kind == .restBetweenRepetitions }!

            let presentation = GuidedForceFullscreenPresentation.stage(rest, preset: protocolValue, elapsedSeconds: 4)

            XCTAssertEqual(presentation.detail, "Next: Rep 2/3 · 10s hold · \(selectedSide.label)")
        }
    }

    func testReverseActionSetRestQuotesTheNextSetWithoutARepIndex() {
        let protocolValue = preset(mode: .reverseAction, repetitions: 4)
        let run = ForceProtocolRun(preset: protocolValue, startingSide: .left, selectedSide: .both)
        let rest = run.stages.first { $0.kind == .restBetweenSets }!

        let presentation = GuidedForceFullscreenPresentation.stage(rest, preset: protocolValue, elapsedSeconds: 4)

        // 4 cadence repetitions × (3s out + 1s return): the whole next set,
        // with no rep index the user is not at yet.
        XCTAssertEqual(presentation.detail, "Next: Set 2 · 16s reverse action · Left")
    }

    func testLastRestBeforeCompletionShowsTheCompletionCue() {
        let protocolValue = preset()
        // The shipped schedule only emits rests BETWEEN reps/sets, so it never
        // rests before `.complete`; the last-rest case is built directly here. A rest
        // with nothing to hand off to must never invent a next set.
        let lastRest = ForceProtocolStage(
            kind: .restBetweenSets,
            setNumber: protocolValue.sets,
            repetitionNumber: protocolValue.repetitions,
            side: .unspecified,
            durationSeconds: 60,
            label: "Set rest"
        )

        let presentation = GuidedForceFullscreenPresentation.stage(lastRest, preset: protocolValue, elapsedSeconds: 5)

        XCTAssertEqual(presentation.phase, .setRest)
        XCTAssertEqual(presentation.detail, "Last set done · finishing")
        XCTAssertFalse(presentation.detail.contains("Next"))
    }

    /// #940: the completed run is an explicit next step, not a dead
    /// countdown. The DONE panel's line is ONE shared string (so the banner
    /// and the detail path cannot drift) and it names the inline action while
    /// stating that the gauge session stays live (#941).
    func testCompleteStageCarriesTheNextStepPrompt() {
        let stage = ForceProtocolStage(
            kind: .complete,
            setNumber: 1,
            repetitionNumber: 1,
            side: .unspecified,
            durationSeconds: 0,
            label: "Complete"
        )

        let presentation = GuidedForceFullscreenPresentation.stage(stage, preset: preset(), elapsedSeconds: 0)

        XCTAssertEqual(presentation.phase, .complete)
        XCTAssertEqual(presentation.label, "DONE")
        XCTAssertEqual(presentation.accent, .optimal)
        XCTAssertEqual(presentation.detail, GuidedForceFullscreenPresentation.completionDetail)
        XCTAssertEqual(presentation.detail, "Protocol complete · Done returns to your session")
        XCTAssertFalse(presentation.detail.contains("00:00"))
        XCTAssertTrue(presentation.detail.contains("Done"))
    }

    /// #939: the presentation never re-derives the schedule — the rest's
    /// hand-off IS the run's next work stage. Prove that for every preset
    /// variant the app can build and every side selection, so a silent index or
    /// arithmetic drift cannot hide behind the rendered line.
    func testRestHandoffMatchesTheRunStageItLeadsInto() {
        struct Launch {
            let name: String
            let preset: TindeqPreset
            let startingSide: TindeqSide
            let selectedSide: TindeqSide
        }

        let launches: [Launch] = [
            Launch(
                name: "alternating Both, left first",
                preset: rampedPreset(),
                startingSide: .left,
                selectedSide: .both
            ),
            Launch(
                name: "alternating Both, right first",
                preset: rampedPreset(),
                startingSide: .right,
                selectedSide: .both
            ),
            Launch(
                name: "single side Left",
                preset: rampedPreset(alternateSides: true),
                startingSide: .left,
                selectedSide: .left
            ),
            Launch(
                name: "single side Right",
                preset: rampedPreset(alternateSides: true),
                startingSide: .left,
                selectedSide: .right
            ),
            Launch(
                name: "non-alternating preset, Both",
                preset: rampedPreset(alternateSides: false),
                startingSide: .left,
                selectedSide: .both
            ),
            Launch(
                name: "legacy unspecified selection",
                preset: rampedPreset(alternateSides: false),
                startingSide: .left,
                selectedSide: .unspecified
            ),
            Launch(
                name: "three sets, ramped holds",
                preset: rampedPreset(repetitions: 3, sets: 3, holdSecondsBySet: [8, 12, 16]),
                startingSide: .left,
                selectedSide: .both
            ),
            Launch(
                name: "no prepare stage",
                preset: rampedPreset(prepareSeconds: 0),
                startingSide: .left,
                selectedSide: .both
            ),
            Launch(
                name: "zero-length rests",
                preset: rampedPreset(restBetweenRepetitionsSeconds: 0),
                startingSide: .left,
                selectedSide: .both
            ),
            Launch(
                name: "reverse action",
                preset: rampedPreset(mode: .reverseAction, repetitions: 4),
                startingSide: .left,
                selectedSide: .both
            )
        ]

        for launch in launches {
            let run = ForceProtocolRun(
                preset: launch.preset,
                startingSide: launch.startingSide,
                selectedSide: launch.selectedSide
            )
            for (index, stage) in run.stages.enumerated() {
                let isRest = stage.kind == .restBetweenRepetitions || stage.kind == .restBetweenSets
                guard isRest else {
                    XCTAssertNil(stage.handoff, "\(launch.name): only a rest carries a hand-off")
                    continue
                }
                guard index + 1 < run.stages.count else {
                    XCTFail("\(launch.name): a generated rest is never the terminal stage")
                    continue
                }
                let next = run.stages[index + 1]
                XCTAssertEqual(next.kind, .work, "\(launch.name): a rest must lead into work")
                guard let handoff = stage.handoff else {
                    XCTFail("\(launch.name): the rest at \(index) has no hand-off")
                    continue
                }
                XCTAssertEqual(handoff.setNumber, next.setNumber, launch.name)
                XCTAssertEqual(handoff.repetitionNumber, next.repetitionNumber, launch.name)
                XCTAssertEqual(handoff.side, next.side, launch.name)
                XCTAssertEqual(handoff.durationSeconds, next.durationSeconds, accuracy: 0.000_001)
                XCTAssertEqual(handoff.repetitionTotal, max(1, launch.preset.repetitions), launch.name)
                XCTAssertEqual(handoff.mode, launch.preset.protocolMode, launch.name)
            }
        }
    }

    // MARK: - #998 — the Target Coach renders only while a pull is measured

    /// #998: the phase → content mapping for the one section whose presence
    /// changes with the phase. The coach renders exactly in the measurement
    /// phases (hold / reverse-action work, including the paused work state)
    /// and in no rest, transition, or completed phase. If a future phase
    /// renders it (or a rest starts rendering it again), this fails.
    func testTargetCoachRendersOnlyWhileAPullIsMeasured() {
        let expected: [GuidedForcePhase: Bool] = [
            .hold: true,
            .reverseOut: true,
            .reverseReturn: true,
            .paused: true,
            .prepare: false,
            .switchSide: false,
            .rest: false,
            .setRest: false,
            .complete: false
        ]

        for (phase, renders) in expected {
            XCTAssertEqual(
                GuidedForceFullscreenPresentation.rendersTargetCoach(phase: phase),
                renders,
                "\(phase.rawValue) must \(renders ? "render" : "not render") the Target Coach"
            )
        }
    }

    /// #998: the mapping must hold for the phases the real schedule produces,
    /// because the guided full-screen calls it with `presentation.phase`. A
    /// rest stage (either flavour) renders no coach; a work stage — HOLD or
    /// the reverse-action OUT/RETURN — renders it, so the rest screen can no
    /// longer spend the coach's measured 92.5 pt.
    func testTargetCoachRenderingFollowsThePhaseTheRunnerRenders() {
        for mode in [ForceProtocolMode.hold, .reverseAction] {
            let protocolValue = preset(mode: mode)
            let run = ForceProtocolRun(preset: protocolValue, startingSide: .left)
            for stage in run.stages {
                let presentation = GuidedForceFullscreenPresentation.stage(
                    stage,
                    preset: protocolValue,
                    elapsedSeconds: 1
                )
                XCTAssertEqual(
                    GuidedForceFullscreenPresentation.rendersTargetCoach(phase: presentation.phase),
                    stage.kind == .work,
                    "\(mode) \(stage.kind) → \(presentation.phase) must follow the measurement phases"
                )
            }
        }

        // A paused phase is a suspended measurement (pause is only reachable
        // from a work stage, #899), never a rest, so the coach stays.
        let protocolValue = preset()
        let holdStage = ForceProtocolRun(preset: protocolValue, startingSide: .left)
            .stages.first { $0.kind == .work }!
        let paused = GuidedForceFullscreenPresentation.stage(
            holdStage,
            preset: protocolValue,
            elapsedSeconds: 2,
            isPaused: true
        )
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertTrue(GuidedForceFullscreenPresentation.rendersTargetCoach(phase: paused.phase))
    }

    /// #998: the chart's growth must not be resolved from the measured stack —
    /// a measurement-driven growth let the chart's own height feed back into
    /// the next measurement and produced a two-state layout cycle on the
    /// iPhone 17 Pro's rest screen (chart 151.7 ↔ 168.7 and the cover never
    /// drawing; probe churned at ~100 renders/second,
    /// `docs/evidence/issue-998/`). The slack is resolved from the static
    /// budget, so two different measurements of the same viewport resolve the
    /// same chart height — while the FIT still consumes the measurement, and
    /// a genuinely roomy viewport still grows the trace to its cap.
    func testChartGrowthResolvesFromTheStaticBudgetSoAMeasurementCannotMoveIt() {
        let first = GuidedForceLayoutMeasurement(
            scrollContentHeight: 697.0,
            chartHeight: 151.7,
            controlsBarHeight: 64.0
        )
        let second = GuidedForceLayoutMeasurement(
            scrollContentHeight: 731.0,
            chartHeight: 168.7,
            controlsBarHeight: 64.0
        )

        // Both measured stacks fit, and the static budget does not: the chart
        // stays at its floor for BOTH — the measurement cannot move it.
        let firstFit = GuidedForceLayout.resolve(width: 402, height: 800, measurement: first)
        let secondFit = GuidedForceLayout.resolve(width: 402, height: 800, measurement: second)
        XCTAssertTrue(firstFit.essentialContentFits)
        XCTAssertTrue(secondFit.essentialContentFits)
        XCTAssertEqual(firstFit.flexibleChartHeight, secondFit.flexibleChartHeight)
        XCTAssertEqual(firstFit.flexibleChartHeight, firstFit.chartMinimumHeight)

        // A viewport the static budget genuinely has room for still grows the
        // trace, and growth still stops at the visual maximum.
        let roomy = GuidedForceLayout.resolve(width: 402, height: 1000, measurement: second)
        XCTAssertTrue(roomy.essentialContentFits)
        XCTAssertEqual(roomy.flexibleChartHeight, roomy.chartMaximumHeight)

        // The measurement still owns the fit decision: a measured stack that
        // overflows keeps the trace at its floor no matter how much static
        // room the viewport appears to have.
        let overflowing = GuidedForceLayoutMeasurement(
            scrollContentHeight: 1100.0,
            chartHeight: 140.0,
            controlsBarHeight: 64.0
        )
        let tight = GuidedForceLayout.resolve(width: 402, height: 1000, measurement: overflowing)
        XCTAssertFalse(tight.essentialContentFits, "the measured overflow must still win the fit")
        XCTAssertEqual(tight.flexibleChartHeight, tight.chartMinimumHeight)
    }
}

@MainActor
final class GuidedForceTerminalSettlementTests: XCTestCase {
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    /// The first caller owns the durable work; a concurrent teardown/Stop
    /// caller receives the same task and cannot run a second preserve or end.
    func testConcurrentTerminalCallersJoinOneSettlement() async {
        let settlement = GuidedForceTerminalSettlement()
        let gate = Gate()
        var operationCalls = 0

        let first = settlement.start {
            operationCalls += 1
            await gate.wait()
        }
        await Task.yield()

        let joined = settlement.start {
            operationCalls += 100
        }
        XCTAssertTrue(settlement.isClaimed)
        XCTAssertEqual(operationCalls, 1)

        gate.open()
        await first.value
        await joined.value
        XCTAssertEqual(operationCalls, 1)
    }
}
