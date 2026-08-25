import Foundation
import XCTest
import SendmeterCore

/// Cross-pinning fixture for the readiness/ACWR math shared with the web
/// (src/lib/metrics.ts), the health core (native-plugins/sendlog-health-core)
/// and the watch (ios/App/SendLogWatchCore). Same bytes as
/// src/lib/readinessAcwrParity.test.ts and the other two Swift suites; a
/// drift in any implementation's numbers fails the suite that owns it.
final class ReadinessAcwrParityTests: XCTestCase {
    private struct Spans: Decodable {
        let acuteDays: Int
        let chronicDays: Int
        let lookbackDays: Int
        let readinessRecoverBelow: Int
        let readinessPushAbove: Int
    }
    private struct AcwrStatusVector: Decodable {
        let id: String
        let ratio: Double?
        let status: String
    }
    private struct AcwrRatioVector: Decodable {
        let id: String
        let dailyLoads: [Double]
        let expected: Double?
    }
    private struct Fixture: Decodable {
        let spans: Spans
        let acwrStatus: [AcwrStatusVector]
        let acwrRatio: [AcwrRatioVector]
    }

    private static let fixture: Fixture = {
        guard let url = Bundle.module.url(
            forResource: "readiness-acwr-parity",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            fatalError("Missing shared readiness-acwr-parity.json test resource")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Invalid readiness/ACWR parity fixture: \(error)")
        }
    }()

    private static let ratioTolerance = 1e-9

    func testSpansMatchFixture() {
        XCTAssertEqual(TrainingMetrics.acuteSpanDays, Self.fixture.spans.acuteDays)
        XCTAssertEqual(TrainingMetrics.chronicSpanDays, Self.fixture.spans.chronicDays)
        XCTAssertEqual(TrainingMetrics.ewmaLookbackDays, Self.fixture.spans.lookbackDays)
    }

    func testAcwrRatioMatchesSharedVectors() {
        for vector in Self.fixture.acwrRatio {
            let ratio = TrainingMetrics.acwrRatio(dailyLoads: vector.dailyLoads)
            if let expected = vector.expected {
                guard let ratio else {
                    XCTFail("\(vector.id): expected \(expected), got nil")
                    continue
                }
                XCTAssertEqual(ratio, expected, accuracy: Self.ratioTolerance, vector.id)
            } else {
                XCTAssertNil(ratio, "\(vector.id): expected nil, got \(String(describing: ratio))")
            }
        }
    }

    func testStatusVectorsMatchProductContract() {
        for vector in Self.fixture.acwrStatus {
            let status = TrainingMetrics.acwrStatus(vector.ratio)
            XCTAssertEqual(status, expectedStatus(for: vector.status), vector.id)
        }
    }

    private func expectedStatus(for fixture: String) -> ACWRStatus {
        switch fixture {
        case "noData": return .noData
        case "underTraining": return .underTraining
        case "low": return .low
        case "optimal": return .optimal
        case "caution": return .caution
        case "danger": return .danger
        default:
            XCTFail("Unknown fixture status \(fixture)")
            return .noData
        }
    }
}
