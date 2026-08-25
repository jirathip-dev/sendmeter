import Foundation
import XCTest
@testable import SendLogHealthCore

/// Cross-pinning fixture for the readiness/ACWR math shared with the web
/// (src/lib/metrics.ts), the watch (ios/App/SendLogWatchCore) and the native
/// app (native/SendmeterNative). The same bytes are consumed by:
///   - src/lib/readinessAcwrParity.test.ts
///   - ios/App/SendLogWatchCore/Tests/SendLogWatchCoreTests/ACWRTests.swift
///   - native/SendmeterNative/Tests/SendmeterCoreTests/MetricsTests.swift
/// This suite asserts the ACWR EWMA ratio and the readiness score/zone math
/// that live here in RecoveryEngine; a drift in any implementation's numbers
/// now fails the suite that owns it instead of shipping as a quiet mismatch.
final class ReadinessAcwrParityTests: XCTestCase {
    struct Spans: Decodable {
        let acuteDays: Int
        let chronicDays: Int
        let lookbackDays: Int
        let readinessRecoverBelow: Int
        let readinessPushAbove: Int
    }
    struct AcwrStatusVector: Decodable {
        let id: String
        let ratio: Double?
        let status: String
    }
    struct AcwrRatioVector: Decodable {
        let id: String
        let dailyLoads: [Double]
        let expected: Double?
    }
    struct ReadinessInputs: Decodable {
        let hrvSDNNms: Double?
        let restingHR: Double?
        let sleepHours: Double?
        let sleepDeepHours: Double?
        let sleepRemHours: Double?
        let respRateBpm: Double?
        let hrvLnBaseline: [Double]?
        let rhrBaseline: [Double]?
        let sleepBaseline: [Double]?
        let respBaseline: [Double]?
        let restorativeSleepBaseline: [Double]?

        func toDailyHealthInputs() -> DailyHealthInputs {
            DailyHealthInputs(
                hrvSDNNms: hrvSDNNms,
                restingHR: restingHR,
                sleepHours: sleepHours,
                bodyMassKg: nil,
                sleepDeepHours: sleepDeepHours,
                sleepRemHours: sleepRemHours,
                respRateBpm: respRateBpm,
                hrvLnBaseline: hrvLnBaseline ?? [],
                rhrBaseline: rhrBaseline ?? [],
                sleepBaseline: sleepBaseline ?? [],
                respBaseline: respBaseline ?? [],
                restorativeSleepBaseline: restorativeSleepBaseline ?? []
            )
        }
    }
    struct ReadinessVector: Decodable {
        let id: String
        let inputs: ReadinessInputs
        let acwr: Double?
        let expectedScore: Int?
        let expectedZone: String?
    }
    struct Fixture: Decodable {
        let spans: Spans
        let acwrStatus: [AcwrStatusVector]
        let acwrRatio: [AcwrRatioVector]
        let readiness: [ReadinessVector]
    }

    private static let fixture: Fixture = {
        guard let url = Bundle.module.url(
            forResource: "readiness-acwr-parity",
            withExtension: "json"
        ) else {
            fatalError("Missing shared readiness-acwr-parity.json test resource")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Invalid readiness/ACWR parity fixture: \(error)")
        }
    }()

    private static let tolerances = (ratio: 1e-9, score: 0.0)

    func testSpansMatchFixture() {
        XCTAssertEqual(Acwr.lookbackDays, Self.fixture.spans.lookbackDays)
        let t = RecoveryTunables.default
        XCTAssertEqual(t.zoneRecoverBelow, Self.fixture.spans.readinessRecoverBelow)
        XCTAssertEqual(t.zonePushAbove, Self.fixture.spans.readinessPushAbove)
        // The ACWR caution zone starts at 1.3 (fixture "above-1.3"); the
        // readiness engine's load penalty starts at the same boundary.
        XCTAssertEqual(t.acwrPenaltyStart, 1.3, accuracy: Self.tolerances.ratio)
        XCTAssertEqual(t.acwrPenaltyFull, 2.0, accuracy: Self.tolerances.ratio)
    }

    func testAcwrRatioMatchesSharedVectors() {
        for vector in Self.fixture.acwrRatio {
            let ratio = Acwr.ratio(dailyLoads: vector.dailyLoads)
            if let expected = vector.expected {
                guard let ratio else {
                    XCTFail("\(vector.id): expected \(expected), got nil")
                    continue
                }
                XCTAssertEqual(ratio, expected, accuracy: Self.tolerances.ratio, vector.id)
            } else {
                XCTAssertNil(ratio, "\(vector.id): expected nil, got \(String(describing: ratio))")
            }
        }
    }

    func testReadinessScoreAndZoneMatchSharedVectors() {
        for vector in Self.fixture.readiness {
            let result = RecoveryEngine.compute(
                inputs: vector.inputs.toDailyHealthInputs(),
                acwr: vector.acwr,
                t: .default
            )
            XCTAssertEqual(result.score, vector.expectedScore, vector.id)
            let expectedZone = ReadinessZone(rawValue: vector.expectedZone ?? "")
            XCTAssertEqual(result.zone, expectedZone, vector.id)
        }
    }
}
