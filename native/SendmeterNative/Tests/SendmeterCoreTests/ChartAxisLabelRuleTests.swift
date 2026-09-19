import SwiftUI
import XCTest
@testable import SendmeterCore

/// #928 AC1: the one shared Dynamic Type-aware axis-label rule.
///
/// The discriminating case is
/// `testAccessibilitySizesThinTheTickLabelsAtTheSmallestPhoneWidth`: at the
/// default text size every admitted tick stays labelled, and at an
/// accessibility text size the label that would collide is dropped instead of
/// overlapping. An implementation that keeps the old fixed-size behaviour (no
/// density adaptation) fails it, and so does one that lets grown labels
/// collide.
final class ChartAxisLabelRuleTests: XCTestCase {
    /// iPhone SE (3rd generation) is the smallest supported phone (375 pt),
    /// minus ForceView's 16 pt screen padding and SurfaceCard's 16 pt card
    /// padding — the width `NativeForceCurvePlot` draws its Canvas in.
    private static let sePlotWidth: CGFloat = 375 - 2 * 16 - 2 * 16

    /// The resolved `caption2` size at the largest accessibility text size,
    /// MEASURED on the iPhone SE (3rd generation) simulator by the app-target
    /// legibility lane: `UIFontMetrics(forTextStyle: .caption2).scaledValue(for: 11)`
    /// is 11 pt at the default size and 40.5 pt at `accessibility5`.
    private static let accessibilityPointSize: CGFloat = 40.5

    // MARK: - The shared rule is the caption2 style

    func testTheSharedRuleIsTheCaption2StyleAtTheDefaultSize() {
        XCTAssertEqual(ChartAxisLabelRule.basePointSize, 11)
        XCTAssertEqual(ChartAxisLabelRule.font, Font.caption2.monospacedDigit())
        XCTAssertEqual(ChartAxisLabelRule.minimumGap, 6)
    }

    func testWidthAndHeightEstimatesScaleWithTheResolvedPointSize() {
        let label = "120s"
        XCTAssertEqual(
            ChartAxisLabelRule.estimatedLabelWidth(label, pointSize: 22),
            ChartAxisLabelRule.estimatedLabelWidth(label, pointSize: 11) * 2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChartAxisLabelRule.estimatedLabelHeight(pointSize: 22),
            ChartAxisLabelRule.estimatedLabelHeight(pointSize: 11) * 2,
            accuracy: 0.0001
        )
    }

    // MARK: - Tick density (the documented collision adaptation)

    func testAccessibilitySizesThinTheTickLabelsAtTheSmallestPhoneWidth() {
        let defaultLayout = layout(pointSize: ChartAxisLabelRule.basePointSize)
        XCTAssertEqual(
            ChartAxisLabelRule.visibleTickIndices(
                labels: defaultLayout.labels,
                positions: defaultLayout.positions,
                pointSize: ChartAxisLabelRule.basePointSize
            ),
            Array(defaultLayout.labels.indices),
            "the default text size keeps every admitted tick labelled"
        )

        let accessibilitySize = Self.accessibilityPointSize
        let accessibilityLayout = layout(pointSize: accessibilitySize)
        let kept = ChartAxisLabelRule.visibleTickIndices(
            labels: accessibilityLayout.labels,
            positions: accessibilityLayout.positions,
            pointSize: accessibilitySize
        )
        XCTAssertEqual(
            kept,
            [0, 1, 3],
            "at the largest accessibility text size the 60s label must be dropped "
                + "instead of colliding (the 1s / 10s / 120s labels survive)"
        )
        XCTAssertLessThan(
            kept.count,
            accessibilityLayout.labels.count,
            "accessibility text sizes must thin the labelled ticks"
        )
    }

    func testEveryKeptLabelClearsItsNeighbourAcrossTheDynamicTypeRange() {
        for pointSize in stride(from: CGFloat(11), through: CGFloat(34), by: CGFloat(1)) {
            let layout = layout(pointSize: pointSize)
            let kept = ChartAxisLabelRule.visibleTickIndices(
                labels: layout.labels,
                positions: layout.positions,
                pointSize: pointSize
            )
            XCTAssertFalse(kept.isEmpty, "the leftmost tick is always labelled at \(pointSize) pt")
            XCTAssertEqual(kept, kept.sorted(), "kept ticks keep their order at \(pointSize) pt")
            for (previous, next) in zip(kept, kept.dropFirst()) {
                let previousRight = layout.positions[previous]
                    + ChartAxisLabelRule.estimatedLabelWidth(
                        layout.labels[previous],
                        pointSize: pointSize
                    ) / 2
                let nextLeft = layout.positions[next]
                    - ChartAxisLabelRule.estimatedLabelWidth(
                        layout.labels[next],
                        pointSize: pointSize
                    ) / 2
                XCTAssertGreaterThanOrEqual(
                    nextLeft - previousRight,
                    ChartAxisLabelRule.minimumGap - 0.0001,
                    "labels at \(pointSize) pt must not collide"
                )
            }
        }
    }

    func testTheLeftmostTickIsAlwaysLabelledEvenWhenNothingFits() {
        let kept = ChartAxisLabelRule.visibleTickIndices(
            labels: ["120s", "120s"],
            positions: [10, 12],
            pointSize: 34
        )
        XCTAssertEqual(kept, [0], "a cramped plot still labels its first tick")
    }

    // MARK: - Insets keep the outermost labels inside the canvas

    func testInsetsKeepTheOutermostLabelsInsideTheCanvasAtEveryTextSize() {
        for pointSize in stride(from: CGFloat(11), through: CGFloat(34), by: CGFloat(1)) {
            let layout = layout(pointSize: pointSize)
            let insets = ChartAxisLabelRule.insets(
                yLabels: Self.yLabels,
                xLabels: layout.labels,
                pointSize: pointSize
            )
            let height = ChartAxisLabelRule.estimatedLabelHeight(pointSize: pointSize)
            let widestY = Self.yLabels
                .map { ChartAxisLabelRule.estimatedLabelWidth($0, pointSize: pointSize) }
                .max() ?? 0
            let widestX = layout.labels
                .map { ChartAxisLabelRule.estimatedLabelWidth($0, pointSize: pointSize) }
                .max() ?? 0

            // The y column centres its labels on half the leading inset.
            XCTAssertGreaterThanOrEqual(insets.leading / 2 - widestY / 2, 0)
            XCTAssertLessThanOrEqual(insets.leading / 2 + widestY / 2, insets.leading - 2)
            // The top y label sits on the plot's top edge.
            XCTAssertGreaterThanOrEqual(insets.top - height / 2, 0)
            // The x labels sit centred in the bottom band.
            XCTAssertGreaterThanOrEqual(insets.bottom - height, 0)
            // The last x label sits centred on the plot's right edge.
            XCTAssertLessThanOrEqual(widestX / 2, insets.trailing - 2)
            // The plot rect stays usable at the smallest phone width.
            XCTAssertGreaterThan(
                Self.sePlotWidth - insets.leading - insets.trailing,
                100,
                "the plot must stay wide enough to draw at \(pointSize) pt"
            )
        }
    }

    func testInsetsNeverShrinkTheShippedPlotAtTheDefaultSize() {
        let insets = ChartAxisLabelRule.insets(
            yLabels: Self.yLabels,
            xLabels: Self.labels,
            pointSize: ChartAxisLabelRule.basePointSize
        )
        XCTAssertGreaterThanOrEqual(insets.leading, 32)
        XCTAssertGreaterThanOrEqual(insets.trailing, 8)
        XCTAssertGreaterThanOrEqual(insets.top, 8)
        XCTAssertGreaterThanOrEqual(insets.bottom, 20)
        XCTAssertEqual(insets.leading, 32, accuracy: 0.0001, "the shipped y column was 32 pt wide")
        XCTAssertEqual(insets.bottom, 20, accuracy: 0.0001, "the shipped x band was 20 pt tall")
    }

    func testInsetsGrowWithTheResolvedPointSize() {
        let small = ChartAxisLabelRule.insets(
            yLabels: Self.yLabels,
            xLabels: Self.labels,
            pointSize: ChartAxisLabelRule.basePointSize
        )
        let large = ChartAxisLabelRule.insets(
            yLabels: Self.yLabels,
            xLabels: Self.labels,
            pointSize: Self.accessibilityPointSize
        )
        XCTAssertGreaterThan(large.leading, small.leading)
        XCTAssertGreaterThan(large.trailing, small.trailing)
        XCTAssertGreaterThan(large.top, small.top)
        XCTAssertGreaterThan(large.bottom, small.bottom)
    }

    // MARK: - Helpers

    /// Mirrors `NativeForceCurvePlot`'s layout for the fixture curve: the
    /// shared rule's insets at `pointSize`, then the log-x positions the
    /// geometry maps inside the remaining plot rect.
    private func layout(pointSize: CGFloat) -> (labels: [String], positions: [CGFloat]) {
        let geometry = ForceCurvePlotGeometry(
            model: Self.fixtureModel(),
            targetBand: Self.fixtureTargetBand()
        )
        let ticks = Self.ticks.filter {
            $0 >= geometry.minimumSeconds && $0 <= geometry.maximumSeconds
        }
        let labels = ticks.map { "\(Int($0))s" }
        let yLabels = (0...2).map { index in
            String(Int((geometry.maximumValue * Double(2 - index) / 2).rounded()))
        }
        let insets = ChartAxisLabelRule.insets(
            yLabels: yLabels,
            xLabels: labels,
            pointSize: pointSize
        )
        let plotWidth = Self.sePlotWidth - insets.leading - insets.trailing
        let positions = ticks.map {
            insets.leading + CGFloat(geometry.xFraction(seconds: $0)) * plotWidth
        }
        return (labels, positions)
    }

    private static let ticks: [Double] = [1, 10, 60, 120]
    private static let labels = ["1s", "10s", "60s", "120s"]
    /// `ForceCurvePlotGeometry` renders these for the fixture's 52.8 kg
    /// y-maximum (pinned in `ForceCurvePlotGeometryTests`).
    private static let yLabels = ["53", "26", "0"]

    private static func fixtureModel() -> ForceCurveModel {
        ForceCurveModel(
            points: [
                ForceCurvePoint(windowSeconds: 1, kilograms: 44.2),
                ForceCurvePoint(windowSeconds: 3, kilograms: 38.5),
                ForceCurvePoint(windowSeconds: 7, kilograms: 33.1),
                ForceCurvePoint(windowSeconds: 15, kilograms: 29.8),
                ForceCurvePoint(windowSeconds: 30, kilograms: 27.4),
                ForceCurvePoint(windowSeconds: 60, kilograms: 25.9),
                ForceCurvePoint(windowSeconds: 120, kilograms: 24.8)
            ],
            maximumForceKilograms: 46.3,
            criticalForceKilograms: 24.6,
            impulseAboveCriticalForceKilogramSeconds: 1234.5,
            capabilityFit: nil,
            confidenceBand: [
                ForceCurveConfidencePoint(
                    windowSeconds: 1, kilograms: 44.2, lowKilograms: 40.1, highKilograms: 48
                ),
                ForceCurveConfidencePoint(
                    windowSeconds: 3, kilograms: 38.5, lowKilograms: 34.9, highKilograms: 42.4
                ),
                ForceCurveConfidencePoint(
                    windowSeconds: 7, kilograms: 33.1, lowKilograms: 29.8, highKilograms: 36.6
                ),
                ForceCurveConfidencePoint(
                    windowSeconds: 15, kilograms: 29.8, lowKilograms: 26.6, highKilograms: 33.1
                ),
                ForceCurveConfidencePoint(
                    windowSeconds: 30, kilograms: 27.4, lowKilograms: 24.3, highKilograms: 30.6
                ),
                ForceCurveConfidencePoint(
                    windowSeconds: 60, kilograms: 25.9, lowKilograms: 22.9, highKilograms: 29
                ),
                ForceCurveConfidencePoint(
                    windowSeconds: 120, kilograms: 24.8, lowKilograms: 21.9, highKilograms: 27.8
                )
            ]
        )
    }

    private static func fixtureTargetBand() -> ForceTargetBand {
        ForceTargetBand(kilograms: 30, lowKilograms: 27, highKilograms: 33)
    }
}
