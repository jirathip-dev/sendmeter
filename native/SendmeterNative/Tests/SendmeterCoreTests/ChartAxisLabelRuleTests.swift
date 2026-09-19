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

    // MARK: - Flexible equal-width columns (the Training Load weekly bars, #929)

    /// The Training Load sheet's weekly-bar geometry: four flexible columns in
    /// the 311 pt the smallest phone's card leaves (375 − 2 × 16 sheet padding
    /// − 2 × 16 card padding), 8 pt apart — the same slots
    /// `TrainingLoadInteraction.weeklyBarIndex` hit-tests a finger against.
    private static let weeklyBarsWidth: CGFloat = 375 - 4 * 16
    private static let weeklyBarSpacing: CGFloat = CGFloat(TrainingLoadInteraction.weeklyBarSpacing)
    private static let weeklyValueLabels = ["630", "1,050", "600", "1,232"]
    private static let weeklyWeekLabels = ["3w", "2w", "1w", "Now"]

    func testColumnCentresMatchTheBarHitTestSlots() {
        let centers = ChartAxisLabelRule.columnCenters(
            width: Self.weeklyBarsWidth,
            count: Self.weeklyValueLabels.count,
            spacing: Self.weeklyBarSpacing
        )
        XCTAssertEqual(centers.count, Self.weeklyValueLabels.count)
        for (index, center) in centers.enumerated() {
            XCTAssertEqual(
                TrainingLoadInteraction.weeklyBarIndex(
                    x: Double(center),
                    width: Double(Self.weeklyBarsWidth),
                    count: Self.weeklyValueLabels.count
                ),
                index,
                "the label centred on slot \(index) must belong to the bar that point selects"
            )
        }
        let columnWidth = (Self.weeklyBarsWidth - 3 * Self.weeklyBarSpacing) / 4
        XCTAssertEqual(centers.first ?? 0, columnWidth / 2, accuracy: 0.0001)
        XCTAssertEqual(centers.last ?? 0, Self.weeklyBarsWidth - columnWidth / 2, accuracy: 0.0001)
    }

    func testColumnPlanKeepsEveryWeeklyLabelAtTheDefaultSize() {
        let values = ChartAxisLabelRule.columnLabelPlan(
            labels: Self.weeklyValueLabels,
            width: Self.weeklyBarsWidth,
            spacing: Self.weeklyBarSpacing,
            pointSize: ChartAxisLabelRule.basePointSize
        )
        XCTAssertEqual(
            values.labelledIndices,
            Array(Self.weeklyValueLabels.indices),
            "the default text size keeps every weekly value label"
        )
        XCTAssertEqual(values.columnWidth, 71.75, accuracy: 0.0001, "311 − 3 × 8, over four columns")
        let weeks = ChartAxisLabelRule.columnLabelPlan(
            labels: Self.weeklyWeekLabels,
            width: Self.weeklyBarsWidth,
            spacing: Self.weeklyBarSpacing,
            pointSize: ChartAxisLabelRule.basePointSize
        )
        XCTAssertEqual(weeks.labelledIndices, Array(Self.weeklyWeekLabels.indices))
    }

    func testAccessibilitySizesThinTheWeeklyLabelsInsteadOfClippingThem() {
        let pointSize = Self.accessibilityPointSize
        let values = ChartAxisLabelRule.columnLabelPlan(
            labels: Self.weeklyValueLabels,
            width: Self.weeklyBarsWidth,
            spacing: Self.weeklyBarSpacing,
            pointSize: pointSize
        )
        XCTAssertTrue(
            values.labelledIndices.isEmpty,
            "no 3-character AU total fits a 72 pt column at 40.5 pt — the row is "
                + "omitted (the sheet keeps the exact values readable below the chart) "
                + "instead of overhanging the neighbouring bar or the card"
        )
        let weeks = ChartAxisLabelRule.columnLabelPlan(
            labels: Self.weeklyWeekLabels,
            width: Self.weeklyBarsWidth,
            spacing: Self.weeklyBarSpacing,
            pointSize: pointSize
        )
        XCTAssertEqual(
            weeks.labelledIndices,
            [0, 1, 2],
            "the 2-character week captions survive at 40.5 pt; the 3-character "
                + "'Now' no longer fits its column and is omitted"
        )
    }

    func testEveryDrawnColumnLabelStaysInsideItsColumnAndClearsItsNeighbour() {
        for pointSize in stride(from: ChartAxisLabelRule.basePointSize, through: Self.accessibilityPointSize, by: 1) {
            for labels in [Self.weeklyValueLabels, Self.weeklyWeekLabels] {
                let plan = ChartAxisLabelRule.columnLabelPlan(
                    labels: labels,
                    width: Self.weeklyBarsWidth,
                    spacing: Self.weeklyBarSpacing,
                    pointSize: pointSize
                )
                func width(_ index: Int) -> CGFloat {
                    ChartAxisLabelRule.estimatedLabelWidth(labels[index], pointSize: pointSize)
                }
                for index in plan.labelledIndices {
                    XCTAssertLessThanOrEqual(
                        width(index) / 2,
                        plan.columnWidth / 2,
                        "a drawn label must fit inside its own column at \(pointSize) pt"
                    )
                    XCTAssertGreaterThanOrEqual(plan.centers[index] - width(index) / 2, 0)
                    XCTAssertLessThanOrEqual(plan.centers[index] + width(index) / 2, Self.weeklyBarsWidth)
                }
                for (previous, next) in zip(plan.labelledIndices, plan.labelledIndices.dropFirst()) {
                    let clearance = plan.centers[next] - plan.centers[previous]
                        - (width(previous) + width(next)) / 2
                    XCTAssertGreaterThanOrEqual(
                        clearance,
                        ChartAxisLabelRule.minimumGap - 0.0001,
                        "labels at \(pointSize) pt must not collide"
                    )
                }
            }
        }
    }

    func testColumnPlanHandlesDegenerateInputs() {
        XCTAssertEqual(
            ChartAxisLabelRule.columnLabelPlan(labels: ["1"], width: 0, spacing: 8, pointSize: 11).labelledIndices,
            [],
            "a zero-width chart labels nothing instead of dividing by zero"
        )
        XCTAssertEqual(ChartAxisLabelRule.columnCenters(width: 311, count: 0, spacing: 8), [])
        XCTAssertEqual(
            ChartAxisLabelRule.columnLabelPlan(labels: [], width: 311, spacing: 8, pointSize: 11).labelledIndices,
            []
        )
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
