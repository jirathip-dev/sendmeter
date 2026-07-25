import XCTest
import SendLogWatchCore

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

    // MARK: Manual attempts (Boulder/Stop button)

    /// A manually-logged boulder is recorded with source .manual and real HR
    /// metrics, even with little altitude gain (exempt from the auto filters).
    func testManualAttemptLogged() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<5 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        d.beginManualAttempt(at: start.addingTimeInterval(5))
        XCTAssertTrue(d.isManualAttemptOpen)
        for i in 5..<15 { // low-angle traverse: barely any altitude change
            d.ingest(MotionSample(t: Double(i), altitude: 0.3, motionRMS: 0.2, hr: 150), at: start.addingTimeInterval(Double(i)))
        }
        d.endManualAttempt(at: start.addingTimeInterval(15))
        XCTAssertFalse(d.isManualAttemptOpen)
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].source, .manual)
        XCTAssertNotNil(attempts[0].peakHR)
    }

    /// While a manual attempt is open, a big altitude rise does NOT spawn a
    /// separate auto attempt — auto detection is suspended.
    func testManualSuppressesAuto() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<5 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        d.beginManualAttempt(at: start.addingTimeInterval(5))
        for i in 5..<20 { // a rise that would normally auto-trigger
            d.ingest(MotionSample(t: Double(i), altitude: Double(i - 5) * 0.5, motionRMS: 0.2, hr: 150), at: start.addingTimeInterval(Double(i)))
        }
        d.endManualAttempt(at: start.addingTimeInterval(20))
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 1, "manual window must not also produce an auto attempt")
        XCTAssertEqual(attempts[0].source, .manual)
    }

    /// Opening a manual attempt while an auto attempt is in progress closes
    /// and keeps the auto one first (both survive, no overlap).
    func testManualClosesOpenAuto() {
        let d = AttemptDetector(tunables: .default)
        var t: [(Double, Double, Double?)] = []
        t += Array(repeating: (0.0, 0.02, 80.0), count: 30)
        for i in 0..<12 { t.append((Double(i) * 0.25, 0.15, 120)) } // auto climb to +3m
        t += Array(repeating: (3.0, 0.12, 130.0), count: 10)         // still up when we tap
        for (i, s) in t.enumerated() {
            d.ingest(MotionSample(t: Double(i), altitude: s.0, motionRMS: s.1, hr: s.2), at: start.addingTimeInterval(Double(i)))
        }
        d.beginManualAttempt(at: start.addingTimeInterval(Double(t.count)))
        for i in t.count..<(t.count + 10) {
            d.ingest(MotionSample(t: Double(i), altitude: 3.0, motionRMS: 0.2, hr: 150), at: start.addingTimeInterval(Double(i)))
        }
        d.endManualAttempt(at: start.addingTimeInterval(Double(t.count + 10)))
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.filter { $0.source == .auto }.count, 1)
        XCTAssertEqual(attempts.filter { $0.source == .manual }.count, 1)
    }

    func testPredictRPEBounds() {
        let rpe = AttemptDetector.predictRPE(attempts: [], avgHR: nil, durationS: 3600, tunables: .default)
        XCTAssertGreaterThanOrEqual(rpe, 1)
        XCTAssertLessThanOrEqual(rpe, 10)

        let hard = AttemptDetector.predictRPE(
            attempts: (0..<30).map { _ in
                Attempt(startedAt: start, durationS: 60, elevationGainM: 4, avgHR: 165, peakHR: 185, motionIntensity: 0.2, effortScore: 9, source: .auto)
            },
            avgHR: 165,
            durationS: 3600,
            tunables: .default
        )
        XCTAssertGreaterThan(hard, 7)
        XCTAssertLessThanOrEqual(hard, 10)
    }
}
