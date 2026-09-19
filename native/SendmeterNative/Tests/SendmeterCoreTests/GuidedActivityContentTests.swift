import XCTest
@testable import SendmeterCore

final class GuidedActivityContentTests: XCTestCase {
    private func preset(
        holdSeconds: Int = 10,
        repetitions: Int = 2,
        sets: Int = 1,
        prepareSeconds: Int = 5,
        alternateSides: Bool = true,
        restBetweenRepetitionsSeconds: Int = 60,
        restBetweenSetsSeconds: Int = 120
    ) -> TindeqPreset {
        TindeqPreset(
            name: "Repeaters",
            holdSeconds: holdSeconds,
            repetitions: repetitions,
            sets: sets,
            restBetweenRepetitionsSeconds: restBetweenRepetitionsSeconds,
            restBetweenSetsSeconds: restBetweenSetsSeconds,
            alternateSides: alternateSides,
            prepareSeconds: prepareSeconds
        )
    }

    private func content(
        preset: TindeqPreset,
        startEpochMs: Double = 1_000_000,
        target: Double? = 42.5
    ) -> GuidedProtocolActivityContent {
        let run = ForceProtocolRun(preset: preset, startingSide: .left)
        let plan = ForceTargetPlan(targets: [
            ForceTargetKey(setNumber: 1, side: .left): ForceTargetBand(
                kilograms: target ?? 0, lowKilograms: 38, highKilograms: 47
            )
        ])
        return GuidedProtocolActivityContent.from(
            run: run,
            preset: preset,
            targetPlan: plan,
            fallbackSide: .left,
            start: Date(timeIntervalSince1970: startEpochMs / 1_000)
        )
    }

    func testBuildsSegmentTimelineFromRun() {
        let content = content(preset: preset())
        // prepare 5s → work L 10s → switch 3s → work R 10s → rest 60s →
        // work L 10s → switch 3s → work R 10s → set rest 120s → ...
        XCTAssertEqual(content.segments.first?.phase, .prepare)
        XCTAssertEqual(content.segments.first?.startS, 0)
        XCTAssertEqual(content.segments.first?.durS, 5)

        let work = content.segments.filter { $0.phase == .work }
        XCTAssertEqual(work.count, 4)
        XCTAssertEqual(work[0].side, .left)
        XCTAssertEqual(work[1].side, .right)
        XCTAssertEqual(work[2].side, .left)
        XCTAssertEqual(work[0].startS, 5)
        XCTAssertEqual(work[0].durS, 10)
        // The second work stage comes after switch (3s) + rest (60s):
        // 5 + 10 + 3 + 10 + 60 = 88.
        XCTAssertEqual(work[2].startS, 88)
        XCTAssertEqual(work[1].startS, 18)
        XCTAssertEqual(content.title, "Repeaters")
        XCTAssertEqual(content.targetKilograms, 42.5)

        var elapsed = 0.0
        for segment in content.segments {
            XCTAssertEqual(segment.startS, elapsed, accuracy: 1e-9)
            elapsed += segment.durS
        }
    }

    func testZeroDurationCompleteStageIsSkipped() {
        let content = content(preset: preset())
        XCTAssertFalse(content.segments.contains { $0.phase == .complete })
        // No zero-duration gaps: every segment is measurable.
        XCTAssertTrue(content.segments.allSatisfy { $0.durS > 0 })
    }

    func testCurrentSegmentAndRemainingMatchTimelineAt() {
        let content = content(preset: preset())
        XCTAssertEqual(content.currentSegment(elapsedSeconds: 0)?.phase, .prepare)
        XCTAssertEqual(content.remainingSeconds(elapsedSeconds: 0) ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(content.currentSegment(elapsedSeconds: 2)?.phase, .prepare)
        XCTAssertEqual(content.remainingSeconds(elapsedSeconds: 2) ?? -1, 3, accuracy: 1e-9)
        // Switch segment boundary.
        XCTAssertEqual(content.currentSegment(elapsedSeconds: 5)?.phase, .work)
        XCTAssertEqual(content.remainingSeconds(elapsedSeconds: 5) ?? -1, 10, accuracy: 1e-9)
        // Past the end → nil.
        XCTAssertNil(content.currentSegment(elapsedSeconds: 1_000_000))
        XCTAssertNil(content.remainingSeconds(elapsedSeconds: 1_000_000))
    }

    func testProgressIsZeroToOneWithinSegment() {
        let content = content(preset: preset())
        XCTAssertEqual(content.progress(elapsedSeconds: 0) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(content.progress(elapsedSeconds: 2.5) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(content.progress(elapsedSeconds: 4.9) ?? -1, 0.98, accuracy: 1e-9)
        // At the exact boundary the NEXT segment is current (0% into it).
        XCTAssertEqual(content.progress(elapsedSeconds: 5) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(content.progress(elapsedSeconds: 14.9) ?? -1, 0.99, accuracy: 1e-9)
        XCTAssertNil(content.progress(elapsedSeconds: 1_000_000))
    }

    func testSnapshotMapsEpochWindowAndLabels() {
        let content = content(preset: preset(), startEpochMs: 1_000_000)
        let snapshot = content.snapshot(atEpochMs: 1_002_000, peakKilograms: 44.1)
        XCTAssertEqual(snapshot?.title, "Repeaters")
        XCTAssertEqual(snapshot?.phaseToken, "prepare")
        XCTAssertEqual(snapshot?.phaseLabel, "Prepare")
        XCTAssertEqual(snapshot?.segmentStartEpochMs, 1_000_000)
        XCTAssertEqual(snapshot?.segmentEndEpochMs, 1_005_000)
        XCTAssertEqual(snapshot?.peakKilograms, 44.1)
        XCTAssertEqual(snapshot?.targetKilograms, 42.5)

        // A work segment carries side + set/rep detail.
        let workSnapshot = content.snapshot(atEpochMs: 1_006_000)
        XCTAssertEqual(workSnapshot?.phaseToken, "work")
        XCTAssertEqual(workSnapshot?.phaseLabel, "Hold")
        XCTAssertEqual(workSnapshot?.detailLabel, "Set 1 · Rep 1 · Left")
        XCTAssertEqual(workSnapshot?.segmentStartEpochMs, 1_005_000)
        XCTAssertEqual(workSnapshot?.segmentEndEpochMs, 1_015_000)

        // Past the schedule: nil (the activity ends, not a stale card).
        XCTAssertNil(content.snapshot(atEpochMs: 2_000_000_000))
    }

    // MARK: #674 review F3 — the LIVE anchor path

    func testRunAnchorReflectsSkipStage() {
        // A Repeaters run reaches its set rest; at 10s in the user taps Skip
        // Stage. The anchor path must re-anchor to the CURRENT stage (the
        // next work hold) instead of replaying the frozen schedule, which
        // would show SET REST counting down from 170s (#674 F3).
        let preset = preset(repetitions: 2, sets: 2, restBetweenSetsSeconds: 180)
        let content = content(preset: preset, startEpochMs: 1_000_000)
        var run = ForceProtocolRun(preset: preset, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        var guardCount = 0
        while run.currentStage.kind != .restBetweenSets {
            run.advance(at: Date(timeIntervalSince1970: 0))
            guardCount += 1
            XCTAssertLessThan(guardCount, 50)
        }
        // advance(at:) set stageStartedAt to the boundary date; re-start the
        // stage so the anchor has a deterministic in-progress stage.
        run.start(at: Date(timeIntervalSince1970: 1_000))
        let anchorBefore = GuidedProtocolActivityContent.RunAnchor(
            run: run,
            at: Date(timeIntervalSince1970: 1_010)
        )
        let before = content.snapshot(runAnchor: anchorBefore, peakKilograms: nil)
        XCTAssertEqual(before.phaseToken, "setRest")
        // Anchored at 1_010_000ms with 170s left → window ends at 1_180_000ms.
        XCTAssertEqual(before.segmentStartEpochMs, 1_010_000)
        XCTAssertEqual(before.segmentEndEpochMs, 1_180_000)

        // Skip Stage: advance to the next (work) stage and re-anchor.
        run.advance(at: Date(timeIntervalSince1970: 1_010))
        XCTAssertEqual(run.currentStage.kind, .work)
        let anchorAfter = GuidedProtocolActivityContent.RunAnchor(
            run: run,
            at: Date(timeIntervalSince1970: 1_010)
        )
        let after = content.snapshot(runAnchor: anchorAfter, peakKilograms: nil)
        XCTAssertEqual(after.phaseToken, "work")
        // The new window starts NOW and runs the full hold duration.
        XCTAssertEqual(after.segmentStartEpochMs, 1_010_000)
        XCTAssertEqual(after.segmentEndEpochMs, 1_020_000)
    }

    func testRunAnchorProgressTracksElapsedWithinStage() {
        let preset = preset(holdSeconds: 10)
        let content = content(preset: preset, startEpochMs: 1_000_000)
        var run = ForceProtocolRun(preset: preset, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        // Midway through the first (prepare, 5s) stage — the countdown window
        // re-anchors to NOW with the remaining span, so the timer renders the
        // right countdown natively.
        let anchor = GuidedProtocolActivityContent.RunAnchor(
            run: run,
            at: Date(timeIntervalSince1970: 2.5)
        )
        let snapshot = content.snapshot(runAnchor: anchor, peakKilograms: 40)
        XCTAssertEqual(snapshot.phaseToken, "prepare")
        XCTAssertEqual(snapshot.segmentStartEpochMs, 2_500)
        XCTAssertEqual(snapshot.segmentEndEpochMs, 5_000)
    }

    func testPausedRunAnchorDoesNotPublishFutureRunningWindow() {
        let preset = preset(holdSeconds: 10)
        let content = content(preset: preset, startEpochMs: 1_000_000)
        var run = ForceProtocolRun(preset: preset, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        run.pause(at: Date(timeIntervalSince1970: 2))

        let snapshot = content.snapshot(
            runAnchor: GuidedProtocolActivityContent.RunAnchor(
                run: run,
                at: Date(timeIntervalSince1970: 100)
            )
        )

        XCTAssertTrue(snapshot.isPaused)
        XCTAssertEqual(snapshot.segmentStartEpochMs, 100_000)
        XCTAssertEqual(snapshot.segmentEndEpochMs, 100_000)
    }

    func testWaitingHandsFreeOverrideFreezesLockScreenUntilMeasurement() {
        let preset = preset(holdSeconds: 10)
        let content = content(preset: preset, startEpochMs: 1_000_000)
        var run = ForceProtocolRun(preset: preset, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        run.advance(at: Date(timeIntervalSince1970: 5))

        let snapshot = content.snapshot(
            runAnchor: GuidedProtocolActivityContent.RunAnchor(
                run: run,
                at: Date(timeIntervalSince1970: 100),
                isPaused: true
            )
        )

        XCTAssertTrue(snapshot.isPaused)
        XCTAssertEqual(snapshot.segmentStartEpochMs, 100_000)
        XCTAssertEqual(snapshot.segmentEndEpochMs, 100_000)
        XCTAssertEqual(snapshot.detailLabel, "Set 1 · Rep 1 · Left")
    }

    // MARK: #939 — a rest card shows the hand-off, not the set that just ended

    func testRestSnapshotDetailMatchesTheFullscreenRestLine() throws {
        let preset = preset(repetitions: 3, sets: 2, restBetweenRepetitionsSeconds: 60)
        let content = content(preset: preset, startEpochMs: 1_000_000)
        var run = ForceProtocolRun(preset: preset, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        let restIndex = try XCTUnwrap(run.stages.firstIndex { $0.kind == .restBetweenRepetitions })
        while run.stageIndex < restIndex {
            run.advance(at: Date(timeIntervalSince1970: 0))
        }
        XCTAssertEqual(run.currentStage.kind, .restBetweenRepetitions)

        let at = Date(timeIntervalSince1970: 1_005)
        let snapshot = content.snapshot(
            runAnchor: GuidedProtocolActivityContent.RunAnchor(run: run, at: at)
        )
        let fullscreen = GuidedForceFullscreenPresentation.stage(
            run.currentStage,
            preset: preset,
            elapsedSeconds: 5
        )

        XCTAssertEqual(snapshot.phaseToken, "rest")
        XCTAssertEqual(snapshot.detailLabel, fullscreen.detail)
        // The hand-off, never the set/rep that just ended (#939).
        XCTAssertEqual(snapshot.detailLabel, "Next: Rep 2/3 · 10s hold · Left")
    }

    // MARK: #674 review N1 — the mirror derives from the LIVE run, never a copy

    func testMirrorTracksRunAcrossStageTransitions() {
        // The regression this guards: the previous manager stored a
        // `ForceProtocolRun` struct copy at start() and never updated it, so
        // every refresh pushed the stage-0 snapshot for the whole protocol.
        // `GuidedActivityMirror` retains NO run — each snapshot reads the run
        // handed in at call time, so advancing the caller's run advances the
        // card.
        //
        // Stages (alternating, 1 rep): prepare 5s → work L 10s → switch 3s →
        // work R 10s → complete 0s.
        let preset = preset(holdSeconds: 10, repetitions: 1, sets: 1, prepareSeconds: 5, alternateSides: true)
        let run = ForceProtocolRun(preset: preset, startingSide: .left)
        let mirror = GuidedActivityMirror(
            content: GuidedProtocolActivityContent.from(
                run: run,
                preset: preset,
                targetPlan: ForceTargetPlan.empty,
                fallbackSide: .left,
                start: Date(timeIntervalSince1970: 0)
            )
        )
        var liveRun = run
        liveRun.start(at: Date(timeIntervalSince1970: 0))

        // Stage 0: prepare.
        XCTAssertEqual(mirror.snapshot(run: liveRun, at: Date(timeIntervalSince1970: 1)).phaseToken, "prepare")
        XCTAssertEqual(
            mirror.snapshot(run: liveRun, at: Date(timeIntervalSince1970: 1)).segmentEndEpochMs,
            1_000 + (4 * 1_000)
        )

        // Advance the caller's run past prepare into the first hold.
        liveRun.advance(at: Date(timeIntervalSince1970: 5))
        let workSnapshot = mirror.snapshot(run: liveRun, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(workSnapshot.phaseToken, "work")
        XCTAssertEqual(workSnapshot.detailLabel, "Set 1 · Rep 1 · Left")
        XCTAssertEqual(workSnapshot.segmentStartEpochMs, 5_000)
        XCTAssertEqual(workSnapshot.segmentEndEpochMs, 15_000)

        // Skip Stage (F3): advance past the switch into the right-side hold;
        // the snapshot re-anchors to the CURRENT stage immediately.
        liveRun.advance(at: Date(timeIntervalSince1970: 5))   // switch
        liveRun.advance(at: Date(timeIntervalSince1970: 5))   // work R
        let skipped = mirror.snapshot(run: liveRun, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(skipped.phaseToken, "work")
        XCTAssertEqual(skipped.detailLabel, "Set 1 · Rep 1 · Right")
        XCTAssertEqual(skipped.segmentStartEpochMs, 5_000)
        XCTAssertEqual(skipped.segmentEndEpochMs, 15_000)

        // The terminal complete stage (F5) is reachable through the mirror too.
        liveRun.advance(at: Date(timeIntervalSince1970: 5))
        let done = mirror.snapshot(run: liveRun, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(done.phaseToken, "complete")
        XCTAssertEqual(done.segmentEndEpochMs, done.segmentStartEpochMs)
    }

    func testMirrorBanksPeakAcrossSnapshots() {
        let preset = preset(repetitions: 1, sets: 1)
        let run = ForceProtocolRun(preset: preset, startingSide: .left)
        var mirror = GuidedActivityMirror(
            content: GuidedProtocolActivityContent.from(
                run: run,
                preset: preset,
                targetPlan: ForceTargetPlan.empty,
                fallbackSide: .left,
                start: Date(timeIntervalSince1970: 0)
            )
        )
        var liveRun = run
        liveRun.start(at: Date(timeIntervalSince1970: 0))
        XCTAssertNil(mirror.snapshot(run: liveRun).peakKilograms)
        mirror.bankPeak(51.2)
        XCTAssertEqual(mirror.snapshot(run: liveRun).peakKilograms, 51.2)
    }

    // MARK: #674 review F5 — the terminal complete stage

    func testRunAnchorEmitsTerminalComplete() {
        let preset = preset(repetitions: 1, sets: 1, prepareSeconds: 0, restBetweenRepetitionsSeconds: 0)
        let content = content(preset: preset, startEpochMs: 1_000_000)
        var run = ForceProtocolRun(preset: preset, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        var guardCount = 0
        while !run.isComplete {
            run.advance(at: Date(timeIntervalSince1970: 10))
            guardCount += 1
            XCTAssertLessThan(guardCount, 50)
        }
        let anchor = GuidedProtocolActivityContent.RunAnchor(run: run, at: Date(timeIntervalSince1970: 10))
        let snapshot = content.snapshot(runAnchor: anchor, peakKilograms: nil)
        XCTAssertEqual(snapshot.phaseToken, "complete")
        // The complete stage is zero-length: empty countdown window.
        XCTAssertEqual(snapshot.segmentEndEpochMs, snapshot.segmentStartEpochMs)
    }

    func testAnchorSnapshotCarriesOnlyWireFields() {
        // #674 review N2: the ContentState carries no `progress` field — the
        // bar animates natively from the window (`ProgressView(timerInterval:)`),
        // so a per-push fraction would be dead payload that never moves. The
        // snapshot must still expose everything the widget renders.
        let preset = preset(repetitions: 1, sets: 1, prepareSeconds: 0, restBetweenRepetitionsSeconds: 0)
        let content = content(preset: preset, startEpochMs: 0)
        var run = ForceProtocolRun(preset: preset, startingSide: .left)
        run.start(at: Date(timeIntervalSince1970: 0))
        while !run.isComplete {
            run.advance(at: Date(timeIntervalSince1970: 10))
        }
        let snapshot = content.snapshot(runAnchor: .init(run: run, at: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(snapshot.phaseToken, "complete")
        XCTAssertEqual(snapshot.segmentEndEpochMs, snapshot.segmentStartEpochMs)
    }

    func testFallbackSideUsedForUnspecifiedStages() {
        let run = ForceProtocolRun(preset: preset(alternateSides: false), startingSide: .left)
        let plan = ForceTargetPlan.empty
        let content = GuidedProtocolActivityContent.from(
            run: run,
            preset: preset(alternateSides: false),
            targetPlan: plan,
            fallbackSide: .right,
            start: Date(timeIntervalSince1970: 1_000)
        )
        let work = content.segments.filter { $0.phase == .work }
        XCTAssertEqual(work.first?.side, .right)
        XCTAssertNil(content.targetKilograms)
    }

    func testCodableWireShapeMatchesWebActivitySegment() throws {
        let segment = GuidedActivitySegment(
            phase: .work,
            side: .left,
            rep: 2,
            set: 1,
            startS: 5,
            durS: 10
        )
        let data = try JSONEncoder().encode(segment)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The web's ActivitySegment keys (p/s/rep/set/startS/durS) — a future
        // widget shares the same model, so the wire shape must not drift.
        XCTAssertEqual(json["p"] as? String, "work")
        XCTAssertEqual(json["s"] as? String, "left")
        XCTAssertEqual(json["rep"] as? Int, 2)
        XCTAssertEqual(json["set"] as? Int, 1)
        XCTAssertEqual(json["startS"] as? Double, 5)
        XCTAssertEqual(json["durS"] as? Double, 10)
    }
}
