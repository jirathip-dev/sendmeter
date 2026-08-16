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

    func testAbsurdHeartRateBecomesAGap() {
        // Negative, zero, sub-resting and above-plausible-max reads are sensor
        // artifacts → nil, so the chart splits its line instead of drawing a
        // spike.
        let raw: [[Double?]] = [
            [0, 1, 2, -40],
            [1, 1, 2, 0],
            [2, 1, 2, 29],
            [3, 1, 2, 251],
            [4, 1, 2, Double.nan],
            [5, 1, 2, Double.infinity]
        ]
        XCTAssertEqual(
            WorkoutRawTrace.hrSeries(raw),
            [
                WorkoutHrSample(t: 0, hr: nil),
                WorkoutHrSample(t: 1, hr: nil),
                WorkoutHrSample(t: 2, hr: nil),
                WorkoutHrSample(t: 3, hr: nil),
                WorkoutHrSample(t: 4, hr: nil),
                WorkoutHrSample(t: 5, hr: nil)
            ]
        )
    }

    func testPlausibleBoundsAreKept() {
        let raw: [[Double?]] = [
            [0, 1, 2, 30],
            [1, 1, 2, 250]
        ]
        XCTAssertEqual(
            WorkoutRawTrace.hrSeries(raw),
            [
                WorkoutHrSample(t: 0, hr: 30),
                WorkoutHrSample(t: 1, hr: 250)
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
        // web's "0:60" (floor minute + rounded second remainder).
        XCTAssertEqual(WorkoutChartAxis.fmtMinSec(119.6), "2:00")
        XCTAssertEqual(WorkoutChartAxis.fmtMinSec(59.4), "0:59")
    }
}
