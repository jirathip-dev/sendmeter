import XCTest
@testable import SendmeterCore

final class AcwrStatusCardTests: XCTestCase {
    private let capacity = PhaseCatalog.definition(for: .capacity)

    // MARK: - Band geometry

    func testBandEdgesMatchThresholdsOnZeroToTwoScale() {
        XCTAssertEqual(AcwrStatusCard.thresholds, [0.8, 1.3, 1.5])
        assertClose(
            AcwrStatusCard.bandEdgeFractions,
            [0.40, 0.65, 0.75]
        )
    }

    func testBandEdgesAreThresholdOverScale() {
        for (edge, threshold) in zip(AcwrStatusCard.bandEdgeFractions, AcwrStatusCard.thresholds) {
            XCTAssertEqual(edge, threshold / AcwrStatusCard.trackScale, accuracy: 0.000_001)
        }
    }

    func testGradientStopsAreTheWebBlend() {
        // The web ACWR_TRACK_GRADIENT stops — 0/0.32/0.48/0.58/0.72/0.78/1.0.
        // A hard stop at each threshold would collapse the blend; the native
        // port preserves the symmetric blend so the midpoint lands on the edge.
        let fractions = AcwrStatusCard.gradientStops.map(\.fraction)
        assertClose(
            fractions,
            [0.0, 0.32, 0.48, 0.58, 0.72, 0.78, 1.0]
        )
        let bands = AcwrStatusCard.gradientStops.map(\.band)
        XCTAssertEqual(bands, [
            .low, .low,
            .optimal, .optimal,
            .caution,
            .danger, .danger
        ])
    }

    func testEachBandEdgeIsTheBlendMidpoint() {
        // Midpoint of the stops around each threshold equals the band edge.
        let pairs: [(Double, Double)] = [
            (0.32, 0.48),
            (0.58, 0.72),
            (0.72, 0.78)
        ]
        for (edge, (a, b)) in zip(AcwrStatusCard.bandEdgeFractions, pairs) {
            XCTAssertEqual(edge, (a + b) / 2.0, accuracy: 0.000_001)
        }
    }

    // MARK: - Ticks

    func testTicksAreAtTrueScaleFractions() {
        XCTAssertEqual(AcwrStatusCard.ticks.map(\.value), [0, 1.0, 1.5, 2])
        XCTAssertEqual(AcwrStatusCard.ticks.map(\.label), ["0", "1.0", "1.5", "2"])
        assertClose(
            AcwrStatusCard.ticks.map(\.fraction),
            [0.0, 0.5, 0.75, 1.0]
        )
    }

    // MARK: - Marker

    func testMarkerFractionIsRatioOverScale() throws {
        XCTAssertEqual(try XCTUnwrap(AcwrStatusCard.markerFraction(0.8)), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AcwrStatusCard.markerFraction(1.0)), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AcwrStatusCard.markerFraction(1.5)), 0.75, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AcwrStatusCard.markerFraction(2.0)), 1.0, accuracy: 0.000_001)
    }

    func testMarkerFractionClampsToTrack() throws {
        XCTAssertEqual(try XCTUnwrap(AcwrStatusCard.markerFraction(-0.5)), 0.0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AcwrStatusCard.markerFraction(0)), 0.0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AcwrStatusCard.markerFraction(5.0)), 1.0, accuracy: 0.000_001)
    }

    func testMarkerFractionIsNilWhenNoRatio() {
        XCTAssertNil(AcwrStatusCard.markerFraction(nil))
    }

    // MARK: - Nil / no-data state

    func testNilRatioReadsAsNoData() {
        XCTAssertEqual(TrainingMetrics.acwrStatus(nil), .noData)
        XCTAssertNil(AcwrStatusCard.markerFraction(nil))
        XCTAssertNil(AcwrStatusCard.phaseFitLine(ratio: nil, phase: capacity))
    }

    func testNilExplainerDistinguishesCauses() {
        XCTAssertEqual(
            AcwrStatusCard.nilExplainer(hasLoadedSessions: false, hasSessions: false),
            "Your training history is still loading."
        )
        XCTAssertEqual(
            AcwrStatusCard.nilExplainer(hasLoadedSessions: true, hasSessions: false),
            "Log a few sessions to see your ACWR."
        )
        XCTAssertEqual(
            AcwrStatusCard.nilExplainer(hasLoadedSessions: true, hasSessions: true),
            "There isn't enough training load in your recent 90 days to compute an ACWR ratio yet."
        )
    }

    func testAccessibilitySummaryNilRatioReadsSingleNoData() {
        // #748 round 2 finding 5: one "No data." — never "No data. No data."
        XCTAssertEqual(
            AcwrStatusCard.accessibilitySummary(
                ratio: nil,
                acute: 12,
                chronic: 34,
                phase: capacity
            ),
            "No data. Acute 7d 12. Chronic avg 34."
        )
    }

    func testAccessibilitySummaryWithRatioCombinesFields() {
        XCTAssertEqual(
            AcwrStatusCard.accessibilitySummary(
                ratio: 1.0,
                acute: 12,
                chronic: 34,
                phase: capacity
            ),
            "1.00. Optimal. On target for Capacity. Acute 7d 12. Chronic avg 34."
        )
        XCTAssertEqual(
            AcwrStatusCard.accessibilitySummary(
                ratio: 0.5,
                acute: 12,
                chronic: 34,
                phase: capacity
            ),
            "0.50. Under-training. Below Capacity target (0.9–1.1). Acute 7d 12. Chronic avg 34."
        )
    }

    // MARK: - Phase-fit copy

    func testPhaseFitLineOnTarget() {
        // Capacity band is 0.9–1.1; a ratio inside it reads "On target".
        XCTAssertEqual(
            AcwrStatusCard.phaseFitLine(ratio: 1.0, phase: capacity),
            "On target for Capacity"
        )
    }

    func testPhaseFitLineBelowAndAboveUseBandText() {
        XCTAssertEqual(
            AcwrStatusCard.phaseFitLine(ratio: 0.5, phase: capacity),
            "Below Capacity target (0.9–1.1)"
        )
        XCTAssertEqual(
            AcwrStatusCard.phaseFitLine(ratio: 1.5, phase: capacity),
            "Above Capacity target (0.9–1.1)"
        )
    }

    func testPhaseFitLineIsNilWithoutPhase() {
        XCTAssertNil(AcwrStatusCard.phaseFitLine(ratio: 1.0, phase: nil))
    }

    /// XCTest has no `accuracy:` overload for arrays, so compare element-wise.
    private func assertClose(
        _ actual: [Double],
        _ expected: [Double],
        accuracy: Double = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (x, y) in zip(actual, expected) {
            XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
        }
    }
}
