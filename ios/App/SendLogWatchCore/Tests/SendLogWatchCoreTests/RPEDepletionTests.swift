import Foundation
import XCTest
import SendLogWatchCore

private struct RPEParityFixture: Decodable {
    struct Tolerances: Decodable {
        let load: Double
        let rpe: Double
        let mapping: Double
    }

    struct MappingVector: Decodable {
        let load: Double
        let expectedRpe: Double
    }

    struct Rep: Decodable {
        let peakKg: Double
        let durationS: Double
        let cf: Double?
        let wPrime: Double?

        var depletionRep: DepletionRep {
            DepletionRep(peakKg: peakKg, durationS: durationS, cf: cf, wPrime: wPrime)
        }
    }

    struct SessionVector: Decodable {
        let id: String
        let reps: [Rep]
        let expectedLoad: Double?
        let expectedRpe: Double
        let expectedFromCurve: Bool
    }

    let tolerances: Tolerances
    let loadToRpe: [MappingVector]
    let sessions: [SessionVector]
}

/// The parity vectors live in one JSON fixture also consumed by
/// `src/lib/rpeDepletion.test.ts`, so a retune cannot update one suite only.
final class RPEDepletionTests: XCTestCase {
    private static let fixture: RPEParityFixture = {
        #if SWIFT_PACKAGE
        let resourceURL = Bundle.module.url(forResource: "rpe-depletion-parity", withExtension: "json")
        #else
        let resourceURL: URL? = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/rpe-depletion-parity.json")
        #endif
        guard let resourceURL else { fatalError("Missing rpe-depletion-parity.json test resource") }
        do {
            return try JSONDecoder().decode(RPEParityFixture.self, from: Data(contentsOf: resourceURL))
        } catch {
            fatalError("Invalid RPE parity fixture: \(error)")
        }
    }()

    private func rep(_ peakKg: Double, _ durationS: Double, _ cf: Double?, _ wPrime: Double?) -> DepletionRep {
        DepletionRep(peakKg: peakKg, durationS: durationS, cf: cf, wPrime: wPrime)
    }

    // MARK: repDepletion

    func testOnCurveToFailureIsExactlyOneBattery() {
        guard let vector = Self.fixture.sessions.first(where: { $0.id == "one-battery-on-curve" }),
              let fixtureRep = vector.reps.first,
              let expectedLoad = vector.expectedLoad else {
            XCTFail("Invalid one-battery RPE parity vector")
            return
        }
        XCTAssertEqual(
            RPEDepletion.repDepletion(fixtureRep.depletionRep) ?? -1,
            expectedLoad,
            accuracy: Self.fixture.tolerances.load
        )
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
        for v in Self.fixture.loadToRpe {
            XCTAssertEqual(RPEDepletion.rpeForDepletion(v.load), v.expectedRpe,
                           accuracy: Self.fixture.tolerances.mapping,
                           "L = \(v.load)")
        }
    }

    func testStaysInsideOneToTen() {
        XCTAssertEqual(RPEDepletion.rpeForDepletion(1000), 10)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(0), 1)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(-5), 1)
    }

    // MARK: predictSessionRPE

    func testPredictionsMatchSharedSessionVectors() {
        for vector in Self.fixture.sessions {
            let prediction = RPEDepletion.predictSessionRPE(vector.reps.map(\.depletionRep))
            if let expectedLoad = vector.expectedLoad {
                XCTAssertEqual(prediction.load ?? -.infinity, expectedLoad,
                               accuracy: Self.fixture.tolerances.load, vector.id)
            } else {
                XCTAssertNil(prediction.load, vector.id)
            }
            XCTAssertEqual(prediction.rpe, vector.expectedRpe,
                           accuracy: Self.fixture.tolerances.rpe, vector.id)
            XCTAssertEqual(prediction.fromCurve, vector.expectedFromCurve, vector.id)
        }
    }

    func testFixtureFallbackMatchesTheModelTunable() {
        for vector in Self.fixture.sessions where !vector.expectedFromCurve {
            XCTAssertEqual(vector.expectedRpe, RPEDepletionTunables.fallbackRPE, vector.id)
        }
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
