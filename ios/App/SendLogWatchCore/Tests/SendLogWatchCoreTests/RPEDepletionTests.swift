import XCTest
import SendLogWatchCore

/// KEEP-IN-SYNC: the same vectors run in `src/lib/rpeDepletion.test.ts`. Both
/// implementations must agree to 0.1 RPE on every case below — that's the
/// whole point of duplicating the depletion math instead of porting the
/// 449-line curve fit to Swift (issue #280).
final class RPEDepletionTests: XCTestCase {
    /// The load→RPE table from issue #280.
    private let mappingVectors: [(load: Double, rpe: Double)] = [
        (0, 1),
        (0.5, 2.6),
        (1, 4),
        (2, 6),
        (4, 8.2),
        (6, 9.2),
        (8, 9.6),
    ]

    private func rep(_ peakKg: Double, _ durationS: Double, _ cf: Double?, _ wPrime: Double?) -> DepletionRep {
        DepletionRep(peakKg: peakKg, durationS: durationS, cf: cf, wPrime: wPrime)
    }

    // MARK: repDepletion

    func testOnCurveToFailureIsExactlyOneBattery() {
        // P = CF + W'/T is the definition of the curve, so (P - CF)·T = W'.
        // This identity is the vector that catches sign and unit errors in
        // both implementations at once.
        let cf = 30.0
        let wPrime = 180.0
        let t = 10.0
        XCTAssertEqual(RPEDepletion.repDepletion(rep(cf + wPrime / t, t, cf, wPrime)) ?? -1, 1.0, accuracy: 1e-10)
    }

    func testScalesLinearlyInForceAboveCFAndInDuration() {
        XCTAssertEqual(RPEDepletion.repDepletion(rep(39, 10, 30, 180)) ?? -1, 0.5, accuracy: 1e-10)
        XCTAssertEqual(RPEDepletion.repDepletion(rep(48, 5, 30, 180)) ?? -1, 0.5, accuracy: 1e-10)
    }

    func testAtOrBelowCFContributesNothing() {
        XCTAssertEqual(RPEDepletion.repDepletion(rep(30, 60, 30, 180)), 0)
        XCTAssertEqual(RPEDepletion.repDepletion(rep(25, 60, 30, 180)), 0)
    }

    func testNilWithoutAUsableCurve() {
        XCTAssertNil(RPEDepletion.repDepletion(rep(48, 10, nil, nil)))
        XCTAssertNil(RPEDepletion.repDepletion(rep(48, 10, 30, nil)))
        XCTAssertNil(RPEDepletion.repDepletion(rep(48, 10, nil, 180)))
        // Degenerate fit — nothing to divide by.
        XCTAssertNil(RPEDepletion.repDepletion(rep(48, 10, 30, 0)))
    }

    func testNegativeDurationIsClampedToZero() {
        XCTAssertEqual(RPEDepletion.repDepletion(rep(48, -5, 30, 180)), 0)
    }

    // MARK: sessionDepletion

    func testSumsEachRepAgainstItsOwnTagsCurve() {
        let load = RPEDepletion.sessionDepletion([
            rep(48, 10, 30, 180),  // 1.0
            rep(30, 5, 20, 100),   // 0.5
        ])
        XCTAssertEqual(load ?? -1, 1.5, accuracy: 1e-10)
    }

    func testSkipsRepsWithoutACurveAndKeepsTheOnesWithOne() {
        let load = RPEDepletion.sessionDepletion([
            rep(48, 10, 30, 180),      // 1.0
            rep(60, 30, nil, nil),     // no curve — contributes nothing
        ])
        XCTAssertEqual(load ?? -1, 1.0, accuracy: 1e-10)
    }

    func testNilRatherThanZeroWhenNoRepHadACurve() {
        XCTAssertNil(RPEDepletion.sessionDepletion([rep(48, 10, nil, nil)]))
        XCTAssertNil(RPEDepletion.sessionDepletion([]))
    }

    // MARK: rpeForDepletion

    func testMatchesThePublishedTable() {
        for v in mappingVectors {
            XCTAssertEqual(RPEDepletion.rpeForDepletion(v.load), v.rpe, accuracy: 1e-9,
                           "L = \(v.load)")
        }
    }

    func testStaysInsideOneToTen() {
        XCTAssertEqual(RPEDepletion.rpeForDepletion(1000), 10)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(0), 1)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(-5), 1)
    }

    // MARK: predictSessionRPE

    func testSingleOnCurveRepPredictsFour() {
        let p = RPEDepletion.predictSessionRPE([rep(48, 10, 30, 180)])
        XCTAssertEqual(p.load ?? -1, 1.0, accuracy: 1e-10)
        XCTAssertEqual(p.rpe, 4.0)
        XCTAssertTrue(p.fromCurve)
    }

    func testMixedTagSessionUsesBothCurves() {
        let p = RPEDepletion.predictSessionRPE([rep(48, 10, 30, 180), rep(30, 5, 20, 100)])
        XCTAssertEqual(p.rpe, 5.1)  // L = 1.5
        XCTAssertTrue(p.fromCurve)
    }

    func testFallsBackWithoutAnyCurve() {
        let p = RPEDepletion.predictSessionRPE([rep(48, 10, nil, nil), rep(60, 30, 0, 0)])
        XCTAssertEqual(p.rpe, RPEDepletionTunables.fallbackRPE)
        XCTAssertFalse(p.fromCurve)
        XCTAssertNil(p.load)
    }

    func testFallsBackOnAnEmptySessionRatherThanReportingRPEOne() {
        let p = RPEDepletion.predictSessionRPE([])
        XCTAssertEqual(p.rpe, RPEDepletionTunables.fallbackRPE)
        XCTAssertFalse(p.fromCurve)
        XCTAssertNil(p.load)
    }

    // MARK: SessionDepletionAccumulator (watch-side running sum)

    func testAccumulatorMatchesTheOneShotPrediction() {
        let reps = [rep(48, 10, 30, 180), rep(30, 5, 20, 100), rep(60, 30, nil, nil)]
        var acc = SessionDepletionAccumulator()
        for r in reps { acc.add(r) }
        XCTAssertEqual(acc.measuredReps, 2)
        XCTAssertEqual(acc.predicted.rpe, RPEDepletion.predictSessionRPE(reps).rpe)
        XCTAssertEqual(acc.predicted.load ?? -1, 1.5, accuracy: 1e-10)
    }

    func testAccumulatorFallsBackUntilARepHasACurve() {
        var acc = SessionDepletionAccumulator()
        acc.add(rep(60, 30, nil, nil))
        XCTAssertEqual(acc.measuredReps, 0)
        XCTAssertFalse(acc.predicted.fromCurve)
        XCTAssertEqual(acc.predicted.rpe, RPEDepletionTunables.fallbackRPE)
    }

    func testAccumulatorResetsWithTheSession() {
        var acc = SessionDepletionAccumulator()
        acc.add(rep(48, 10, 30, 180))
        acc.reset()
        XCTAssertEqual(acc.load, 0)
        XCTAssertEqual(acc.measuredReps, 0)
        XCTAssertFalse(acc.predicted.fromCurve)
    }
}
