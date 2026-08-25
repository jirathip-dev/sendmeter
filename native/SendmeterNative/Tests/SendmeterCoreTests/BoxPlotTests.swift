import XCTest
@testable import SendmeterCore

final class BoxPlotTests: XCTestCase {
    // MARK: fiveNumberSummary

    func testFiveNumberSummaryOddCount() {
        let summary = BoxPlot.fiveNumberSummary([3, 1, 4, 1, 5])
        XCTAssertEqual(summary?.min, 1)
        XCTAssertEqual(summary?.q1, 1)
        XCTAssertEqual(summary?.median, 3)
        XCTAssertEqual(summary?.q3, 4)
        XCTAssertEqual(summary?.max, 5)
    }

    func testFiveNumberSummaryInterpolatesQuartilesR7() {
        // R-7 linear interpolation, matching the web (Excel/numpy default):
        // [1,2,3,4] → q1 = 1.75, median = 2.5, q3 = 3.25.
        let summary = BoxPlot.fiveNumberSummary([1, 2, 3, 4])
        XCTAssertEqual(summary?.q1, 1.75)
        XCTAssertEqual(summary?.median, 2.5)
        XCTAssertEqual(summary?.q3, 3.25)
    }

    func testFiveNumberSummarySingleValue() {
        let summary = BoxPlot.fiveNumberSummary([42])
        XCTAssertEqual(summary?.min, 42)
        XCTAssertEqual(summary?.median, 42)
        XCTAssertEqual(summary?.max, 42)
    }

    func testFiveNumberSummaryNilForEmpty() {
        XCTAssertNil(BoxPlot.fiveNumberSummary([]))
    }

    // MARK: boxStats

    func testBoxStatsWhiskersClampToFence() {
        // [1, 2, 3, 4, 100]: q1 = 2, median 3, q3 4, IQR 2, fence [−1, 7] —
        // 100 is an outlier; whiskers clamp to the in-fence extremes.
        let stats = BoxPlot.boxStats([1, 2, 3, 4, 100])
        XCTAssertEqual(stats?.q1, 2)
        XCTAssertEqual(stats?.median, 3)
        XCTAssertEqual(stats?.q3, 4)
        XCTAssertEqual(stats?.whiskerLow, 1)
        XCTAssertEqual(stats?.whiskerHigh, 4)
        XCTAssertEqual(stats?.outliers, [100])
    }

    func testBoxStatsWithNoOutliers() {
        let stats = BoxPlot.boxStats([1, 2, 3, 4])
        XCTAssertEqual(stats?.whiskerLow, 1)
        XCTAssertEqual(stats?.whiskerHigh, 4)
        XCTAssertTrue(stats?.outliers.isEmpty ?? false)
    }

    func testBoxStatsKeepsOutliersInOriginalOrder() {
        // Both extremes lie beyond the 1.5·IQR fence; the outlier list must
        // preserve input order, not sorted order.
        let stats = BoxPlot.boxStats([-100, 1, 2, 3, 4, 5, 1_000])
        XCTAssertEqual(stats?.outliers, [-100, 1_000])
    }

    func testBoxStatsDegenerateIqrClampsWhiskersToMinMax() {
        // Zero IQR: fence collapses onto the quartile — the only in-fence
        // point is the quartile itself; extremes become outliers, whiskers
        // fall back to the in-fence min/max.
        let stats = BoxPlot.boxStats([1, 1, 1, 1, 1, 50])
        XCTAssertEqual(stats?.q1, 1)
        XCTAssertEqual(stats?.median, 1)
        XCTAssertEqual(stats?.q3, 1)
        XCTAssertEqual(stats?.whiskerLow, 1)
        XCTAssertEqual(stats?.whiskerHigh, 1)
        XCTAssertEqual(stats?.outliers, [50])
    }

    func testBoxStatsNilForEmpty() {
        XCTAssertNil(BoxPlot.boxStats([]))
    }

    func testBoxStatsIsDeterministicAndMatchesWebReference() {
        // Reference values computed with the web's boxStats on identical
        // input (issue #100 fixture): the per-rep charts must agree across
        // clients.
        let stats = BoxPlot.boxStats([8.1, 10.4, 9.2, 7.6, 11.0, 9.8, 8.9, 10.1, 9.5, 8.4])
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.median, 9.35)
        XCTAssertEqual(stats?.q1, 8.525)
        XCTAssertEqual(stats?.q3, 10.025)
        XCTAssertEqual(stats?.whiskerLow, 7.6)
        XCTAssertEqual(stats?.whiskerHigh, 11.0)
        XCTAssertTrue(stats?.outliers.isEmpty ?? false)
    }
}
