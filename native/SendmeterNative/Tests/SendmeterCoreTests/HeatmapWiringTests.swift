import XCTest

/// Source-text wiring test for the Daily Load heatmap (#754 r2): the view's
/// color, legend, and empty-state decisions must route through the
/// unit-tested Core policies (`TrainingLoad.heatmapCellFill`,
/// `heatmapLegendTypes`, `heatmapHasVisibleLoad`) so a regression to the
/// grey-producing behavior fails here even though the SwiftPM suite cannot
/// compile the App target's view.
///
/// Mutation directions the assertions bite:
/// - fillColor greying a positive cell directly (pre-#769 lookups) — removed
///   because the Core `heatmapCellFill` resolver carries the decision;
/// - legendTypes scanning the full `daily` map again (out-of-window swatches
///   under a grey grid — the reopened symptom wedge);
/// - rendering the raw 53-week grid when the window has no load instead of
///   the honest empty state.
final class HeatmapWiringTests: XCTestCase {
    private var source: String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot
            .appendingPathComponent("Sources/Features/Dashboard/TrainingLoad/ContributionHeatmapView.swift")
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func testCellFillRoutesThroughCoreResolver() {
        XCTAssertTrue(source.contains("TrainingLoad.heatmapCellFill("))
        XCTAssertFalse(
            source.contains("if cell.future { return Color(uiColor: .secondarySystemFill) }"),
            "the grey gate must live in the Core resolver, not inline in the view"
        )
    }

    func testLegendDerivesFromRenderedGridCells() {
        XCTAssertTrue(source.contains("TrainingLoad.heatmapLegendTypes(in: grid)"))
        XCTAssertFalse(
            source.contains("for entry in daily.values where entry.total > 0"),
            "the legend must not scan the full-history daily map (out-of-window wedge)"
        )
    }

    func testLoadFreeWindowRendersHonestEmptyStateInsteadOfGreyWall() {
        XCTAssertTrue(source.contains("TrainingLoad.heatmapHasVisibleLoad(in: grid)"))
        XCTAssertTrue(source.contains("No training records yet. Log a session to start your daily load heatmap."))
        XCTAssertTrue(source.contains("No training load in the past 53 weeks."))
    }
}
