import XCTest
@testable import SendmeterCore

final class GuidedActivityContentTests: XCTestCase {
    private func preset(
        holdSeconds: Int = 10,
        repetitions: Int = 2,
        sets: Int = 1,
        prepareSeconds: Int = 5,
        alternateSides: Bool = true,
        restBetweenRepetitionsSeconds: Int = 60
    ) -> TindeqPreset {
        TindeqPreset(
            name: "Repeaters",
            holdSeconds: holdSeconds,
            repetitions: repetitions,
            sets: sets,
            restBetweenRepetitionsSeconds: restBetweenRepetitionsSeconds,
            restBetweenSetsSeconds: 120,
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
        XCTAssertEqual(snapshot?.phaseLabel, "Prepare")
        XCTAssertEqual(snapshot?.segmentStartEpochMs, 1_000_000)
        XCTAssertEqual(snapshot?.segmentEndEpochMs, 1_005_000)
        XCTAssertEqual(snapshot?.progress ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(snapshot?.peakKilograms, 44.1)
        XCTAssertEqual(snapshot?.targetKilograms, 42.5)

        // A work segment carries side + set/rep detail.
        let workSnapshot = content.snapshot(atEpochMs: 1_006_000)
        XCTAssertEqual(workSnapshot?.phaseLabel, "Hold")
        XCTAssertEqual(workSnapshot?.detailLabel, "Set 1 · Rep 1 · Left")
        XCTAssertEqual(workSnapshot?.segmentStartEpochMs, 1_005_000)
        XCTAssertEqual(workSnapshot?.segmentEndEpochMs, 1_015_000)

        // Past the schedule: nil (the activity ends, not a stale card).
        XCTAssertNil(content.snapshot(atEpochMs: 2_000_000_000))
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
