import XCTest

final class RecoveryInputsWiringTests: XCTestCase {
    private var source: String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent("Sources/Features/Dashboard/RecoveryInputsSheet.swift")
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func testRecoveryChartsPinContainmentAndBothTrendWiring() {
        XCTAssertTrue(source.contains("yStart: .value(\"Baseline\""))
        XCTAssertTrue(source.contains(".chartPlotStyle { plotArea in"))
        XCTAssertTrue(source.contains("plotArea.clipped()"))
        XCTAssertTrue(source.contains(".value(\"28d EWMA\""))
        XCTAssertTrue(source.contains("StrokeStyle(lineWidth: 1.5, dash:"))
        XCTAssertTrue(source.contains("RecoveryBarGradient.classification"))
        XCTAssertTrue(source.contains("RecoveryBarGradient.position"))
        // #753 R2: both trend families must share one series dimension with
        // unique per-family values — the old two-key/colliding-value emission
        // made Swift Charts silently drop the 28d dashed series.
        XCTAssertTrue(source.contains("series: .value(\"Trend\", \"7d-run-"))
        XCTAssertTrue(source.contains("series: .value(\"Trend\", \"28d-run-"))
        // #753 AC6: without a warmed 28d baseline the bar falls back to the
        // neutral treatment instead of classifying against zero/minimum.
        XCTAssertTrue(source.contains("day.trend28.map { barColor"))
    }

    /// #753 R2: the DEBUG evidence fixture must feed a genuinely warmed 60-day
    /// history (a 14-day fixture made the 28d line an immature average that
    /// hugged the bars and hid the device parity defect), keep a wear gap
    /// inside the visible 14-day window so honest run splitting is captured,
    /// and stay deterministic so evidence reproduces.
    func testRecoveryFixtureFeedsWarmedDeterministicHistory() {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appURL = packageRoot.appendingPathComponent("Sources/App/SendmeterNativeApp.swift")
        guard let appSource = try? String(contentsOf: appURL, encoding: .utf8) else {
            return XCTFail("SendmeterNativeApp.swift not readable")
        }
        XCTAssertTrue(appSource.contains("--recovery-fixture"))
        XCTAssertTrue(appSource.contains("RecoveryInputsSheet(fixtureMetrics: metrics)"))
        XCTAssertTrue(appSource.contains("(0..<60)"), "the fixture must supply a full 60-day warm-up window")
        XCTAssertTrue(appSource.contains("gapOffsets"), "the fixture must include deterministic wear gaps")
        XCTAssertTrue(appSource.contains("[58, 30, 8]"), "a gap must sit inside the visible 14-day window (offset 8)")
        XCTAssertFalse(appSource.contains("arc4random"), "the fixture must be deterministic for reproducible evidence")
    }
}
