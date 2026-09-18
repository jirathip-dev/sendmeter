import Foundation
import XCTest
@testable import SendmeterCore

/// #928: the Force SwiftUI surfaces are outside the host SwiftPM module, so
/// these source invariants keep the two Force cards on the one shared
/// Dynamic Type-aware axis rule until the hosted Xcode compile gate runs —
/// including the failure they guard: fixed 8/9-point axis text and a
/// hand-rolled label rule reappearing in a card.
final class ForceCurveAxisWiringTests: XCTestCase {
    func testForceCurveCardUsesTheSharedRuleInsteadOfFixedPointText() {
        let curve = code(source("Sources/Features/Force/NativeForceCurveCard.swift"))

        XCTAssertEqual(
            countOccurrences(".font(.system(size: 8))", in: curve),
            0,
            "the fixed 8 pt axis text must be gone"
        )
        XCTAssertEqual(
            countOccurrences("@ScaledMetric(relativeTo: .caption2)", in: curve),
            1,
            "the curve's one label size must come from the shared caption2 base"
        )
        XCTAssertEqual(
            countOccurrences("ChartAxisLabelRule.basePointSize", in: curve),
            1,
            "the scaled metric must be seeded from the shared rule's base size"
        )
        XCTAssertEqual(
            countOccurrences(".font(axisLabelFont)", in: curve),
            2,
            "both axis labels (y and x) must draw at the resolved shared size"
        )
        XCTAssertEqual(
            countOccurrences("ChartAxisLabelRule.visibleTickIndices(", in: curve),
            1,
            "the x ticks must go through the shared tick-density adaptation"
        )
        XCTAssertEqual(
            countOccurrences("ChartAxisLabelRule.insets(", in: curve),
            1,
            "the plot insets must come from the shared rule"
        )
        XCTAssertEqual(
            countOccurrences("ForceCurvePlotGeometry(model: model, targetBand: targetBand)", in: curve),
            1,
            "the drawn geometry must come from the shared Core geometry"
        )
        XCTAssertEqual(
            countOccurrences("advanceRatio", in: curve),
            0,
            "the card must not re-implement the rule's width estimates"
        )
        XCTAssertEqual(
            countOccurrences("dynamicTypeSize.isAccessibilitySize", in: curve),
            2,
            "the metric row and the legend must switch to one-per-line at accessibility sizes"
        )
    }

    func testForceCurveCardKeepsThe755TooltipAndAccessibilityContract() {
        let curve = code(source("Sources/Features/Force/NativeForceCurveCard.swift"))

        XCTAssertEqual(
            countOccurrences("ForceCurveTooltipPlacement.x(", in: curve),
            1,
            "the tooltip must be clamped by the shared placement rule"
        )
        XCTAssertEqual(
            countOccurrences("ForceCurveTooltipPlacement.y(", in: curve),
            1
        )
        XCTAssertTrue(
            curve.contains("tooltipWidth: tooltipSize.width"),
            "the tooltip must use its MEASURED size, never a hard-coded one"
        )
        XCTAssertTrue(
            curve.contains("model.points[pointIndex]"),
            "the tooltip must show the measured point's real values"
        )
        XCTAssertEqual(
            countOccurrences("ForceCurveSelection.nearestPointIndex(", in: curve),
            1,
            "tap/scrub selection must keep the #755 log-space nearest-point rule"
        )
        XCTAssertTrue(
            curve.contains("accessibilityForceCurveChartDescriptor(model, targetBand: targetBand)"),
            "the accessibility chart summary/detail must stay attached"
        )
        XCTAssertEqual(
            countOccurrences("AXChartDescriptor(", in: curve),
            1
        )
    }

    func testForceProgressCardUsesTheSharedRuleInsteadOfFixedPointText() {
        let progress = code(source("Sources/Features/Force/ForceProgressCard.swift"))

        XCTAssertEqual(
            countOccurrences(".font(.system(size: 9))", in: progress),
            0,
            "the fixed 9 pt tile caption must be gone"
        )
        XCTAssertEqual(
            countOccurrences(".font(ChartAxisLabelRule.font)", in: progress),
            1,
            "the tile caption must use the shared Dynamic Type-aware label style"
        )
        XCTAssertEqual(
            countOccurrences("dynamicTypeSize.isAccessibilitySize", in: progress),
            1,
            "the two tiles must stack into one column at accessibility sizes"
        )
        XCTAssertEqual(
            countOccurrences("minimumScaleFactor(0.7)", in: progress),
            1,
            "the caption keeps its existing shrink limit"
        )
        XCTAssertEqual(
            countOccurrences("advanceRatio", in: progress),
            0,
            "the card must not re-implement the rule's width estimates"
        )
    }

    func testChartThemeHostsTheSharedLabelStyleNextToTheAxisToken() {
        let theme = code(source("Sources/App/ChartTheme.swift"))

        XCTAssertEqual(
            countOccurrences("public extension ChartAxisLabelRule", in: theme),
            1,
            "the shared label style belongs next to ChartToken.axis"
        )
        XCTAssertTrue(
            theme.contains("static let font: Font = .caption2.monospacedDigit()"),
            "the one axis label style is caption2 with monospaced digits"
        )
    }

    // MARK: - Helpers (duplicated from ForceTraceChartDomainWiringTests)

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
