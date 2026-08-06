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

    func testLowFortyFiveSecondClimbUsesAltitudeAndHRSupport() {
        var trace: [(Double, Double, Double?)] = []
        trace += Array(repeating: (-2.0, 0.02, 80.0), count: 30)
        for i in 0..<45 {
            trace.append((-2.0 + Double(i) / 44.0, 0.12, 80.0 + Double(i) * 0.8))
        }
        for i in 0..<8 { trace.append((-1.0 - Double(i) / 7.0, 0.10, 120)) }
        trace += Array(repeating: (-2.0, 0.02, 95.0), count: 12)
        let attempts = run(trace)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertGreaterThanOrEqual(attempts[0].elevationGainM, 0.9)
    }

    func testSlowClimbDoesNotNeedOldTenSecondGain() {
        var trace: [(Double, Double, Double?)] = []
        trace += Array(repeating: (0.0, 0.02, nil), count: 30)
        for i in 0..<50 { trace.append((Double(i) * 2.5 / 49.0, 0.13, nil)) }
        for i in 0..<10 { trace.append((2.5 - Double(i) * 0.25, 0.10, nil)) }
        trace += Array(repeating: (0.0, 0.02, nil), count: 12)
        XCTAssertEqual(run(trace).count, 1)
    }

    func testNegativeDriftStillUsesLocalFloor() {
        var trace: [(Double, Double, Double?)] = []
        for i in 0..<40 { trace.append((-5.0 - Double(i) * 0.01, 0.02, 80)) }
        let floor = trace.last!.0
        for i in 0..<30 { trace.append((floor + Double(i) * 1.4 / 29.0, 0.13, 105)) }
        for i in 0..<8 { trace.append((floor + 1.4 - Double(i) * 0.2, 0.10, 115)) }
        trace += Array(repeating: (floor, 0.02, 90), count: 12)
        let attempts = run(trace)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertGreaterThan(attempts[0].elevationGainM, 1.2)
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

    func testStableSnapshotExposesAutomaticOpenAndClose() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .resting)
        for i in 30..<50 {
            d.ingest(MotionSample(t: Double(i), altitude: Double(i - 30) * 0.08, motionRMS: 0.13, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .autoClimbing)
        XCTAssertNotNil(d.snapshot.phaseStartedAt)
        for i in 50..<58 {
            d.ingest(MotionSample(t: Double(i), altitude: max(0, 1.5 - Double(i - 50) * 0.25), motionRMS: 0.03, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        for i in 58..<68 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 95), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .resting)
    }

    func testAutoReturnToFloorClosesDespiteWalkingMotionExactlyOnce() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        for i in 30..<50 {
            d.ingest(MotionSample(t: Double(i), altitude: Double(i - 30) * 0.08, motionRMS: 0.13, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .autoClimbing)
        for i in 50..<58 {
            d.ingest(MotionSample(t: Double(i), altitude: max(0, 1.5 - Double(i - 50) * 0.25), motionRMS: 0.10, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        for i in 58..<68 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.10, hr: 100), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .resting)
        XCTAssertEqual(d.liveAttemptCount, 1)
        XCTAssertEqual(d.finalize().count, 1)
    }

    func testForgottenManualReturnToFloorClosesWhileWalkingExactlyOnce() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<20 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        d.beginManualAttempt(at: start.addingTimeInterval(20))
        for i in 20..<35 {
            d.ingest(MotionSample(t: Double(i), altitude: Double(i - 20) * 0.1, motionRMS: 0.15, hr: 120), at: start.addingTimeInterval(Double(i)))
        }
        for i in 35..<40 {
            d.ingest(MotionSample(t: Double(i), altitude: max(0, 1.4 - Double(i - 35) * 0.4), motionRMS: 0.10, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        for i in 40..<48 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.10, hr: 100), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .resting)
        d.endManualAttempt(at: start.addingTimeInterval(48))
        XCTAssertEqual(d.finalize().filter { $0.source == .manual }.count, 1)
    }

    func testQuietPauseWhileElevatedDoesNotClose() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        for i in 30..<45 {
            d.ingest(MotionSample(t: Double(i), altitude: Double(i - 30) * 0.1, motionRMS: 0.14, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        for i in 45..<60 {
            d.ingest(MotionSample(t: Double(i), altitude: 1.4, motionRMS: 0.01, hr: 115), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .autoClimbing)
    }

    /// #473 changed this test's trace (it is EXPECTED to change, per the
    /// issue's correction comment — capping HR at +1 alone deletes HR-only
    /// detection). A zero-altitude traverse now needs HR-rise(+1) AND
    /// sustained motion (+1, ~12-of-15 trailing ticks, stricter than the
    /// 5-of-8 candidate gate) to reach startConfidenceRequired. The original
    /// 12-tick active segment isn't long enough: confidence only trips once
    /// the sustained-motion window has accumulated enough active ticks
    /// (empirically the last tick of a same-length active run), leaving no
    /// active ticks inside the resulting attempt window to pass
    /// minActiveMotionTicks. A realistic-length traverse (35s of active
    /// motion) leaves a real climbing window after confidence trips, same as
    /// a real gym traverse would.
    func testHROnlyAttemptClosesWithQuietFallback() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        for i in 30..<65 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.13, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .autoClimbing)
        for i in 65..<80 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .resting)
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].source, .auto)
    }

    func testSnapshotLocalHeightTracksDescentAndClampsAtZero() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: -2, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        for i in 30..<45 {
            d.ingest(MotionSample(t: Double(i), altitude: -2 + Double(i - 30) * 0.1, motionRMS: 0.14, hr: 110), at: start.addingTimeInterval(Double(i)))
        }
        let peakHeight = d.snapshot.localHeightM
        d.ingest(MotionSample(t: 45, altitude: -1.5, motionRMS: 0.10, hr: 110), at: start.addingTimeInterval(45))
        XCTAssertLessThan(d.snapshot.localHeightM, peakHeight)
        d.ingest(MotionSample(t: 46, altitude: -2.2, motionRMS: 0.10, hr: 105), at: start.addingTimeInterval(46))
        XCTAssertEqual(d.snapshot.localHeightM, 0)
    }

    func testForgottenManualStopAutoClosesExactlyOnce() {
        let d = AttemptDetector(tunables: .default)
        for i in 0..<20 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        d.beginManualAttempt(at: start.addingTimeInterval(20))
        for i in 20..<35 {
            d.ingest(MotionSample(t: Double(i), altitude: Double(i - 20) * 0.1, motionRMS: 0.15, hr: 120), at: start.addingTimeInterval(Double(i)))
        }
        for i in 35..<48 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 100), at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(d.snapshot.state, .resting)
        XCTAssertEqual(d.liveAttemptCount, 1)
        d.endManualAttempt(at: start.addingTimeInterval(48))
        XCTAssertEqual(d.finalize().filter { $0.source == .manual }.count, 1)
    }

    func testExplicitManualStopIsIdempotent() {
        let d = AttemptDetector(tunables: .default)
        d.beginManualAttempt(at: start)
        for i in 0..<5 {
            d.ingest(MotionSample(t: Double(i), altitude: 0.2, motionRMS: 0.1, hr: nil), at: start.addingTimeInterval(Double(i)))
        }
        d.endManualAttempt(at: start.addingTimeInterval(5))
        d.endManualAttempt(at: start.addingTimeInterval(6))
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].source, .manual)
    }

    func testManualStartAndStopBeforeFirstSensorTickIsSafe() {
        let d = AttemptDetector(tunables: .default)
        d.beginManualAttempt(at: start)
        XCTAssertEqual(d.liveAttemptCount, 0)
        d.endManualAttempt(at: start.addingTimeInterval(0.5))
        XCTAssertEqual(d.snapshot.state, .resting)
        XCTAssertEqual(d.liveAttemptCount, 0)

        d.ingest(
            MotionSample(t: 1, altitude: 0, motionRMS: 0.02, hr: 80),
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(d.finalize().count, 0)
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

    // MARK: #475 — zero-duration invariant at the single emit boundary

    /// Ingests `count` resting ticks and returns "now" for the caller to open
    /// a manual attempt against a non-empty buffer without any tick elapsing
    /// before the close.
    @discardableResult
    private func nonEmptyBuffer(_ d: AttemptDetector, count: Int = 5) -> Date {
        for i in 0..<count {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
        }
        return start.addingTimeInterval(Double(count))
    }

    /// The named acceptance case: `beginManualAttempt` + `endManualAttempt`
    /// with no intervening `ingest` on a non-empty buffer. Pre-#475 this
    /// reached the caller as one attempt with `durationS == 0.0` — verified
    /// failing before the `processedAttempts()` guard was added.
    func testSameTickManualStopOnNonEmptyBufferRecordsNothing() {
        let d = AttemptDetector(tunables: .default)
        let now = nonEmptyBuffer(d)
        d.beginManualAttempt(at: now)
        d.endManualAttempt(at: now)
        XCTAssertEqual(d.liveAttemptCount, 0)
        XCTAssertEqual(d.finalize().count, 0)
    }

    /// `durationS > 0` as a property over all four paths that can emit an
    /// attempt (manual stop, current stop, finalize() flush, assisted
    /// close) — not a case test on just one of them. Opus's review measured
    /// a third path rev 1 missed: Play, then End the Workout without ever
    /// tapping Stop routes through `finalize()`'s direct flush of the open
    /// manual phase, which had no duration guard of its own. Pre-#475, the
    /// `.manualStop`, `.currentStop` and `.finalizeFlush` branches below
    /// each produced a `durationS == 0.0` attempt and failed the assertion;
    /// `.assistedClose` cannot go below `assistedManualMinS` (12s) by
    /// construction and is included to prove the guard doesn't reject a
    /// legitimate attempt.
    func testPositiveDurationInvariantHoldsAcrossAllFourEmissionPaths() {
        enum Closer: String, CaseIterable {
            case manualStop, currentStop, finalizeFlush, assistedClose
        }
        for closer in Closer.allCases {
            let d = AttemptDetector(tunables: .default)
            let now = nonEmptyBuffer(d)
            d.beginManualAttempt(at: now)
            let attempts: [Attempt]
            switch closer {
            case .manualStop:
                d.endManualAttempt(at: now)
                attempts = d.finalize()
            case .currentStop:
                d.endCurrentAttempt(at: now)
                attempts = d.finalize()
            case .finalizeFlush:
                // Play, then End Workout without tapping Stop.
                attempts = d.finalize()
            case .assistedClose:
                for i in 5..<25 {
                    d.ingest(
                        MotionSample(t: Double(i), altitude: Double(i - 5) * 0.1, motionRMS: 0.15, hr: 130),
                        at: start.addingTimeInterval(Double(i))
                    )
                }
                for i in 25..<38 {
                    d.ingest(
                        MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 100),
                        at: start.addingTimeInterval(Double(i))
                    )
                }
                XCTAssertFalse(d.isManualAttemptOpen, "\(closer) should have auto-closed via the assisted path")
                attempts = d.finalize()
            }
            for a in attempts {
                XCTAssertGreaterThan(a.durationS, 0, "\(closer) emitted a non-positive-duration attempt")
            }
        }
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

    // MARK: #473 — auto re-open after a close

    /// THE load-bearing acceptance case (issue #473's actual gym bug). A
    /// clean boulder — rise, hold, descend, return to floor — closes exactly
    /// once. Then 12 post-close ticks at 0.10g motion (>= startMotionG, so
    /// every tick of the trailing 8-tick window is active — comfortably over
    /// the 5-of-8 candidate gate) and a 90bpm heart rate (a 45+ bpm rise over
    /// the ~80-100bpm this trace's resting HR settles to) — exactly the
    /// walk-off-motion + still-elevated-HR combination that reopened the
    /// phantom on unfixed code. Verified failing pre-fix: on the checked-out
    /// pre-#473 detector this trace re-enters .autoClimbing on the very
    /// first hostile tick (HR alone reaches startConfidenceRequired via both
    /// old HR thresholds), transitions == 3 (not 2), and the merged
    /// duration hits 49s against this test's 30s ceiling.
    func testPostCloseHostileTickStaysAtRest() {
        let d = AttemptDetector(tunables: .default)
        var transitions = 0
        var lastClimbing = false
        func ingest(_ alt: Double, _ rms: Double, _ hr: Double?, _ i: Int) {
            d.ingest(MotionSample(t: Double(i), altitude: alt, motionRMS: rms, hr: hr), at: start.addingTimeInterval(Double(i)))
            let climbing = d.snapshot.isClimbing
            if climbing != lastClimbing { transitions += 1 }
            lastClimbing = climbing
        }

        var i = 0
        for _ in 0..<30 { ingest(0, 0.02, 80, i); i += 1 }                          // rest
        for k in 0..<20 { ingest(Double(k) * 0.08, 0.13, 110, i); i += 1 }          // rise to ~1.5m
        for k in 0..<8 { ingest(max(0, 1.5 - Double(k) * 0.25), 0.10, 110, i); i += 1 } // descend
        for _ in 0..<10 { ingest(0, 0.10, 100, i); i += 1 }                         // walk, returns to floor

        XCTAssertEqual(d.snapshot.state, .resting, "the legitimate boulder should already be closed")
        XCTAssertEqual(d.liveAttemptCount, 1)

        // Hostile post-close ticks.
        for _ in 0..<12 {
            ingest(0, 0.10, 170, i)
            XCTAssertEqual(d.snapshot.state, .resting, "phantom re-opened on a post-close hostile tick")
            i += 1
        }

        XCTAssertEqual(transitions, 2, "exactly one resting→climbing→resting cycle")
        let final = d.finalize()
        XCTAssertEqual(final.count, 1)
        XCTAssertLessThanOrEqual(final[0].durationS, 30, "duration ceiling on the one legitimate boulder")
        XCTAssertFalse(final[0].hitCap)
    }

    /// #473: Stop-then-Play must open and STAY manual — the auto-disarm the
    /// hostile-tick fix relies on must never block the user's own Play tap,
    /// or the fix for a dead Stop button creates a dead Play button. (Passes
    /// on pre-#473 code too, since no disarm existed to block anything —
    /// kept as an acceptance criterion per the issue's stated requirement,
    /// not because it's a regression.)
    func testStopThenPlayBypassesDisarmAndStaysManual() {
        let d = AttemptDetector(tunables: .default)
        var i = 0
        for _ in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        for k in 0..<20 {
            d.ingest(MotionSample(t: Double(i), altitude: Double(k) * 0.08, motionRMS: 0.13, hr: 110), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        let now = start.addingTimeInterval(Double(i))
        d.endCurrentAttempt(at: now) // Stop, with walk-off motion still fresh
        XCTAssertEqual(d.snapshot.state, .resting)

        d.beginManualAttempt(at: now) // Play, immediately after Stop
        XCTAssertTrue(d.isManualAttemptOpen, "manual Play must bypass the post-close disarm")

        // Stays manual across further ticks — including hostile-looking
        // motion+HR that would otherwise be blocked for auto.
        for _ in 0..<10 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.10, hr: 170), at: start.addingTimeInterval(Double(i)))
            XCTAssertTrue(d.isManualAttemptOpen, "manual attempt closed on its own while open")
            i += 1
        }
    }

    /// #473: an explicit Stop on a short/low-motion AUTO attempt must always
    /// record — it must not fall through the same minAttemptS/
    /// minActiveMotionTicks filters that exist to catch UNDETECTED phantoms.
    /// This is independent of the #475 zero-duration guard (still enforced):
    /// duration here is real, just short. Verified failing pre-fix: the same
    /// trace records 0 attempts on the checked-out pre-#473 detector,
    /// because an explicit Stop on an auto attempt applied the same
    /// minAttemptS/minActiveMotionTicks filters as an undetected phantom.
    func testExplicitStopOfShortAutoAttemptRecordsExactlyOnePositiveDurationAttempt() {
        let d = AttemptDetector(tunables: .default)
        var i = 0
        for _ in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        // A strong-altitude start (confidence 2 from altitude alone; jumps
        // straight to 1.2m so gain is already >= startStrongAltitudeM from
        // the first climbing tick), then Stop after only 6 ticks — enough to
        // clear the 5-of-8 motion candidate gate but still under
        // minAttemptS (8s) and minActiveMotionTicks (8 active ticks).
        for _ in 0..<6 {
            d.ingest(MotionSample(t: Double(i), altitude: 1.2, motionRMS: 0.12, hr: 100), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        XCTAssertEqual(d.snapshot.state, .autoClimbing)
        let now = start.addingTimeInterval(Double(i))
        d.endCurrentAttempt(at: now)
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertGreaterThan(attempts[0].durationS, 0)
        XCTAssertEqual(attempts[0].source, .auto)
    }

    /// #473 guard: capping HR at +1 must not touch altitude-only starts — a
    /// small (1m), HR-less climb still opens and closes normally.
    func testHRLessOneMeterClimbStillOpens() {
        var trace: [(Double, Double, Double?)] = []
        trace += Array(repeating: (0.0, 0.02, nil), count: 30)
        for i in 0..<20 { trace.append((Double(i) * 1.0 / 19.0, 0.13, nil)) }
        for i in 0..<8 { trace.append((1.0 - Double(i) * 0.14, 0.10, nil)) }
        trace += Array(repeating: (0.0, 0.02, nil), count: 12)
        let attempts = run(trace)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertGreaterThanOrEqual(attempts[0].elevationGainM, 0.9)
    }

    // MARK: #473 — realistic close paths for attempts that never self-close

    /// A floor-level (never-established) attempt must close near
    /// `unestablishedMaxS` (60s), not fall through to `maxAttemptS` (300s).
    /// This trace never gives the HR+quiet fallback a chance to fire either
    /// (motion sits at 0.06g — above `quietMotionG` so never "quiet", below
    /// `startMotionG` so it stops re-triggering the candidate gate), so on
    /// pre-#473 code (no `unestablishedMaxS`) this closes at exactly
    /// `maxAttemptS` — reasoned rather than run, since the tunable this test
    /// exercises did not exist pre-fix and the file can't compile against
    /// both at once.
    func testUnestablishedAttemptClosesNearFloorLevelCap() {
        let d = AttemptDetector(tunables: .default)
        var i = 0
        for _ in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        // HR-rise + sustained-motion opens it (same shape as the restored
        // traverse test), flat altitude throughout.
        for _ in 0..<35 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.13, hr: 110), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        XCTAssertEqual(d.snapshot.state, .autoClimbing)
        // Never establishes (flat altitude), never goes quiet (0.06g is
        // above quietMotionG), HR support never lapses (constant 110) — the
        // only exit left is the floor-level cap.
        for _ in 0..<200 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.06, hr: 110), at: start.addingTimeInterval(Double(i)))
            i += 1
            if d.snapshot.state == .resting { break }
        }
        XCTAssertEqual(d.snapshot.state, .resting, "never closed at all")
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertGreaterThan(attempts[0].durationS, 60, "must run at least to unestablishedMaxS")
        XCTAssertLessThanOrEqual(attempts[0].durationS, 66, "exact ceiling — must not run anywhere near maxAttemptS (300s)")
        XCTAssertTrue(attempts[0].hitCap)
    }

    /// An attempt that DOES establish altitude (>= establishedAltitudeGainM)
    /// but never returns within `endReturnM` of its startline — real
    /// barometric drift over a long, fully quiet hold — must close near
    /// `establishedDriftMaxS` (90s), not sit CLIMBING for the full
    /// `maxAttemptS` (300s). Reasoned rather than run against pre-#473 code
    /// for the same reason as the unestablished case above: on that code
    /// the established branch of `AttemptEndResolver.shouldEnd` checks
    /// ONLY `returnedToFloor` and ignores quiet entirely (see the struck
    /// version still in this file's git history), so this exact trace closes
    /// at maxAttemptS = 300s, not ~90s.
    func testEstablishedDriftAttemptClosesNearDriftCap() {
        let d = AttemptDetector(tunables: .default)
        var i = 0
        for _ in 0..<30 {
            d.ingest(MotionSample(t: Double(i), altitude: 0, motionRMS: 0.02, hr: 80), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        for k in 0..<20 { // establishes ~1.5m
            d.ingest(MotionSample(t: Double(i), altitude: Double(k) * 0.08, motionRMS: 0.13, hr: 110), at: start.addingTimeInterval(Double(i)))
            i += 1
        }
        XCTAssertEqual(d.snapshot.state, .autoClimbing)
        // Fully still at altitude — never returns within endReturnM of the
        // startline (real drift), quiet the whole time.
        for _ in 0..<200 {
            d.ingest(MotionSample(t: Double(i), altitude: 1.5, motionRMS: 0.01, hr: 90), at: start.addingTimeInterval(Double(i)))
            i += 1
            if d.snapshot.state == .resting { break }
        }
        XCTAssertEqual(d.snapshot.state, .resting, "never closed at all")
        let attempts = d.finalize()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertGreaterThan(attempts[0].durationS, 90, "must run at least to establishedDriftMaxS")
        XCTAssertLessThanOrEqual(attempts[0].durationS, 96, "exact ceiling — must not run anywhere near maxAttemptS (300s)")
        XCTAssertTrue(attempts[0].hitCap)
        XCTAssertGreaterThan(attempts[0].elevationGainM, 1.0)
    }
}
