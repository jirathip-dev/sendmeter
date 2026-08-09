import Foundation
import XCTest
@testable import SendLogWatchCore

final class MovementSetMetricsTests: XCTestCase {
    func testFlatCompleteTargetedSet() {
        let metrics = movementSetMetrics(
            samples: [
                MovementSample(tMs: 0, kg: 20),
                MovementSample(tMs: 2_500, kg: 20),
                MovementSample(tMs: 5_000, kg: 20),
                MovementSample(tMs: 7_500, kg: 20),
                MovementSample(tMs: 10_000, kg: 20),
            ],
            band: MovementTargetBand(kg: 20, lowKg: 18, highKg: 22),
            plannedDurationMs: 10_000
        )

        XCTAssertEqual(metrics.meanKg, 20)
        XCTAssertEqual(metrics.coefficientVariationPct, 0)
        XCTAssertEqual(metrics.inTargetPct, 100)
        XCTAssertEqual(metrics.timeUnderTensionMs, 10_000)
        XCTAssertEqual(metrics.driftPct, 0)
        XCTAssertEqual(metrics.cadenceAdherencePct, 100)
    }

    func testIrregularTraceIsTimeWeightedAndExcludesUnloadedTime() {
        let metrics = movementSetMetrics(
            samples: [
                MovementSample(tMs: 0, kg: 0),
                MovementSample(tMs: 1_000, kg: 0),
                MovementSample(tMs: 2_000, kg: 10),
                MovementSample(tMs: 5_000, kg: 10),
                MovementSample(tMs: 8_000, kg: 15),
                MovementSample(tMs: 10_000, kg: 15),
            ],
            band: MovementTargetBand(kg: 12, lowKg: 9, highKg: 13),
            plannedDurationMs: 10_000
        )

        XCTAssertEqual(metrics.timeUnderTensionMs, 9_000)
        XCTAssertEqual(metrics.meanKg, 11.39)
        XCTAssertEqual(metrics.inTargetPct, 66.7)
        XCTAssertEqual(metrics.driftPct, 200)
        XCTAssertEqual(metrics.cadenceAdherencePct, 100)
    }

    func testTargetFreeEarlyStopKeepsAccuracyUnknown() {
        let metrics = movementSetMetrics(
            samples: [
                MovementSample(tMs: 0, kg: 20),
                MovementSample(tMs: 5_000, kg: 20),
            ],
            band: nil,
            plannedDurationMs: 10_000
        )

        XCTAssertNil(metrics.inTargetPct)
        XCTAssertEqual(metrics.cadenceAdherencePct, 50)
    }

    func testStarterMarkersUseStoredOutReturnVocabulary() {
        let markers = WatchForceProtocol.movementStarter.cadenceMarkers(forSet: 2)
        XCTAssertEqual(markers.count, 20)
        XCTAssertEqual(markers[0], WatchCadenceMarker(tMs: 0, rep: 1, direction: .out))
        XCTAssertEqual(markers[1], WatchCadenceMarker(tMs: 3_000, rep: 1, direction: .return))
        XCTAssertEqual(markers[18], WatchCadenceMarker(tMs: 36_000, rep: 10, direction: .out))
        XCTAssertEqual(markers[19], WatchCadenceMarker(tMs: 39_000, rep: 10, direction: .return))
    }

    func testMetricsJSONMatchesWebFieldNames() throws {
        let metrics = MovementSetMetrics(
            meanKg: 12.5,
            coefficientVariationPct: 4.2,
            inTargetPct: nil,
            timeUnderTensionMs: 39_000,
            driftPct: -3.1,
            cadenceAdherencePct: 97.5
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: Any]
        )
        XCTAssertEqual(object["meanKg"] as? Double, 12.5)
        XCTAssertEqual(object["coefficientVariationPct"] as? Double, 4.2)
        XCTAssertTrue(object["inTargetPct"] is NSNull)
        XCTAssertEqual(object["timeUnderTensionMs"] as? Int, 39_000)
        XCTAssertEqual(object["driftPct"] as? Double, -3.1)
        XCTAssertEqual(object["cadenceAdherencePct"] as? Double, 97.5)
    }
}
