import XCTest
@testable import SendmeterCore

/// #929: the Training Load weekly bars are SwiftUI app-target code, so the
/// host SwiftPM run cannot compile `TrainingLoadSheet.swift`. These source
/// invariants keep both label rows on the shared Dynamic Type-aware axis rule
/// (#928) until the hosted Xcode gate compiles them, and the value/label
/// golden pins what the chart plots (AC3/AC5) against a relayout.
///
/// Mutation directions the assertions bite:
/// - the fixed 9 pt axis text (or a hand-rolled width estimate) reappearing in
///   the weekly bars;
/// - a label row drawn without the shared column plan, i.e. every label drawn
///   again so a grown label overlaps its neighbour or leaves the card;
/// - the chart height or the tooltip reserve pinned to a fixed number again;
/// - the tap/scrub hit test drifting from the slots the labels sit on;
/// - the plotted weekly values or their labels changing while the chart is
///   relaid out.
final class TrainingLoadSheetAxisWiringTests: XCTestCase {
    private static let sheetPath = "Sources/Features/Dashboard/TrainingLoad/TrainingLoadSheet.swift"

    // MARK: - The shared rule owns both label rows

    func testWeeklyBarLabelsUseTheSharedRuleInsteadOfFixedPointText() {
        let sheet = code(source(Self.sheetPath))

        XCTAssertEqual(
            countOccurrences(".font(.system(size: 9))", in: sheet),
            0,
            "the two fixed 9 pt axis-label sites must be gone"
        )
        XCTAssertEqual(
            countOccurrences(".font(ChartAxisLabelRule.font)", in: sheet),
            3,
            "both label rows and the exact-values readout draw at the shared style"
        )
        XCTAssertEqual(
            countOccurrences("@ScaledMetric(relativeTo: .caption2)", in: sheet),
            3,
            "the drawn label size, the label band and the tooltip reserve all come "
                + "from the shared caption2 base"
        )
        XCTAssertEqual(
            countOccurrences("ChartAxisLabelRule.basePointSize", in: sheet),
            1,
            "the scaled metric must be seeded from the shared rule's base size"
        )
        XCTAssertEqual(
            countOccurrences("ChartAxisLabelRule.columnLabelPlan(", in: sheet),
            3,
            "the AU totals, the week captions and the readout's omission check all "
                + "go through the shared column plan"
        )
        XCTAssertEqual(
            countOccurrences("reservesValueBand: !valuePlan.labelledIndices.isEmpty", in: sheet),
            1,
            "a row that drew any label keeps its band in every column, so all bars "
                + "share one baseline"
        )
        XCTAssertEqual(
            countOccurrences("tooltipReserveBaseHeight", in: sheet),
            2,
            "the reserved tooltip slot follows the resolved text size from a base "
                + "instead of staying fixed"
        )
        XCTAssertEqual(
            countOccurrences("maxWidth: proxy.size.width", in: sheet),
            1,
            "the tooltip slot measures its own width so the tooltip wraps inside the card"
        )
        XCTAssertEqual(
            countOccurrences("dynamicTypeSize.isAccessibilitySize", in: sheet),
            1,
            "the weekly card's title and delta chip must stack at accessibility sizes"
        )
        XCTAssertEqual(
            countOccurrences("advanceRatio", in: sheet),
            0,
            "the view must not re-implement the rule's width estimates"
        )
    }

    func testWeeklyBarInspectionAndAccessibilityContractIsIntact() {
        let sheet = code(source(Self.sheetPath))

        XCTAssertEqual(
            countOccurrences("TrainingLoadInteraction.weeklyBarIndex(", in: sheet),
            1,
            "tap/scrub must keep the #650 slot hit test"
        )
        XCTAssertTrue(sheet.contains("SpatialTapGesture()"), "tap-to-select must stay")
        XCTAssertTrue(sheet.contains("DragGesture(minimumDistance: 12)"), "the scrub gesture must stay")
        XCTAssertEqual(
            countOccurrences("Haptics.shared.playGesture(.selection)", in: sheet),
            1,
            "the per-change selection tick must stay"
        )
        XCTAssertEqual(
            countOccurrences("SelectionHaptics.valueChanged(", in: sheet),
            1,
            "the haptic dedupe guard must stay"
        )
        XCTAssertTrue(
            sheet.contains("accessibilityLabel(for: week, index: index)"),
            "each bar keeps its VoiceOver label (week, AU total and delta)"
        )
        XCTAssertTrue(
            sheet.contains("TrainingLoadTooltip {"),
            "the selected-value tooltip must stay attached to the chart"
        )
        XCTAssertTrue(
            sheet.contains("valuesReadout"),
            "the exact-value readout must stay wired for dense axes"
        )
        XCTAssertTrue(
            sheet.contains("AU"),
            "axis units stay explicit"
        )
    }

    // MARK: - What the chart plots (AC3/AC5 golden)

    /// Four weeks ending on a pinned reference date: the totals, the week
    /// labels and their formatted text are exactly what the pre-#929 chart
    /// plotted (`TrainingMetrics.weeklyLoads` + `TrainingLoad.formatAU`, both
    /// untouched by this slice). A relayout that re-derives, re-sorts or
    /// re-windows the bars fails here.
    func testWeeklyBarValuesAndLabelsAreUnchanged() throws {
        let bangkok = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-09-19", timeZone: bangkok))
        let sessions = [
            session("2026-08-25", duration: 30, rpe: 3),
            session("2026-09-01", duration: 75, rpe: 8),
            session("2026-09-10", duration: 90, rpe: 7),
            session("2026-09-11", duration: 90, rpe: 7),
            session("2026-09-18", duration: 45, rpe: 8)
        ]

        let weeks = TrainingMetrics.weeklyLoads(
            sessions: sessions,
            referenceDate: reference,
            timeZone: bangkok
        )

        XCTAssertEqual(weeks.map(\.label), ["3w", "2w", "1w", "Now"])
        XCTAssertEqual(weeks.map(\.total), [90, 600, 1_260, 360])
        XCTAssertEqual(
            weeks.map { TrainingLoad.formatAU($0.total, locale: Locale(identifier: "en_US")) },
            ["90", "600", "1,260", "360"]
        )
    }

    // MARK: - Helpers (duplicated from ForceCurveAxisWiringTests)

    private func session(_ date: String, duration: Int, rpe: Double) -> Session {
        Session(
            id: UUID(),
            date: date,
            type: "board",
            typeLabel: "Board Climbing",
            durationMinutes: duration,
            rpe: rpe,
            note: "",
            phase: .capacity
        )
    }

    private func source(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private func code(_ source: String) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlockComments
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    private func countOccurrences(_ needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchStart = source.startIndex
        while let match = source.range(of: needle, range: searchStart..<source.endIndex) {
            count += 1
            searchStart = match.upperBound
        }
        return count
    }
}
