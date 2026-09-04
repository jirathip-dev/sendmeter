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

    /// #895 root cause: the empty/heatmap/legend decision ran against a @State
    /// grid snapshot that could predate the CURRENT `daily` — the deprecated
    /// single-parameter `onChange(of:)` action runs against the pre-update
    /// view value, so a grid first built while `daily` was empty was never
    /// rebuilt when the sync populated it, and a session-filled window
    /// rendered "No training load in the past 53 weeks." next to a real
    /// 28-day mix (Build 51, Thai-locale device). The view must resolve the
    /// decision grid from the CURRENT inputs every pass.
    func testGridDecisionResolvesFromCurrentDailyInputs() {
        XCTAssertTrue(
            source.contains("private var resolvedGrid: HeatmapGrid"),
            "the rendered grid must come from a resolver keyed to the current daily/today"
        )
        XCTAssertTrue(
            source.contains("gridBuiltFromDaily == daily"),
            "the cached grid must be reused only when its inputs are unchanged"
        )
    }

    /// The data-change hook must use the two-parameter `onChange` form whose
    /// action runs against the post-update view value; the deprecated
    /// one-parameter form (`.onChange(of: daily) { _ in ...`) can strand the
    /// grid cache on the pre-update `daily` (#895).
    func testDataChangeHookUsesTwoParameterOnChange() {
        XCTAssertFalse(
            source.contains("onChange(of: daily) { _ in"),
            "the single-parameter onChange action runs against the pre-update view value"
        )
        XCTAssertTrue(source.contains("onChange(of: daily) { _, _ in"))
        XCTAssertTrue(source.contains("onChange(of: today) { _, _ in"))
    }
}
