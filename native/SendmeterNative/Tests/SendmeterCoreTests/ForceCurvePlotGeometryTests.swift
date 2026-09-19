import XCTest
@testable import SendmeterCore

/// #928 AC4: the axis-typography slice must not move a single data
/// coordinate. Every pinned number below was measured at the lane's base
/// (`a5e9868`) by running the pre-change inline Canvas formulas verbatim in a
/// standalone Swift process (log `/tmp/impl928-golden-base-measure.log`), so a
/// drift in the log-x window, the y-maximum, the band values or the fraction
/// mappings fails here instead of shipping a silently rescaled curve.
final class ForceCurvePlotGeometryTests: XCTestCase {
    func testGoldenWindowAndYMaximum() {
        let geometry = Self.fixtureGeometry()

        XCTAssertEqual(geometry.minimumSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(geometry.maximumSeconds, 120, accuracy: 1e-9)
        XCTAssertEqual(geometry.maximumValue, 52.8, accuracy: 1e-9)
    }

    func testGoldenXFractionsForTheAdmittedTicks() {
        let geometry = Self.fixtureGeometry()

        XCTAssertEqual(geometry.xFraction(seconds: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.xFraction(seconds: 10), 0.48095855130519705, accuracy: 1e-9)
        XCTAssertEqual(geometry.xFraction(seconds: 60), 0.8552170493860419, accuracy: 1e-9)
        XCTAssertEqual(geometry.xFraction(seconds: 120), 1, accuracy: 1e-9)
        XCTAssertEqual(
            geometry.xFraction(seconds: 0.1),
            0,
            accuracy: 1e-9,
            "a duration below the window clamps to its left edge"
        )
        XCTAssertEqual(
            geometry.xFraction(seconds: 600),
            1.3361756006912389,
            accuracy: 1e-9,
            """
            faithful extraction: the pre-change formula clamps the window's left \
            edge only. The Canvas admits in-window ticks and the tooltip's own \
            mapping (ForceCurveSelection.xFraction) clamps, so this end is only \
            reachable if a caller feeds it an out-of-window duration.
            """
        )
    }

    func testGoldenYFractionsForTheBandAndMeasuredValues() {
        let geometry = Self.fixtureGeometry()

        XCTAssertEqual(geometry.yFraction(kilograms: 48), 0.9090909090909091, accuracy: 1e-9)
        XCTAssertEqual(geometry.yFraction(kilograms: 44.2), 0.8371212121212122, accuracy: 1e-9)
        XCTAssertEqual(geometry.yFraction(kilograms: 24.8), 0.46969696969696967, accuracy: 1e-9)
        XCTAssertEqual(geometry.yFraction(kilograms: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(
            geometry.yFraction(kilograms: -5),
            0,
            accuracy: 1e-9,
            "negative force stays on the baseline"
        )
    }

    func testShortWindowKeepsTheTenSecondFloor() {
        let geometry = ForceCurvePlotGeometry(
            model: ForceCurveModel(
                points: [
                    ForceCurvePoint(windowSeconds: 2, kilograms: 30),
                    ForceCurvePoint(windowSeconds: 8, kilograms: 20)
                ],
                maximumForceKilograms: 30,
                criticalForceKilograms: nil,
                impulseAboveCriticalForceKilogramSeconds: nil,
                capabilityFit: nil
            ),
            targetBand: nil
        )

        XCTAssertEqual(geometry.minimumSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(geometry.maximumSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(geometry.maximumValue, 33, accuracy: 1e-9)
        XCTAssertEqual(geometry.xFraction(seconds: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.xFraction(seconds: 8), 0.861353116146786, accuracy: 1e-9)
        XCTAssertEqual(geometry.xFraction(seconds: 10), 1, accuracy: 1e-9)
    }

    func testMissingBandAndTargetKeepTheTenKilogramFloor() {
        let geometry = ForceCurvePlotGeometry(
            model: ForceCurveModel(
                points: [ForceCurvePoint(windowSeconds: 1, kilograms: 6)],
                maximumForceKilograms: 6,
                criticalForceKilograms: nil,
                impulseAboveCriticalForceKilogramSeconds: nil,
                capabilityFit: nil
            ),
            targetBand: nil
        )

        XCTAssertEqual(
            geometry.maximumValue,
            11,
            accuracy: 1e-9,
            "the 10 kg floor and the 1.1 headroom are unchanged"
        )
        XCTAssertEqual(geometry.yFraction(kilograms: 6), 6.0 / 11.0, accuracy: 1e-9)
    }

    func testTheHighestBandEdgeAndTargetStillSetTheYMaximum() {
        let geometry = Self.fixtureGeometry()

        // The fixture's highest confidence-band edge is 48 kg, above both the
        // 46.3 kg measured maximum and the 33 kg target edge.
        XCTAssertEqual(geometry.maximumValue, 48 * 1.1, accuracy: 1e-9)

        let targetOnly = ForceCurvePlotGeometry(
            model: ForceCurveModel(
                points: [ForceCurvePoint(windowSeconds: 1, kilograms: 20)],
                maximumForceKilograms: 20,
                criticalForceKilograms: nil,
                impulseAboveCriticalForceKilogramSeconds: nil,
                capabilityFit: nil
            ),
            targetBand: ForceTargetBand(kilograms: 30, lowKilograms: 27, highKilograms: 36)
        )
        XCTAssertEqual(
            targetOnly.maximumValue,
            36 * 1.1,
            accuracy: 1e-9,
            "the plan target's upper edge still scales the y axis"
        )
    }

    // MARK: - Helpers

    private static func fixtureGeometry() -> ForceCurvePlotGeometry {
        ForceCurvePlotGeometry(model: fixtureModel(), targetBand: fixtureTargetBand())
    }

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
