import XCTest
@testable import SendLogWatch

final class AttemptDetectorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Feed a trace of (altitude, motionRMS, hr) at 1 Hz.
    private func run(_ trace: [(alt: Double, rms: Double, hr: Double?)]) -> [Attempt] {
        let detector = AttemptDetector(tunables: .default)
        for (i, s) in trace.enumerated() {
            detector.ingest(
                MotionSample(t: Double(i), altitude: s.alt, motionRMS: s.rms, hr: s.hr),
                at: start.addingTimeInterval(Double(i))
            )
        }
        return detector.finalize()
    }

    /// 30s rest → 25s climb to +3m → back down → 30s rest = exactly one attempt.
    func testSingleCleanAttempt() {
        var trace: [(Double, Double, Double?)] = []
        trace += Array(repeating: (0.0, 0.02, 80.0), count: 30)                 // rest
        for i in 0..<12 { trace.append((Double(i) * 0.25, 0.15, 110)) }          // climb to +3m
        trace += Array(repeating: (3.0, 0.12, 130.0), count: 13)                 // on the wall
        for i in 0..<6 { trace.append((3.0 - Double(i) * 0.5, 0.10, 140)) }      // down
        trace += Array(repeating: (0.0, 0.02, 120.0), count: 30)                 // rest
        let attempts = run(trace)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertGreaterThanOrEqual(attempts[0].elevationGainM, 2.5)
        XCTAssertGreaterThanOrEqual(attempts[0].durationS, 8)
        XCTAssertNotNil(attempts[0].peakHR)
    }

    /// Two climbs separated by only ~10s merge into one attempt.
    func testCloseAttemptsMerge() {
        var trace: [(Double, Double, Double?)] = []
        trace += Array(repeating: (0.0, 0.02, 80.0), count: 30)
        for i in 0..<10 { trace.append((Double(i) * 0.3, 0.15, 110)) }           // up to 2.7m
        trace += Array(repeating: (3.0, 0.12, 120.0), count: 8)
        for i in 0..<6 { trace.append((3.0 - Double(i) * 0.5, 0.10, 125)) }      // down
        trace += Array(repeating: (0.0, 0.06, 120.0), count: 8)                  // brief rest < mergeGap
        for i in 0..<10 { trace.append((Double(i) * 0.3, 0.15, 130)) }           // up again
        trace += Array(repeating: (3.0, 0.12, 140.0), count: 8)
        for i in 0..<6 { trace.append((3.0 - Double(i) * 0.5, 0.10, 140)) }
        trace += Array(repeating: (0.0, 0.02, 120.0), count: 30)
        let attempts = run(trace)
        XCTAssertEqual(attempts.count, 1, "attempts <15s apart should merge")
    }

    /// Walking around the gym (small altitude wiggle, moderate motion) = no attempts.
    func testWalkingNoiseRejected() {
        var trace: [(Double, Double, Double?)] = []
        for i in 0..<120 {
            let wiggle = 0.4 * sin(Double(i) / 5)
            trace.append((wiggle, 0.10, 95))
        }
        XCTAssertEqual(run(trace).count, 0)
    }

    /// Slow pressure drift (+3m over 10 min, no motion) = no attempts:
    /// the rest-only baseline EMA tracks it.
    func testPressureDriftRejected() {
        var trace: [(Double, Double, Double?)] = []
        for i in 0..<600 {
            trace.append((Double(i) * 0.005, 0.02, 75))
        }
        XCTAssertEqual(run(trace).count, 0)
    }

    /// Short hop (<8s, <1.2m) gets filtered.
    func testShortHopRejected() {
        var trace: [(Double, Double, Double?)] = []
        trace += Array(repeating: (0.0, 0.02, 80.0), count: 30)
        for i in 0..<3 { trace.append((Double(i) * 0.6, 0.15, 100)) }
        for i in 0..<3 { trace.append((1.8 - Double(i) * 0.6, 0.15, 100)) }
        trace += Array(repeating: (0.0, 0.02, 90.0), count: 30)
        XCTAssertEqual(run(trace).count, 0)
    }

    func testPredictRPEBounds() {
        let rpe = AttemptDetector.predictRPE(attempts: [], avgHR: nil, durationS: 3600, tunables: .default)
        XCTAssertGreaterThanOrEqual(rpe, 1)
        XCTAssertLessThanOrEqual(rpe, 10)

        let hard = AttemptDetector.predictRPE(
            attempts: (0..<30).map { _ in
                Attempt(startedAt: start, durationS: 60, elevationGainM: 4, avgHR: 165, peakHR: 185, motionIntensity: 0.2, effortScore: 9)
            },
            avgHR: 165,
            durationS: 3600,
            tunables: .default
        )
        XCTAssertGreaterThan(hard, 7)
        XCTAssertLessThanOrEqual(hard, 10)
    }
}
