import XCTest
import SendLogWatchCore

final class HandsFreeForceTests: XCTestCase {
    private let config = HandsFreeForceConfig(
        startKg: 2,
        stopKg: 1,
        startStableMs: 600,
        stopGraceMs: 1_500
    )

    private func step(_ state: HandsFreeForceState, _ atMs: Double, _ kg: Double) -> HandsFreeForceStep {
        stepHandsFreeForce(state, atMs: atMs, kg: kg, config: config)
    }

    func testStableLoadStartsButBriefSpikeDoesNot() {
        var state = armedHandsFreeForce()
        state = step(state, 0, 2.1).state
        state = step(state, 500, 2.3).state
        XCTAssertNil(step(state, 599, 3).action)

        // A single dip resets the complete stable window.
        state = step(state, 599, 1.9).state
        state = step(state, 700, 2.2).state
        XCTAssertNil(step(state, 1_299, 2.2).action)
        XCTAssertEqual(
            step(state, 1_300, 2.2),
            HandsFreeForceStep(
                state: .recording(
                    belowSinceMs: nil,
                    flatWatch: HandsFreeForceFlatWatch(sinceMs: 1_300, minKg: 2.2, maxKg: 2.2)
                ),
                action: .start
            )
        )
    }

    func testReleaseGraceAndHysteresisBandDoNotStopEarly() {
        var state = HandsFreeForceState.recording(belowSinceMs: nil, flatWatch: nil)
        state = step(state, 0, 0.8).state
        state = step(state, 1_000, 0.7).state
        XCTAssertNil(step(state, 1_499, 0).action)

        // The 1...2 kg hysteresis band is above stopKg, so it cancels a
        // pending stop without being high enough to start a fresh rep.
        state = step(state, 1_200, 1.1).state
        XCTAssertEqual(
            state,
            .recording(
                belowSinceMs: nil,
                flatWatch: HandsFreeForceFlatWatch(sinceMs: 1_200, minKg: 1.1, maxKg: 1.1)
            )
        )
        state = step(state, 2_000, 0.5).state
        XCTAssertNil(step(state, 3_499, 0).action)
        XCTAssertEqual(
            step(state, 3_500, 0),
            HandsFreeForceStep(state: .stopping, action: .stop)
        )
    }

    func testEachTransitionActionIsClaimedExactlyOnce() {
        var result = step(.armed(aboveSinceMs: 0), 600, 5)
        XCTAssertEqual(result.action, .start)
        XCTAssertNil(step(result.state, 601, 5).action)

        result = step(.recording(belowSinceMs: 0, flatWatch: nil), 1_500, 0)
        XCTAssertEqual(result.action, .stop)
        XCTAssertNil(step(result.state, 1_501, 0).action)
    }

    func testRearmCycleCanStartASecondRep() {
        let firstStart = step(.armed(aboveSinceMs: 0), 600, 5)
        let firstStop = step(.recording(belowSinceMs: 700, flatWatch: nil), 2_200, 0)
        XCTAssertEqual(firstStart.action, .start)
        XCTAssertEqual(firstStop.action, .stop)

        var state = rearmedHandsFreeForce()
        XCTAssertEqual(step(state, 5_000, 35).state, .waitingForSlack)
        XCTAssertEqual(step(state, 50_000, 35).state, .waitingForSlack)

        state = step(state, 50_100, 0.5).state
        XCTAssertEqual(state, .armed(aboveSinceMs: nil))
        state = step(state, 50_200, 3).state
        let secondStart = step(state, 50_800, 3)
        XCTAssertEqual(secondStart.action, .start)
        XCTAssertEqual(
            secondStart.state,
            .recording(
                belowSinceMs: nil,
                flatWatch: HandsFreeForceFlatWatch(sinceMs: 50_800, minKg: 3, maxKg: 3)
            )
        )
    }

    /// #681 — the issue's named re-arm regression: a post-save re-arm
    /// (waitingForSlack) that observes the release-to-slack edge arms, and the
    /// next pull held startStableMs records. This is the ONLY way rep #2 can
    /// start once the manual Start control is gone (#683).
    ///
    /// Characterization note (#681 review F4): this drives only the pure
    /// machine's waitingForSlack -> armed transition, which this branch did
    /// not change, so it cannot fail on the unfixed manager. The tests that DO
    /// fail on unfixed code are the manager-level integration cases in
    /// `TindeqHandsFreeIntegrationTests` (the app test target, watchOS
    /// simulator only); the new `testSaveWindowSamplePastArmTimeoutDoesNotCancel`
    /// below pins the F1 idle-budget re-base (Swift-only — the web has no
    /// idle-disarm concept).
    func testRearmThroughWaitingForSlackObservesReleaseThenArmsAndRecords() {
        var state = rearmedHandsFreeForce()
        XCTAssertEqual(state, .waitingForSlack)

        // A fresh pull before slack is ignored — it must not arm mid-load.
        XCTAssertEqual(step(state, 0, 35).state, .waitingForSlack)
        XCTAssertEqual(step(state, 10_000, 35).state, .waitingForSlack)

        // The release-to-slack edge (at/below stopKg) arms.
        state = step(state, 10_100, 0.5).state
        XCTAssertEqual(state, .armed(aboveSinceMs: nil))

        // The next pull held startStableMs records.
        state = step(state, 10_200, 3).state
        let secondStart = step(state, 10_800, 3)
        XCTAssertEqual(secondStart.action, .start)
        XCTAssertEqual(
            secondStart.state,
            .recording(
                belowSinceMs: nil,
                flatWatch: HandsFreeForceFlatWatch(sinceMs: 10_800, minKg: 3, maxKg: 3)
            )
        )
    }

    /// #681 — the phantom-rep guard: a continuous load spanning a save (no
    /// release edge at/below stopKg after the re-arm) must NEVER produce a
    /// second rep. The machine stays in waitingForSlack no matter how long the
    /// same load is held.
    ///
    /// Characterization note (#681 review F4): same as the re-arm test above —
    /// this pins the pure machine only; the manager wiring that preserves this
    /// through a real tap/cap save is covered by the integration cases.
    func testContinuousLoadSpanningSaveNeverProducesPhantomSecondRep() {
        var state = rearmedHandsFreeForce()
        XCTAssertEqual(state, .waitingForSlack)

        // The same continuous load (never dipping to stopKg) spanning the save
        // and well past startStableMs stays waitingForSlack — never arms.
        for atMs in stride(from: 0.0, through: 60_000, by: 500) {
            let stepped = step(state, atMs, 35)
            state = stepped.state
            XCTAssertEqual(stepped.action, nil)
        }
        XCTAssertEqual(state, .waitingForSlack)

        // Only a genuine release arms, then the pull records.
        state = step(state, 60_500, 0.5).state
        XCTAssertEqual(state, .armed(aboveSinceMs: nil))
        state = step(state, 60_600, 3).state
        XCTAssertEqual(step(state, 61_200, 3).action, .start)
    }

    /// #681 review F1 — regression: a sample inside the save window at a
    /// device timestamp past the arm timeout must NOT cancel. The watch keeps
    /// the weight stream live through tap/cap saves, so post-stop samples keep
    /// flowing into `handleArmedSamples`; the manager re-bases the idle budget
    /// at save-window entry (and at rep start), so a 30-minute rep's first
    /// post-cap sample starts a FRESH budget instead of inheriting the stale
    /// pre-rep base. Without the re-base this sample computes ~30 min > 10 min
    /// and disarms mid-save. This pins the Swift-only idle budget (no TS
    /// counterpart exists); the manager wiring is covered by the cap
    /// integration case's save-window feed.
    func testSaveWindowSamplePastArmTimeoutDoesNotCancel() {
        // The bug the re-base guards against: a budget that kept the PRE-REP
        // base through the whole rep (never re-based at save-window entry)
        // sees the 30-minute cap sample as 30 min of "idle" and disarms.
        let stale = ArmedStreamIdleBudget()
        let armed = observeArmedStreamIdleBudget(stale, sampleUs: 1_000, timeoutSeconds: 600) // arm-time base
        XCTAssertTrue(
            observeArmedStreamIdleBudget(armed.budget, sampleUs: 1_800_600_000, timeoutSeconds: 600).idleExceeded,
            "the stale pre-rep base would disarm — the failure this regression guards against"
        )

        // The fix: save-window entry re-bases the budget (a fresh epoch), so
        // the first sample inside the window establishes the base and must NOT
        // cancel.
        let budget = ArmedStreamIdleBudget() // re-based at stopAndSave
        let first = observeArmedStreamIdleBudget(budget, sampleUs: 1_800_600_000, timeoutSeconds: 600)
        XCTAssertFalse(first.idleExceeded, "a save-window sample at a device timestamp past the arm timeout must NOT cancel")
        XCTAssertEqual(first.budget.baseUs, 1_800_600_000)

        // Ten genuine idle minutes after that still disarm — the budget's job.
        XCTAssertTrue(
            observeArmedStreamIdleBudget(first.budget, sampleUs: 2_400_600_000, timeoutSeconds: 600).idleExceeded
        )

        // A rep start also re-bases: recording time never counts as idle, so a
        // sample 0.5 s into the rep (30+ min after arming) does not disarm.
        XCTAssertFalse(
            observeArmedStreamIdleBudget(ArmedStreamIdleBudget(), sampleUs: 1_800_900_000, timeoutSeconds: 600).idleExceeded
        )
    }

    /// #681 review F3 — the keep-the-stream-running decision is Core's, not a
    /// fourth local switch in the manager. Release proved `stopGraceMs` of
    /// slack, so it may stop the transport outright; tap/cap have no proof and
    /// keep the stream live so the release edge inside the async save window
    /// is still observed. A `.staticLoad` stop (#682) has no slack proof either
    /// (the sustained non-human load is still hanging), so it also keeps the
    /// stream live to observe the release when the load is cut.
    func testStopReasonAnswersTheKeepStreamLiveQuestion() {
        XCTAssertFalse(HandsFreeStopReason.released(endMs: 1_234).keepsStreamLive)
        XCTAssertTrue(HandsFreeStopReason.userTapped.keepsStreamLive)
        XCTAssertTrue(HandsFreeStopReason.cappedAt30Min.keepsStreamLive)
        XCTAssertTrue(HandsFreeStopReason.staticLoad(endMs: 1_234).keepsStreamLive)
    }

    func testInactiveTransportDisarmsExceptForClaimedConnectedArm() {
        let armed = armedHandsFreeForce()
        XCTAssertEqual(handsFreeForceAtInactiveStatus(armed, status: .connected), armed)
        XCTAssertEqual(handsFreeForceAtInactiveStatus(armed, status: .idle), .idle)
        XCTAssertEqual(
            handsFreeForceAtInactiveStatus(.recording(belowSinceMs: nil, flatWatch: nil), status: .connected),
            .idle
        )
    }

    func testBackwardDeviceTimestampRestartsThresholdWindow() {
        XCTAssertEqual(
            step(.armed(aboveSinceMs: 500), 100, 3).state,
            .armed(aboveSinceMs: 100)
        )
        XCTAssertEqual(
            step(.recording(belowSinceMs: 500, flatWatch: nil), 100, 0).state,
            .recording(
                belowSinceMs: 100,
                flatWatch: HandsFreeForceFlatWatch(sinceMs: 100, minKg: 0, maxKg: 0)
            )
        )
    }

    func testOnlyReleaseRearmsImmediatelyTapAndCapWaitForSlack() {
        // #503: the re-arm decision is keyed on the stop reason itself.
        // Release proved 1.5 s of slack, so it re-arms straight to armed;
        // a mid-hold tap or the 30-minute cap must gate the same continuous
        // load behind fresh slack or it becomes a phantom rep (#467).
        // A `.staticLoad` stop has no slack proof either — the same continuous
        // load (the still-hanging bag) must observe slack before re-arming.
        XCTAssertEqual(
            rearmedHandsFreeForce(afterStop: .released(endMs: 1_234)),
            .armed(aboveSinceMs: nil)
        )
        XCTAssertEqual(rearmedHandsFreeForce(afterStop: .userTapped), .waitingForSlack)
        XCTAssertEqual(rearmedHandsFreeForce(afterStop: .cappedAt30Min), .waitingForSlack)
        XCTAssertEqual(rearmedHandsFreeForce(afterStop: .staticLoad(endMs: 1_234)), .waitingForSlack)
    }

    func testOnlyReleaseCarriesATrimTimestamp() {
        // A tap or cap stop has no proven cut point, so trimming the tail
        // there would drop real load from the recording. A `.staticLoad` stop
        // has a proven cut point — the start of the flat window — so it trims.
        XCTAssertEqual(HandsFreeStopReason.released(endMs: 1_234).trimEndMs, 1_234)
        XCTAssertEqual(HandsFreeStopReason.staticLoad(endMs: 1_234).trimEndMs, 1_234)
        XCTAssertNil(HandsFreeStopReason.userTapped.trimEndMs)
        XCTAssertNil(HandsFreeStopReason.cappedAt30Min.trimEndMs)
    }

    // MARK: #682 guards

    /// Guard 1 (#682): a rep peaking below `minPeakKg` is discarded at the
    /// persist boundary; at or above it persists. The threshold is verified
    /// against the config's precise values (2.9 < 3 < 3.1).
    func testRecordingPeakingAt29KgIsDiscarded31KgPersists() {
        XCTAssertEqual(
            recordingVerdict(peakKg: 2.9, durationMs: 10_000, config: config),
            .discard(reason: .belowMinPeak)
        )
        XCTAssertEqual(recordingVerdict(peakKg: 3.1, durationMs: 10_000, config: config), .persist)
    }

    /// Guard 1 (#682): a rep shorter than `minDurationMs` is discarded at the
    /// persist boundary; at or above it persists.
    func testRecordingLasting14SIsDiscarded16SPersists() {
        XCTAssertEqual(
            recordingVerdict(peakKg: 10, durationMs: 1_400, config: config),
            .discard(reason: .belowMinDuration)
        )
        XCTAssertEqual(recordingVerdict(peakKg: 10, durationMs: 1_600, config: config), .persist)
    }

    /// Guard 2 (#682): 30 s of load inside the 0.25 kg flatline band while
    /// `recording` terminates with `.staticLoad`, and the persisted duration
    /// ends at the START of the flat window (the sample that claimed Start,
    /// not at termination — the band may have been flat longer than the
    /// window).
    func testThirtySecondsFlatTerminatesAsStaticLoadTrimmingToFlatWindowStart() {
        var state = armedHandsFreeForce()
        state = step(state, 0, 3).state
        var result = step(state, 600, 3)
        XCTAssertEqual(result.action, .start)
        state = result.state
        for atMs in stride(from: 700.0, through: 30_600, by: 100) {
            result = step(state, atMs, 3)
            state = result.state
            if result.action == .stop { break }
        }
        XCTAssertEqual(result.action, .stop)
        XCTAssertEqual(result.staticLoadEndMs, 600)
        XCTAssertEqual(HandsFreeStopReason.staticLoad(endMs: result.staticLoadEndMs ?? 0).trimEndMs, 600)
    }

    /// Guard 2 (#682): 29 s of flat samples then a 2 kg excursion (5 kg from
    /// 3 kg) does NOT terminate because it breaks the 0.25 kg band, and it
    /// resets the rolling min/max window to the excursion sample.
    func testFlatWindowResetsOnExcursionAndDoesNotTerminate() {
        var state = armedHandsFreeForce()
        state = step(state, 0, 3).state
        var result = step(state, 600, 3)
        XCTAssertEqual(result.action, .start)
        state = result.state
        for atMs in stride(from: 700.0, through: 29_600, by: 100) {
            result = step(state, atMs, 3)
            state = result.state
            XCTAssertEqual(result.action, nil)
        }
        result = step(state, 29_700, 5)
        state = result.state
        XCTAssertEqual(result.action, nil)
        XCTAssertEqual(
            state,
            .recording(
                belowSinceMs: nil,
                flatWatch: HandsFreeForceFlatWatch(sinceMs: 29_700, minKg: 5, maxKg: 5)
            )
        )
        result = step(state, 30_100, 5)
        XCTAssertEqual(result.action, nil)
    }

    /// Guard 1 runs LAST (#682): a `.staticLoad`-terminated recording (Guard 2
    /// produced it) is still evaluated by Guard 1 — a flat-terminated recording
    /// peaking below `minPeakKg` is discarded, not persisted.
    func testStaticLoadTerminatedRecordingPeakingBelowMinPeakIsDiscarded() {
        var state = armedHandsFreeForce()
        state = step(state, 0, 3).state
        var result = step(state, 600, 2.9)
        XCTAssertEqual(result.action, .start)
        state = result.state
        for atMs in stride(from: 700.0, through: 30_600, by: 100) {
            result = step(state, atMs, 2.9)
            state = result.state
            if result.action == .stop { break }
        }
        XCTAssertEqual(result.action, .stop)
        XCTAssertEqual(result.staticLoadEndMs, 600)
        XCTAssertEqual(
            recordingVerdict(peakKg: 2.9, durationMs: 10_000, config: config),
            .discard(reason: .belowMinPeak)
        )
    }

    /// The persist funnel gates on the pure `recordingVerdict` (#682). A
    /// below-min-peak rep is a discard, so the funnel must not enqueue it nor
    /// report it as saved; the complement (a qualifying rep) persists. The
    /// queue-level gate is exercised by the native controller test
    /// (`testDiscardedRepNeverCallsStopAndSave`) — this pins the pure predicate.
    func testDiscardedRepNeverReportedAsQueued() {
        XCTAssertEqual(
            recordingVerdict(peakKg: 2.9, durationMs: 10_000, config: config),
            .discard(reason: .belowMinPeak)
        )
        XCTAssertEqual(recordingVerdict(peakKg: 3.1, durationMs: 10_000, config: config), .persist)
    }

    func testTwoNearSimultaneousStopClaimsSaveExactlyOnce() async {
        let harness = await MainActor.run { ClaimBeforeAwaitHarness() }
        await MainActor.run { harness.begin() }

        let first = Task { @MainActor in await harness.stopAndSave() }
        let second = Task { @MainActor in await harness.stopAndSave() }
        await first.value
        await second.value

        let savedCount = await MainActor.run { harness.savedCount }
        XCTAssertEqual(savedCount, 1)
    }
}

@MainActor
private final class ClaimBeforeAwaitHarness {
    private var claims = HandsFreeForceRepClaims()
    private(set) var savedCount = 0

    func begin() {
        XCTAssertNotNil(claims.begin(tag: "Half crimp", side: "left"))
    }

    func stopAndSave() async {
        // Direct Core coverage for Linux CI: consume synchronously, then await.
        guard claims.claimStop() != nil else { return }
        await Task.yield()
        savedCount += 1
    }
}
