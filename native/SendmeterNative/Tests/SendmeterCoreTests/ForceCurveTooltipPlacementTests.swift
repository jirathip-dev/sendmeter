import XCTest
@testable import SendmeterCore

/// #928 AC3: the #755 scrub/tap tooltip keeps its measured, clamped
/// placement. The clamp moved from the view's private helpers into
/// `ForceCurveTooltipPlacement` unchanged; the pinned numbers were measured at
/// the lane's base (`a5e9868`) by running the pre-change helpers verbatim in a
/// standalone Swift process (log
/// `/tmp/impl928-tooltip-base-measure.log`).
final class ForceCurveTooltipPlacementTests: XCTestCase {
    /// The fixture curve's plot rect at the smallest supported phone width and
    /// the default text size (32 pt leading / 15.64 pt trailing / 8.875 pt
    /// top / 20 pt bottom insets inside a 190 pt-tall Canvas).
    private static let plotFrame = CGRect(x: 32, y: 8.875, width: 263.36, height: 161.125)

    func testGoldenClampKeepsTheMeasuredTooltipInsideThePlot() {
        XCTAssertEqual(
            ForceCurveTooltipPlacement.x(
                anchor: 32,
                plotFrame: Self.plotFrame,
                tooltipWidth: 96
            ),
            88,
            accuracy: 0.0001,
            "an anchor at the left edge clamps to half the measured tooltip plus 8 pt"
        )
        XCTAssertEqual(
            ForceCurveTooltipPlacement.x(
                anchor: 158.66,
                plotFrame: Self.plotFrame,
                tooltipWidth: 96
            ),
            158.66,
            accuracy: 0.0001,
            "an anchor inside the clamp range is not moved"
        )
        XCTAssertEqual(
            ForceCurveTooltipPlacement.x(
                anchor: 500,
                plotFrame: Self.plotFrame,
                tooltipWidth: 96
            ),
            239.36,
            accuracy: 0.0001,
            "an anchor past the right edge clamps to the plot's right edge"
        )
        XCTAssertEqual(
            ForceCurveTooltipPlacement.y(
                plotFrame: Self.plotFrame,
                tooltipHeight: 58
            ),
            41.875,
            accuracy: 0.0001,
            "the shipped placement pins the tooltip to the top of the plot"
        )
    }

    func testGoldenFallbacksBeforeTheFirstMeasurement() {
        XCTAssertEqual(
            ForceCurveTooltipPlacement.x(
                anchor: 0,
                plotFrame: Self.plotFrame,
                tooltipWidth: 0
            ),
            85,
            accuracy: 0.0001,
            "a zero measurement uses the shipped 90 pt width"
        )
        XCTAssertEqual(
            ForceCurveTooltipPlacement.y(
                plotFrame: Self.plotFrame,
                tooltipHeight: 0
            ),
            42.875,
            accuracy: 0.0001,
            "a zero measurement uses the shipped 60 pt height"
        )
    }

    func testTooltipWiderThanThePlotFallsBackToThePlotCentre() {
        let tight = CGRect(x: 0, y: 0, width: 60, height: 40)

        XCTAssertEqual(
            ForceCurveTooltipPlacement.x(anchor: 10, plotFrame: tight, tooltipWidth: 90),
            tight.midX,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ForceCurveTooltipPlacement.y(plotFrame: tight, tooltipHeight: 60),
            tight.midY,
            accuracy: 0.0001
        )
    }

    func testClampedTooltipStaysInsideEveryPlotRectTheCardsCanProduce() {
        let tooltipWidth: CGFloat = 96
        let tooltipHeight: CGFloat = 58
        for width in stride(from: CGFloat(140), through: CGFloat(320), by: CGFloat(10)) {
            for leading in stride(from: CGFloat(32), through: CGFloat(56), by: CGFloat(6)) {
                let plotFrame = CGRect(x: leading, y: 8.875, width: width, height: 161.125)
                for anchor in stride(from: CGFloat(0), through: width + 40, by: CGFloat(12)) {
                    let center = ForceCurveTooltipPlacement.x(
                        anchor: plotFrame.minX + anchor,
                        plotFrame: plotFrame,
                        tooltipWidth: tooltipWidth
                    )
                    XCTAssertGreaterThanOrEqual(center - tooltipWidth / 2, plotFrame.minX)
                    XCTAssertLessThanOrEqual(center + tooltipWidth / 2, plotFrame.maxX)
                }
                let centerY = ForceCurveTooltipPlacement.y(
                    plotFrame: plotFrame,
                    tooltipHeight: tooltipHeight
                )
                XCTAssertGreaterThanOrEqual(centerY - tooltipHeight / 2, plotFrame.minY)
                XCTAssertLessThanOrEqual(centerY + tooltipHeight / 2, plotFrame.maxY)
            }
        }
    }
}
