import XCTest
@testable import SendmeterCore

/// Native mirror of the web's `routineRun.test.ts` semantics (#633): the
/// ≥60s logging gate, partial-minute clamping, and the resume/stale decision
/// must classify a run exactly as the web would. Numbers are copied from the
/// web tests where the scenario matches so a divergence is a visible diff.
final class RoutineGateTests: XCTestCase {
    private static let suiteName = "RoutineGateTests-\(UUID().uuidString)"

    private let p1 = UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!
    /// startedMs = 1_000_000 matches the web tests' base record.
    private func base(
        presetID: UUID? = nil,
        startedMs: Int64 = 1_000_000,
        skippedS: Int = 0,
        pausedAtMs: Int64? = nil,
        pausedTotalMs: Int64 = 0,
        lastSeenMs: Int64? = nil
    ) -> PersistedRoutineRun {
        PersistedRoutineRun(
            presetID: presetID ?? p1,
            startedMs: startedMs,
            skippedS: skippedS,
            pausedAtMs: pausedAtMs,
            pausedTotalMs: pausedTotalMs,
            lastSeenMs: lastSeenMs ?? startedMs
        )
    }

    // MARK: elapsedS / realElapsedS

    func testElapsedSCountsWallClockSecondsSinceStart() {
        XCTAssertEqual(RoutineGate.elapsedS(base(), nowMs: 1_030_000), 30)
    }

    func testElapsedSAddsSkippedSeconds() {
        XCTAssertEqual(RoutineGate.elapsedS(base(skippedS: 12), nowMs: 1_030_000), 42)
    }

    func testElapsedSSubtractsAccumulatedPauseTime() {
        // 30s wall-clock, 8s of it spent paused → 22s of routine time.
        XCTAssertEqual(RoutineGate.elapsedS(base(pausedTotalMs: 8_000), nowMs: 1_030_000), 22)
    }

    func testElapsedSFreezesWhilePaused() {
        // now keeps advancing but elapsed stays at the pause instant.
        XCTAssertEqual(
            RoutineGate.elapsedS(base(pausedAtMs: 1_020_000), nowMs: 1_099_000),
            20
        )
    }

    func testRealElapsedSExcludesSkippedSeconds() {
        let run = base(skippedS: 500)
        XCTAssertEqual(RoutineGate.elapsedS(run, nowMs: 1_030_000), 530) // position
        XCTAssertEqual(RoutineGate.realElapsedS(run, nowMs: 1_030_000), 30) // duration to log
    }

    func testRealElapsedSFreezesWhilePausedAndSubtractsPauseTime() {
        let run = base(skippedS: 100, pausedAtMs: 1_020_000, pausedTotalMs: 5_000)
        XCTAssertEqual(RoutineGate.realElapsedS(run, nowMs: 1_999_000), 15)
    }

    // MARK: shouldLog

    func testShouldLogIsFalseUnderAMinute() {
        XCTAssertFalse(RoutineGate.shouldLog(0))
        XCTAssertFalse(RoutineGate.shouldLog(59.9))
    }

    func testShouldLogIsTrueAtAMinuteOrMore() {
        XCTAssertTrue(RoutineGate.shouldLog(60))
        XCTAssertTrue(RoutineGate.shouldLog(600))
    }

    // MARK: partialMinutes

    func testPartialMinutesRoundsToWholeMinutesWithFloorOfOne() {
        XCTAssertEqual(RoutineGate.partialMinutes(60), 1)
        XCTAssertEqual(RoutineGate.partialMinutes(89), 1)
        XCTAssertEqual(RoutineGate.partialMinutes(90), 2)
        XCTAssertEqual(RoutineGate.partialMinutes(150), 3)
    }

    func testPartialMinutesClampsToTheDBDurationRangeNeverPastIt() {
        XCTAssertEqual(RoutineGate.partialMinutes(601 * 60), 600)
        XCTAssertEqual(RoutineGate.partialMinutes(24 * 60 * 60), 600) // a full day
        XCTAssertEqual(RoutineGate.partialMinutes(0), 1)
        XCTAssertEqual(RoutineGate.partialMinutes(-30), 1)
    }

    /// The web's #483 F6 guard: NaN slips through min/max unclamped, so it
    /// must be handled before the clamp — the one input that must still land
    /// inside 1..600 no matter what a caller passes in.
    func testPartialMinutesNeverReturnsOutOfRangeForNonFiniteInput() {
        XCTAssertEqual(RoutineGate.partialMinutes(Double.nan), 1)
        XCTAssertEqual(RoutineGate.partialMinutes(Double.infinity), 600)
        XCTAssertEqual(RoutineGate.partialMinutes(-Double.infinity), 1)
    }

    // MARK: loggedMinutes

    /// The web's #483 core arithmetic: a 9-minute preset abandoned for 2
    /// hours must log 9 minutes, never the 120 raw wall clock would give.
    func testLoggedMinutesCapsA2HourAbandoned9MinuteRoutineAt9() {
        let elapsed = 2.0 * 60 * 60
        XCTAssertEqual(RoutineGate.loggedMinutes(elapsed, totalSeconds: 9 * 60), 9)
    }

    func testLoggedMinutesStillClampsTo600ForALegitimatelyLongerTotal() {
        XCTAssertEqual(RoutineGate.loggedMinutes(1000 * 60, totalSeconds: 1000 * 60), 600)
    }

    func testLoggedMinutesDoesNotInflateANormalCompletion() {
        XCTAssertEqual(RoutineGate.loggedMinutes(9 * 60, totalSeconds: 9 * 60), 9)
    }

    // MARK: isAbandoned

    func testIsAbandonedWhileGenuinelyInProgress() {
        XCTAssertFalse(RoutineGate.isAbandoned(base(), totalSeconds: 9 * 60, nowMs: 1_120_000))
    }

    func testIsAbandonedOnceWallClockReachesTheTotal() {
        XCTAssertTrue(RoutineGate.isAbandoned(base(), totalSeconds: 9 * 60, nowMs: 1_540_000))
    }

    func testIsAbandonedWhenReopenedHoursAfterTheTotal() {
        XCTAssertTrue(RoutineGate.isAbandoned(base(), totalSeconds: 9 * 60, nowMs: 7_300_000))
    }

    func testPausedRunIsNeverAbandonedByStaleWallClock() {
        // Paused at 60s in, read back 2h later — frozen elapsed still governs.
        XCTAssertFalse(RoutineGate.isAbandoned(
            base(pausedAtMs: 1_060_000),
            totalSeconds: 9 * 60,
            nowMs: 7_300_000
        ))
    }

    // MARK: classifyElapsed

    func testClassifyElapsedCountsAtOrWithinMarginOfTotalAsCompleted() {
        XCTAssertEqual(
            RoutineGate.classifyElapsed(seenElapsed: 540, totalSeconds: 9 * 60),
            .completed(durationMin: 9)
        )
        XCTAssertEqual(
            RoutineGate.classifyElapsed(seenElapsed: 533, totalSeconds: 9 * 60),
            .completed(durationMin: 9)
        )
    }

    func testClassifyElapsedCountsShorterSubstantialElapsedAsPartial() {
        XCTAssertEqual(
            RoutineGate.classifyElapsed(seenElapsed: 120, totalSeconds: 9 * 60),
            .partial(durationMin: 2)
        )
    }

    func testClassifyElapsedDiscardsAnythingUnderTheShouldLogBar() {
        XCTAssertEqual(RoutineGate.classifyElapsed(seenElapsed: 30, totalSeconds: 9 * 60), .discarded)
        XCTAssertEqual(RoutineGate.classifyElapsed(seenElapsed: 0, totalSeconds: 9 * 60), .discarded)
    }

    // MARK: completionOutcome (#633 gate)

    func testCompletionOutcomeUsesTheCompletedPathBelowTheInterruptionBar() {
        XCTAssertEqual(RoutineGate.completionOutcome(elapsedSeconds: 0, totalSeconds: 540), .logged(durationMin: 1))
        XCTAssertEqual(RoutineGate.completionOutcome(elapsedSeconds: 59.9, totalSeconds: 540), .logged(durationMin: 1))
    }

    /// The issue's core case: an explicitly completed sub-minute routine gets
    /// the web's one-minute floor, even though an interrupted run does not.
    func testCompletionOutcomeLogsACompletedSubMinuteRoutine() {
        XCTAssertEqual(RoutineGate.completionOutcome(elapsedSeconds: 45, totalSeconds: 45), .logged(durationMin: 1))
    }

    func testCompletionOutcomeLogsRealElapsedMinutesAtTheBar() {
        XCTAssertEqual(RoutineGate.completionOutcome(elapsedSeconds: 60, totalSeconds: 540), .logged(durationMin: 1))
        XCTAssertEqual(RoutineGate.completionOutcome(elapsedSeconds: 120, totalSeconds: 540), .logged(durationMin: 2))
        XCTAssertEqual(RoutineGate.completionOutcome(elapsedSeconds: 300, totalSeconds: 540), .logged(durationMin: 5))
    }

    /// A completed skip-through run still uses real elapsed, not skipped
    /// timeline credit; 45 real seconds therefore gets the one-minute floor.
    func testCompletionOutcomeLogsACompletedSkipThroughSubMinuteRun() {
        XCTAssertEqual(RoutineGate.completionOutcome(elapsedSeconds: 45, totalSeconds: 600), .logged(durationMin: 1))
    }

    func testInterruptionOutcomeDiscardsAnEarlyCloseUnderAMinute() {
        XCTAssertEqual(RoutineGate.interruptionOutcome(elapsedSeconds: 45), .discarded)
    }

    func testInterruptionOutcomeLogsAnEarlyCloseAtAMinute() {
        XCTAssertEqual(RoutineGate.interruptionOutcome(elapsedSeconds: 60), .logged(durationMin: 1))
    }

    func testInterruptionOutcomeUsesRealElapsedInsteadOfSkippedCredit() {
        let run = base(skippedS: 400)
        let realElapsed = RoutineGate.realElapsedS(run, nowMs: 1_030_000)
        XCTAssertEqual(RoutineGate.interruptionOutcome(elapsedSeconds: realElapsed), .discarded)
    }

    /// A 20-minute real run of a 9-minute routine caps at the staged total
    /// (9), never the raw 20; a day-long run still hits the DB cap of 600.
    func testCompletionOutcomeClampsAtTheStagedTotalAndTheDBCap() {
        XCTAssertEqual(
            RoutineGate.completionOutcome(elapsedSeconds: 1_200, totalSeconds: 9 * 60),
            .logged(durationMin: 9)
        )
        XCTAssertEqual(
            RoutineGate.completionOutcome(elapsedSeconds: 60_000, totalSeconds: 60_000),
            .logged(durationMin: 600)
        )
    }

    // MARK: stable-ID Undo decision

    func testUndoDecisionUsesTheReceiptSessionIDNotAnotherConcurrentSession() {
        let account = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let created = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let later = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let receipt = SessionLogReceipt(sessionID: created, accountUserID: account)

        XCTAssertEqual(
            RoutineGate.undoDecision(receipt: receipt, currentUserID: account),
            .delete(sessionID: created, accountUserID: account)
        )
        XCTAssertNotEqual(
            RoutineGate.undoDecision(receipt: receipt, currentUserID: account),
            .delete(sessionID: later, accountUserID: account)
        )
    }

    func testUndoDecisionIgnoresMissingReceiptOrDifferentAccount() {
        let account = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherAccount = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let receipt = SessionLogReceipt(
            sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            accountUserID: account
        )

        XCTAssertEqual(RoutineGate.undoDecision(receipt: nil, currentUserID: account), .ignore)
        XCTAssertEqual(RoutineGate.undoDecision(receipt: receipt, currentUserID: otherAccount), .ignore)
        XCTAssertEqual(RoutineGate.undoDecision(receipt: receipt, currentUserID: nil), .ignore)
    }

    // MARK: resolveRoutineResume (web #483 F1/F4/F5/N3 semantics)

    func testResolveWithNoPersistedRunIsNone() {
        XCTAssertEqual(RoutineGate.resolveRoutineResume(run: nil, totalSeconds: 9 * 60, nowMs: 1_000_000), .none)
    }

    func testResolveGenuinelyInProgressRunResumes() {
        // 2 minutes into a 9-minute preset, heartbeat 1s old.
        let run = base(lastSeenMs: 1_119_000)
        XCTAssertEqual(RoutineGate.resolveRoutineResume(run: run, totalSeconds: 9 * 60, nowMs: 1_120_000), .resume)
    }

    func testResolvePausedRunResumesEvenReadBackHoursLater() {
        let paused = base(pausedAtMs: 1_060_000)
        XCTAssertEqual(
            RoutineGate.resolveRoutineResume(run: paused, totalSeconds: 9 * 60, nowMs: 19_000_000),
            .resume
        )
    }

    /// Web F1: a genuinely COMPLETED routine, killed right at the end, must
    /// log as completed — not be discarded — via what the heartbeat
    /// confirmed (reclaimed ~537s in, reopened 30s later).
    func testResolvePresentThroughTheEndReopenedShortlyAfterLogsCompleted() {
        let run = base(lastSeenMs: 1_537_000)
        let nowMs: Int64 = 1_575_000
        XCTAssertTrue(RoutineGate.isAbandoned(run, totalSeconds: 9 * 60, nowMs: nowMs))
        XCTAssertEqual(
            RoutineGate.resolveRoutineResume(run: run, totalSeconds: 9 * 60, nowMs: nowMs),
            .logged(.completed(durationMin: 9))
        )
    }

    /// Web F5: a run abandoned partway through, reopened just under the
    /// total, must NOT resume (which would log the full nominal duration one
    /// tick later) — it logs the confirmed partial instead.
    func testResolveAbandonedPartwayReopenedJustUnderTotalLogsPartialNotResume() {
        let run = base(lastSeenMs: 1_120_000)
        let nowMs: Int64 = 1_539_000
        XCTAssertFalse(RoutineGate.isAbandoned(run, totalSeconds: 9 * 60, nowMs: nowMs))
        XCTAssertEqual(
            RoutineGate.resolveRoutineResume(run: run, totalSeconds: 9 * 60, nowMs: nowMs),
            .logged(.partial(durationMin: 2))
        )
    }

    func testResolveBarelyTouchedStaleRunIsDiscarded() {
        let run = base(lastSeenMs: 1_005_000)
        XCTAssertEqual(
            RoutineGate.resolveRoutineResume(run: run, totalSeconds: 9 * 60, nowMs: 7_300_000),
            .logged(.discarded)
        )
    }

    func testResolveAbandonedReopenedHoursLaterLogsTheConfirmedPartial() {
        let run = base(lastSeenMs: 1_120_000)
        XCTAssertEqual(
            RoutineGate.resolveRoutineResume(run: run, totalSeconds: 9 * 60, nowMs: 7_300_000),
            .logged(.partial(durationMin: 2))
        )
    }

    /// Web F4: skipped credit must not inflate what a stale run logs — 30s
    /// really spent (with 400s skipped) is discarded, not logged as 7 min.
    func testResolveSkippedCreditIsNotCreditedWhenLoggingAStaleRun() {
        let run = base(skippedS: 400, lastSeenMs: 1_030_000)
        XCTAssertEqual(
            RoutineGate.resolveRoutineResume(run: run, totalSeconds: 9 * 60, nowMs: 7_300_000),
            .logged(.discarded)
        )
    }

    /// Web N3: a record with no heartbeat history (lastSeen defaulted to
    /// startedMs) must not fabricate a completed session hours later.
    func testResolveLegacyRecordWithNoHeartbeatDoesNotFabricateCompletion() {
        let legacy = base(lastSeenMs: 1_000_000)
        XCTAssertEqual(
            RoutineGate.resolveRoutineResume(run: legacy, totalSeconds: 9 * 60, nowMs: 7_300_000),
            .logged(.discarded)
        )
    }

    // MARK: Pause/skip/heartbeat helpers

    func testPauseResumeHelpersAccumulatePausedTime() {
        let paused = base().paused(atMs: 1_020_000)
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.pausedAtMs, 1_020_000)
        let resumed = paused.resumed(atMs: 1_030_000)
        XCTAssertFalse(resumed.isPaused)
        XCTAssertNil(resumed.pausedAtMs)
        XCTAssertEqual(resumed.pausedTotalMs, 10_000)
    }

    func testPauseResumeHelpersAreNoOpsWhenCalledOutOfOrder() {
        XCTAssertEqual(base().resumed(atMs: 1_020_000), base())
        let paused = base().paused(atMs: 1_020_000)
        XCTAssertEqual(paused.paused(atMs: 1_030_000), paused)
    }

    func testSkipAndHeartbeatHelpers() {
        XCTAssertEqual(base().skipped(15, atMs: 1_030_000).skippedS, 15)
        XCTAssertEqual(base().skipped(-5, atMs: 1_030_000).skippedS, 0)
        XCTAssertEqual(base().heartbeat(atMs: 1_030_000).lastSeenMs, 1_030_000)
    }

    // MARK: Persistence shape + store

    /// The record encodes to the web's exact key names, so the two
    /// implementations' records are byte-comparable.
    func testPersistedRunEncodesToTheWebShape() throws {
        let run = base(skippedS: 12, pausedAtMs: 1_020_000, pausedTotalMs: 5_000, lastSeenMs: 1_015_000)
        let data = try JSONEncoder().encode(run)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["presetId"] as? String, p1.uuidString)
        XCTAssertEqual(object["startedMs"] as? Int64, 1_000_000)
        XCTAssertEqual(object["skippedS"] as? Int, 12)
        XCTAssertEqual(object["pausedAtMs"] as? Int64, 1_020_000)
        XCTAssertEqual(object["pausedTotalMs"] as? Int64, 5_000)
        XCTAssertEqual(object["lastSeenMs"] as? Int64, 1_015_000)
    }

    func testPersistedRunDecodesFromTheWebShape() throws {
        let json = Data(#"{"presetId":"12345678-1234-5678-9ABC-DEF012345678","startedMs":1000000,"skippedS":12,"pausedAtMs":1020000,"pausedTotalMs":5000,"lastSeenMs":1015000}"#.utf8)
        let run = try JSONDecoder().decode(PersistedRoutineRun.self, from: json)
        XCTAssertEqual(run, base(skippedS: 12, pausedAtMs: 1_020_000, pausedTotalMs: 5_000, lastSeenMs: 1_015_000))
    }

    func testStoreRoundTripsAndClears() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let store = RoutineRunStore(defaults: defaults)
        XCTAssertNil(store.load())
        let run = base(skippedS: 12, pausedAtMs: 1_020_000, pausedTotalMs: 5_000, lastSeenMs: 1_015_000)
        store.save(run)
        XCTAssertEqual(store.load(), run)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoreIgnoresMalformedDataRatherThanThrowing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        defaults.set(Data("{not a run".utf8), forKey: "sendmeter.native.routine-run")
        XCTAssertNil(RoutineRunStore(defaults: defaults).load())
    }

    // MARK: In-memory restore seeding (RoutineRun restoring init)

    private func twoStepPreset() -> RoutinePreset {
        RoutinePreset(name: "Warmup", steps: [
            RoutineStep(label: "Pulse raiser", seconds: 30),
            RoutineStep(label: "Hangs", seconds: 60)
        ])
    }

    private func dateAt(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1_000)
    }

    func testRestoredRunSeedsTheCurrentStageClock() {
        // 65s into a 90s routine → second stage ("Hangs"), 35s in.
        let t0 = dateAt(ms: 1_000_000)
        let now = t0.addingTimeInterval(65)
        let run = RoutineRun(
            preset: twoStepPreset(),
            restoring: base(lastSeenMs: 1_000_000),
            at: now
        )
        XCTAssertEqual(run.currentStage.label, "Hangs")
        XCTAssertEqual(run.elapsedSeconds(at: now), 35)
        XCTAssertEqual(run.remainingSeconds(at: now), 25)
        XCTAssertFalse(run.isPaused)
    }

    func testRestoredPausedRunStaysFrozenAtItsElapsed() {
        let t0 = dateAt(ms: 1_000_000)
        let now = t0.addingTimeInterval(5 * 60 * 60)
        let run = RoutineRun(
            preset: twoStepPreset(),
            restoring: base(pausedAtMs: 1_065_000, lastSeenMs: 1_065_000),
            at: now
        )
        XCTAssertTrue(run.isPaused)
        XCTAssertEqual(run.currentStage.label, "Hangs")
        XCTAssertEqual(run.elapsedSeconds(at: now), 35)
        XCTAssertEqual(run.remainingSeconds(at: now), 25)
    }

    func testRestoredRunPositionsBySkippedCredit() {
        // 65s wall clock + 10s skipped → 75s position, 45s into the second
        // stage.
        let t0 = dateAt(ms: 1_000_000)
        let now = t0.addingTimeInterval(65)
        let run = RoutineRun(
            preset: twoStepPreset(),
            restoring: base(skippedS: 10, lastSeenMs: 1_000_000),
            at: now
        )
        XCTAssertEqual(run.currentStage.label, "Hangs")
        XCTAssertEqual(run.remainingSeconds(at: now), 15)
    }

    func testRestoredRunPastTheTotalLandsOnComplete() {
        let t0 = dateAt(ms: 1_000_000)
        let now = t0.addingTimeInterval(100)
        let run = RoutineRun(
            preset: twoStepPreset(),
            restoring: base(lastSeenMs: 1_000_000),
            at: now
        )
        XCTAssertTrue(run.isComplete)
    }

    func testRestoredRunAtAStageBoundaryStartsTheNextStageFresh() {
        let t0 = dateAt(ms: 1_000_000)
        let now = t0.addingTimeInterval(30)
        let run = RoutineRun(
            preset: twoStepPreset(),
            restoring: base(lastSeenMs: 1_000_000),
            at: now
        )
        XCTAssertEqual(run.currentStage.label, "Hangs")
        XCTAssertEqual(run.elapsedSeconds(at: now), 0)
        XCTAssertEqual(run.remainingSeconds(at: now), 60)
    }

    func testRestoredNilIsAFreshRun() {
        let run = RoutineRun(preset: twoStepPreset(), restoring: nil)
        let fresh = RoutineRun(preset: twoStepPreset())
        XCTAssertEqual(run.currentIndex, fresh.currentIndex)
        XCTAssertEqual(run.isPaused, fresh.isPaused)
        XCTAssertNil(run.stageStartedAt)
        XCTAssertEqual(run.pausedElapsedSeconds, fresh.pausedElapsedSeconds)
    }
}
