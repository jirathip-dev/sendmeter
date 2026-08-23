import XCTest
@testable import SendmeterCore

final class WorkoutRawTraceTests: XCTestCase {
    // MARK: hrSeries — raw → HR series shaping

    func testNilRawYieldsEmptySeries() {
        XCTAssertEqual(WorkoutRawTrace.hrSeries(nil), [])
    }

    func testEmptyRawYieldsEmptySeries() {
        XCTAssertEqual(WorkoutRawTrace.hrSeries([]), [])
    }

    func testValidTraceKeepsShapeAndOrder() {
        let raw: [[Double?]] = [
            [0, 1.0, 2.0, 88],
            [1, 1.1, 2.2, 91],
            [2, 1.2, 2.4, 95]
        ]
        XCTAssertEqual(
            WorkoutRawTrace.hrSeries(raw),
            [
                WorkoutHrSample(t: 0, hr: 88),
                WorkoutHrSample(t: 1, hr: 91),
                WorkoutHrSample(t: 2, hr: 95)
            ]
        )
    }

    func testShortEntriesAreDropped() {
        // Fewer than 4 elements: the web reads s[0]/s[3] and would trap; the
        // native parse drops them (t exists but there is no hr slot).
        let raw: [[Double?]] = [
            [0],
            [1, 2],
            [1, 2, 3],
            [5, 1, 2, 100]
        ]
        XCTAssertEqual(WorkoutRawTrace.hrSeries(raw), [WorkoutHrSample(t: 5, hr: 100)])
    }

    func testNegativeOrNonFiniteTimeIsDropped() {
        let raw: [[Double?]] = [
            [-1, 1, 2, 88],
            [Double.nan, 1, 2, 88],
            [Double.infinity, 1, 2, 88],
            [10, 1, 2, 88]
        ]
        XCTAssertEqual(WorkoutRawTrace.hrSeries(raw), [WorkoutHrSample(t: 10, hr: 88)])
    }

    func testNullHrStaysAGap() {
        let raw: [[Double?]] = [
            [0, 1, 2, nil],
            [1, 1, 2, 90]
        ]
        XCTAssertEqual(
            WorkoutRawTrace.hrSeries(raw),
            [
                WorkoutHrSample(t: 0, hr: nil),
                WorkoutHrSample(t: 1, hr: 90)
            ]
        )
    }

    func testHeartRateIsMappedVerbatimWithoutAPlausibilityClamp() {
        // The web maps entries verbatim (`hr = s[3] ?? null`) with no
        // 30–250 clamp (#645 review F9): a genuine low reading — a fit
        // athlete's deep-rest 28 bpm, or the watch's first post-start
        // sample — stays a real reading, not a fabricated gap. Native now
        // matches, so both platforms draw the same chart for identical data.
        let raw: [[Double?]] = [
            [0, 1, 2, 28],
            [1, 1, 2, 0],
            [2, 1, 2, 251],
            [3, 1, 2, 130]
        ]
        XCTAssertEqual(
            WorkoutRawTrace.hrSeries(raw),
            [
                WorkoutHrSample(t: 0, hr: 28),
                WorkoutHrSample(t: 1, hr: 0),
                WorkoutHrSample(t: 2, hr: 251),
                WorkoutHrSample(t: 3, hr: 130)
            ]
        )
    }

    func testNonFiniteHeartRateBecomesAGap() {
        // jsonb cannot hold NaN/Infinity, so this is purely defensive — but
        // if a row ever carries one, it becomes a gap like a nil.
        let raw: [[Double?]] = [
            [0, 1, 2, Double.nan],
            [1, 1, 2, Double.infinity],
            [2, 1, 2, 130]
        ]
        XCTAssertEqual(
            WorkoutRawTrace.hrSeries(raw),
            [
                WorkoutHrSample(t: 0, hr: nil),
                WorkoutHrSample(t: 1, hr: nil),
                WorkoutHrSample(t: 2, hr: 130)
            ]
        )
    }

    func testExtraElementsBeyondTheFourthAreIgnored() {
        // The transport decodes raw as [[Double?]], so a 5th+ element can
        // only be numeric (a non-number would fail the whole row's decode) —
        // extra values are ignored, matching the web's s[0]/s[3] reads.
        let raw: [[Double?]] = [
            [0, 1, 2, 88, 999, -1]
        ]
        XCTAssertEqual(WorkoutRawTrace.hrSeries(raw), [WorkoutHrSample(t: 0, hr: 88)])
    }

    // MARK: hrRuns — contiguous non-nil runs (the AC2 fixture)

    private func sample(_ t: Double, _ hr: Double?) -> WorkoutHrSample {
        WorkoutHrSample(t: t, hr: hr)
    }

    func testHrRunsSplitsAtNilGaps() {
        // A gap in the middle splits the trace into two runs — each drawn as
        // its own series so the chart never interpolates across the gap.
        let runs = WorkoutRawTrace.hrRuns([
            sample(0, 88), sample(1, 91), sample(2, 95),
            sample(3, nil),
            sample(4, 100), sample(5, 102)
        ])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0], [sample(0, 88), sample(1, 91), sample(2, 95)])
        XCTAssertEqual(runs[1], [sample(4, 100), sample(5, 102)])
    }

    func testHrRunsKeepsTrailingAndLeadingGaps() {
        // nil before the first reading and after the last don't create empty
        // runs; the surviving runs keep their boundaries.
        let runs = WorkoutRawTrace.hrRuns([
            sample(0, nil),
            sample(1, 90), sample(2, 92),
            sample(3, nil),
            sample(4, 100)
        ])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0], [sample(1, 90), sample(2, 92)])
        XCTAssertEqual(runs[1], [sample(4, 100)])
    }

    func testHrRunsEmptyWhenNoHr() {
        XCTAssertEqual(WorkoutRawTrace.hrRuns([]), [])
        XCTAssertEqual(WorkoutRawTrace.hrRuns([sample(0, nil), sample(1, nil)]), [])
    }

    func testHrRunsKeepsSingleSampleRun() {
        // A lone valid sample is a run of 1 — the chart skips runs < 2, but
        // the split itself is honest about where it starts/ends.
        let runs = WorkoutRawTrace.hrRuns([
            sample(0, 88),
            sample(1, nil),
            sample(2, 90)
        ])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0], [sample(0, 88)])
        XCTAssertEqual(runs[1], [sample(2, 90)])
    }

    // MARK: downsample / downsampleRuns — bounded marks (F11)

    func testDownsampleKeepsUnderCapUntouched() {
        let small = (0..<10).map { sample(Double($0), 100 + Double($0)) }
        XCTAssertEqual(WorkoutRawTrace.downsample(small, maxPoints: 600), small)
    }

    func testDownsampleDecimatesUniformlyKeepingEndpoints() {
        let large = (0..<100).map { sample(Double($0), 100 + Double($0)) }
        let result = WorkoutRawTrace.downsample(large, maxPoints: 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.first, large.first)
        XCTAssertEqual(result.last, large.last)
        // Evenly spread across the original span.
        let expectedTs = Set([0, 11, 22, 33, 44, 55, 66, 77, 88, 99].map(Double.init))
        XCTAssertEqual(Set(result.map(\.t)), expectedTs)
    }

    func testDownsampleRunsBoundedByCap() {
        // A ~5000-sample single-run trace (a 95-min session at the watch's
        // 3 s stride is ~1900; a 3-h outdoor one is ~7200).
        let large = (0..<5000).map { sample(Double($0), 100 + Double($0 % 40)) }
        let runs = WorkoutRawTrace.downsampleRuns(large, maxPoints: 600)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].count, 600)
        XCTAssertEqual(runs[0].first, large.first)
        XCTAssertEqual(runs[0].last, large.last)
    }

    func testDownsampleRunsSplitsThenBoundsPerRun() {
        // Two runs of 1000 each → each gets a 300-point budget (600 total).
        var input: [WorkoutHrSample] = []
        input += (0..<1000).map { sample(Double($0), 100) }
        input.append(sample(1000, nil))
        input += (1001..<2001).map { sample(Double($0), 110) }
        let runs = WorkoutRawTrace.downsampleRuns(input, maxPoints: 600)
        XCTAssertEqual(runs.count, 2)
        let total = runs.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, 600)
        XCTAssertEqual(runs[0].first?.hr, 100)
        XCTAssertEqual(runs[1].first?.hr, 110)
    }

    // MARK: isChartRenderable — the web's < 2 valid samples guard

    func testChartNeedsAtLeastTwoValidSamples() {
        XCTAssertFalse(WorkoutRawTrace.isChartRenderable([]))
        XCTAssertFalse(WorkoutRawTrace.isChartRenderable([WorkoutHrSample(t: 0, hr: nil)]))
        XCTAssertFalse(WorkoutRawTrace.isChartRenderable([WorkoutHrSample(t: 0, hr: 88)]))
        XCTAssertTrue(WorkoutRawTrace.isChartRenderable([
            WorkoutHrSample(t: 0, hr: 88),
            WorkoutHrSample(t: 1, hr: 91)
        ]))
        // Gaps don't count as points.
        XCTAssertFalse(WorkoutRawTrace.isChartRenderable([
            WorkoutHrSample(t: 0, hr: nil),
            WorkoutHrSample(t: 1, hr: nil)
        ]))
    }

    // MARK: WorkoutChartAxis — the shared x domain

    func testTimeMaxDrivenByTraceEnd() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            WorkoutHrSample(t: 0, hr: 88),
            WorkoutHrSample(t: 119, hr: 95)
        ]
        // endedAt is later than the trace end — the trace wins, so a workout
        // left running after the last climb doesn't squash the line.
        XCTAssertEqual(
            WorkoutChartAxis.timeMaxS(
                startedAt: start,
                endedAt: start.addingTimeInterval(3_600),
                attempts: [],
                samples: samples
            ),
            119
        )
    }

    func testTimeMaxDrivenByAttemptEnd() {
        let start = Date(timeIntervalSince1970: 1_000)
        let attempts = [
            WorkoutAttempt(startedAt: start.addingTimeInterval(60), durationSeconds: 90)
        ]
        XCTAssertEqual(
            WorkoutChartAxis.timeMaxS(
                startedAt: start,
                endedAt: start.addingTimeInterval(3_600),
                attempts: attempts,
                samples: []
            ),
            150
        )
    }

    func testTimeMaxTakesTheLaterOfTraceAndAttempts() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [WorkoutHrSample(t: 0, hr: 88), WorkoutHrSample(t: 300, hr: 95)]
        let attempts = [
            WorkoutAttempt(startedAt: start.addingTimeInterval(100), durationSeconds: 30)
        ]
        XCTAssertEqual(
            WorkoutChartAxis.timeMaxS(
                startedAt: start,
                endedAt: start.addingTimeInterval(3_600),
                attempts: attempts,
                samples: samples
            ),
            300
        )
    }

    func testTimeMaxFallsBackToWorkoutDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            WorkoutChartAxis.timeMaxS(
                startedAt: start,
                endedAt: start.addingTimeInterval(50),
                attempts: [],
                samples: []
            ),
            50
        )
    }

    func testTimeMaxNeverBelowOne() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            WorkoutChartAxis.timeMaxS(
                startedAt: start,
                endedAt: start.addingTimeInterval(0.4),
                attempts: [],
                samples: []
            ),
            1
        )
    }

    func testXTicksSpanTheDomain() {
        XCTAssertEqual(WorkoutChartAxis.xTicks(tMax: 120), [0, 60, 120])
    }

    func testFmtMinSec() {
        XCTAssertEqual(WorkoutChartAxis.fmtMinSec(0), "0:00")
        XCTAssertEqual(WorkoutChartAxis.fmtMinSec(65), "1:05")
        XCTAssertEqual(WorkoutChartAxis.fmtMinSec(3_659), "60:59")
        // Rounds the total first, so a tick at 119.6 s reads 2:00 — not the
        // old "0:60" (floor minute + rounded second remainder). The web was
        // aligned to this (#645 review F15).
        XCTAssertEqual(WorkoutChartAxis.fmtMinSec(119.6), "2:00")
        XCTAssertEqual(WorkoutChartAxis.fmtMinSec(59.4), "0:59")
    }

    // MARK: attemptWindows — the shared x-domain contribution (F4)

    func testAttemptWindowsPlaceOnTraceSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let attempts = [
            WorkoutAttempt(startedAt: start.addingTimeInterval(30), durationSeconds: 40, source: "auto"),
            WorkoutAttempt(
                startedAt: start.addingTimeInterval(300),
                durationSeconds: 20,
                source: "manual"
            )
        ]
        XCTAssertEqual(
            WorkoutChartAxis.attemptWindows(startedAt: start, attempts: attempts),
            [
                WorkoutChartAxis.AttemptWindow(start: 30, end: 70, manual: false),
                WorkoutChartAxis.AttemptWindow(start: 300, end: 320, manual: true)
            ]
        )
    }

    // MARK: selectedSample — scrub hit testing (#755)

    func testSelectedSampleStaysInsideItsRun() {
        let runOne = [
            sample(0, 88), sample(1, 91), sample(2, 95)
        ]
        let runTwo = [
            sample(10, 100), sample(11, 102), sample(12, 103)
        ]
        XCTAssertEqual(WorkoutRawTrace.selectedSample(at: 1.4, inRuns: [runOne, runTwo]), sample(1, 91))
        XCTAssertEqual(WorkoutRawTrace.selectedSample(at: 11.4, inRuns: [runOne, runTwo]), sample(11, 102))
    }

    func testSelectedSampleNeverCrossesAGap() {
        let runOne = [
            sample(0, 88), sample(1, 91), sample(2, 95)
        ]
        let runTwo = [
            sample(10, 100), sample(11, 102), sample(12, 103)
        ]
        XCTAssertNil(WorkoutRawTrace.selectedSample(at: 4, inRuns: [runOne, runTwo]))
        XCTAssertNil(WorkoutRawTrace.selectedSample(at: 9, inRuns: [runOne, runTwo]))
    }

    func testSelectedSampleIgnoresEmptyRunsAndNonFiniteTime() {
        let run = [
            sample(0, 88), sample(1, 91)
        ]
        XCTAssertNil(WorkoutRawTrace.selectedSample(at: .nan, inRuns: [run]))
        XCTAssertNil(WorkoutRawTrace.selectedSample(at: 0, inRuns: [[]]))
    }
}
