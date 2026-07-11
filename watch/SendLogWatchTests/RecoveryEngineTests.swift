import XCTest
@testable import SendLogWatch

final class RecoveryEngineTests: XCTestCase {
    private let t = RecoveryTunables.default

    private func inputs(
        hrv: Double? = nil,
        rhr: Double? = nil,
        sleep: Double? = nil,
        hrvBase: [Double] = [],
        rhrBase: [Double] = [],
        sleepBase: [Double] = []
    ) -> DailyHealthInputs {
        DailyHealthInputs(
            hrvSDNNms: hrv, restingHR: rhr, sleepHours: sleep, bodyMassKg: nil,
            hrvLnBaseline: hrvBase, rhrBaseline: rhrBase, sleepBaseline: sleepBase
        )
    }

    /// Baseline arrays with exact mean/σ: alternate mean±σ.
    private func base(mean: Double, sigma: Double, n: Int = 10) -> [Double] {
        (0..<n).map { mean + ($0 % 2 == 0 ? sigma : -sigma) }
    }

    func testWorkedExample() {
        // z_hrv = (ln75 − 4.1)/0.15 ≈ +1.45 → +21.8; z_rhr = (52−54)/2 = −1 → +12
        // z_sleep = (6.1−7.2)/0.6 ≈ −1.83 → −14.7; acwr 1.45 → p=0.214 → −4.3
        let r = RecoveryEngine.compute(
            inputs: inputs(
                hrv: 75, rhr: 52, sleep: 6.1,
                hrvBase: base(mean: 4.1, sigma: 0.15),
                rhrBase: base(mean: 54, sigma: 2),
                sleepBase: base(mean: 7.2, sigma: 0.6)
            ),
            acwr: 1.45, t: t
        )
        XCTAssertNotNil(r.score)
        XCTAssertEqual(Double(r.score ?? 0), 65, accuracy: 3)
        XCTAssertEqual(r.zone, .maintain)
    }

    func testZClampAtPlusMinus2() {
        // HRV massively above baseline: contribution caps at wHRV * 2 = 30
        let r = RecoveryEngine.compute(
            inputs: inputs(hrv: 200, hrvBase: base(mean: 4.0, sigma: 0.1)),
            acwr: nil, t: t
        )
        XCTAssertEqual(r.score, 80) // 50 + 15*2
        XCTAssertEqual(r.zone, .push)
    }

    func testSleepPositiveCap() {
        // Great sleep can add at most wSleep * sleepPosCapZ = 8
        let good = RecoveryEngine.compute(
            inputs: inputs(
                rhr: 54, sleep: 12,
                rhrBase: base(mean: 54, sigma: 2),
                sleepBase: base(mean: 7, sigma: 0.6)
            ),
            acwr: nil, t: t
        )
        XCTAssertEqual(good.score, 58) // 50 + 0 (rhr at mean) + 8 capped
    }

    func testSleepSigmaFloor() {
        // Hyper-regular sleeper (σ=0.1 → floored to 0.5): 30 min short ≈ −1z, not −5z
        let r = RecoveryEngine.compute(
            inputs: inputs(
                rhr: 54, sleep: 6.5,
                rhrBase: base(mean: 54, sigma: 2),
                sleepBase: base(mean: 7.0, sigma: 0.1)
            ),
            acwr: nil, t: t
        )
        XCTAssertEqual(r.score, 42) // 50 − 8*(0.5/0.5 → z=−1) = 42
    }

    func testShortBaselineDropsTerm() {
        // Only 3 baseline days → HRV term contributes nothing; RHR carries
        let r = RecoveryEngine.compute(
            inputs: inputs(
                hrv: 100, rhr: 54,
                hrvBase: base(mean: 4.0, sigma: 0.1, n: 3),
                rhrBase: base(mean: 54, sigma: 2)
            ),
            acwr: nil, t: t
        )
        XCTAssertEqual(r.score, 50)
    }

    func testBothAutonomicSignalsMissingReturnsNil() {
        let r = RecoveryEngine.compute(
            inputs: inputs(sleep: 7, sleepBase: base(mean: 7, sigma: 0.6)),
            acwr: 1.0, t: t
        )
        XCTAssertNil(r.score)
        XCTAssertNil(r.zone)
        XCTAssertEqual(r.driver, "Insufficient data")
    }

    func testAcwrPenalty() {
        func score(acwr: Double?) -> Int {
            RecoveryEngine.compute(
                inputs: inputs(rhr: 54, rhrBase: base(mean: 54, sigma: 2)),
                acwr: acwr, t: t
            ).score!
        }
        XCTAssertEqual(score(acwr: nil), 50)
        XCTAssertEqual(score(acwr: 1.3), 50)     // penalty starts above 1.3
        XCTAssertEqual(score(acwr: 1.65), 40)    // halfway → −10
        XCTAssertEqual(score(acwr: 2.0), 30)     // full → −20
        XCTAssertEqual(score(acwr: 3.0), 30)     // clamped
    }

    func testZoneBoundaries() {
        func zone(rhr: Double) -> ReadinessZone? {
            RecoveryEngine.compute(
                inputs: inputs(rhr: rhr, rhrBase: base(mean: 54, sigma: 2)),
                acwr: nil, t: t
            ).zone
        }
        // rhr 54 → z 0 → 50 maintain; rhr 50 → z −2 → 74 push; rhr 58 → z +2 → 26 recover
        XCTAssertEqual(zone(rhr: 54), .maintain)
        XCTAssertEqual(zone(rhr: 50), .push)
        XCTAssertEqual(zone(rhr: 58), .recover)
    }

    func testDriverLine() {
        let r = RecoveryEngine.compute(
            inputs: inputs(
                hrv: 40, rhr: 54,
                hrvBase: base(mean: 4.3, sigma: 0.15), // ln40 ≈ 3.69 → z −2 (clamped)
                rhrBase: base(mean: 54, sigma: 2)
            ),
            acwr: nil, t: t
        )
        XCTAssertEqual(r.driver, "HRV below baseline")
    }
}
