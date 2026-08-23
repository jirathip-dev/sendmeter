import XCTest
@testable import SendmeterCore

final class ForceCurveSelectionTests: XCTestCase {
    func testHalfFractionIsTheGeometricMidpoint() {
        XCTAssertEqual(
            ForceCurveSelection.seconds(atXFraction: 0.5, firstSeconds: 1, lastSeconds: 100) ?? 0,
            10,
            accuracy: 0.0001
        )
    }

    func testFractionAndInverseRoundTripThroughLogSpace() {
        let points: [ForceCurvePoint] = [
            ForceCurvePoint(windowSeconds: 1, kilograms: 100),
            ForceCurvePoint(windowSeconds: 10, kilograms: 80),
            ForceCurvePoint(windowSeconds: 100, kilograms: 70)
        ]
        for point in points {
            let fraction = ForceCurveSelection.xFraction(
                forSeconds: point.windowSeconds,
                firstSeconds: 1,
                lastSeconds: 100
            )
            let restored = fraction.flatMap {
                ForceCurveSelection.seconds(atXFraction: $0, firstSeconds: 1, lastSeconds: 100)
            }
            XCTAssertEqual(restored ?? 0, point.windowSeconds, accuracy: 0.0001)
        }
    }

    func testNearestPointUsesLogSpaceAcrossTheWholeCurve() {
        let points: [ForceCurvePoint] = [
            ForceCurvePoint(windowSeconds: 1, kilograms: 100),
            ForceCurvePoint(windowSeconds: 10, kilograms: 80),
            ForceCurvePoint(windowSeconds: 100, kilograms: 70)
        ]
        XCTAssertEqual(ForceCurveSelection.nearestPointIndex(points: points, toSeconds: 2), 0)
        XCTAssertEqual(ForceCurveSelection.nearestPointIndex(points: points, toSeconds: 8), 1)
        XCTAssertEqual(ForceCurveSelection.nearestPointIndex(points: points, toSeconds: 50), 2)
    }

    func testNearestPointSkipsInvalidAndRejectsNoValidInput() {
        let points: [ForceCurvePoint] = [
            ForceCurvePoint(windowSeconds: 0, kilograms: 100),
            ForceCurvePoint(windowSeconds: 10, kilograms: 80)
        ]
        XCTAssertEqual(ForceCurveSelection.nearestPointIndex(points: points, toSeconds: 1), 1)
        XCTAssertNil(ForceCurveSelection.nearestPointIndex(points: [ForceCurvePoint(windowSeconds: 0, kilograms: 100)], toSeconds: 1))
        XCTAssertNil(ForceCurveSelection.nearestPointIndex(points: [], toSeconds: 1))
        XCTAssertNil(ForceCurveSelection.nearestPointIndex(points: points, toSeconds: 0))
    }

    func testFractionClampsOutsideDomain() {
        XCTAssertEqual(
            ForceCurveSelection.xFraction(forSeconds: 200, firstSeconds: 1, lastSeconds: 100),
            1
        )
        XCTAssertEqual(
            ForceCurveSelection.seconds(atXFraction: -1, firstSeconds: 1, lastSeconds: 100) ?? 0,
            1,
            accuracy: 0.0001
        )
    }
}
