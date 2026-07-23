import XCTest
@testable import SendLogHealthCore

final class BaselineBuilderTests: XCTestCase {
    private let t = RecoveryTunables.default

    private func night(
        hrv: Double? = nil,
        rhr: Double? = nil,
        sleep: Double? = nil,
        deep: Double? = nil,
        rem: Double? = nil,
        resp: Double? = nil
    ) -> NightSample {
        NightSample(hrv: hrv, rhr: rhr, sleepTotal: sleep, sleepDeep: deep, sleepRem: rem, resp: resp)
    }

    private var emptyNight: NightSample { NightSample() }

    /// A fully-populated night with values derived from `i` so ordering is
    /// assertable (hrv 40+i, rhr 50+i, sleep 6+i/100, deep 1+i/100,
    /// rem 1.5+i/100, resp 14+i/100).
    private func fullNight(_ i: Int) -> NightSample {
        let d = Double(i)
        return night(
            hrv: 40 + d, rhr: 50 + d, sleep: 6 + d / 100,
            deep: 1 + d / 100, rem: 1.5 + d / 100, resp: 14 + d / 100
        )
    }

    /// The prod-shaped gap layout from issue #111: usable nights only at
    /// indexes 0-5 (fresh data after the gap) and 65-70 (pre-gap history),
    /// everything else empty. 12 usable autonomic nights total.
    private func gapNights() -> [NightSample] {
        (0..<90).map { i in
            if (0...5).contains(i) {
                // fresh post-gap nights — alternate so σ > 0
                return night(hrv: i % 2 == 0 ? 45 : 55, rhr: i % 2 == 0 ? 52 : 60)
            }
            if (65...70).contains(i) {
                return night(hrv: i % 2 == 0 ? 40 : 60, rhr: i % 2 == 0 ? 51 : 59, sleep: 7.2)
            }
            return emptyNight
        }
    }

    // 1. Healthy trailing window → same arrays the old fixed-window loops built.
    func testHealthyWindowMatchesLegacyRules() {
        let nights = (0..<30).map(fullNight)
        let r = BaselineBuilder.build(nights: nights, t: t)
        XCTAssertEqual(r.hrvLnBaseline.count, 30)
        XCTAssertEqual(r.rhrBaseline.count, 30)
        XCTAssertEqual(r.sleepBaseline.count, 30)
        XCTAssertEqual(r.respBaseline.count, 30)
        XCTAssertEqual(r.restorativeSleepBaseline.count, 30)
        // hrv entries are log(hrv), in nights order
        let expectedHrv: [Double] = (0..<30).map { log(40 + Double($0)) }
        XCTAssertEqual(r.hrvLnBaseline, expectedHrv)
        // restorative = deep + rem
        let expectedRest: [Double] = (0..<30).map { i -> Double in
            let d = Double(i)
            return (1 + d / 100) + (1.5 + d / 100)
        }
        XCTAssertEqual(r.restorativeSleepBaseline, expectedRest, "restorative should be deep+rem")
        XCTAssertFalse(r.isAutonomicStarved)
    }

    // 2. Per-night usability rules, verbatim from the old loops.
    func testUsabilityFilters() {
        let nights: [NightSample] = [
            night(hrv: 0, rhr: 55),          // hrv 0 → excluded; rhr still counts
            night(rhr: 56),                  // hrv nil, rhr present → rhr counts
            night(hrv: 50, sleep: 0),        // sleepTotal 0 → excluded
            night(resp: 0),                  // resp 0 → excluded
            night(deep: 0, rem: 0),          // deep+rem = 0 → no restorative entry
            night(deep: 1.5),                // deep-only → restorative 1.5
            night(rem: 1.2),                 // rem-only → restorative 1.2
        ]
        let r = BaselineBuilder.build(nights: nights, t: t)
        XCTAssertEqual(r.hrvLnBaseline, [log(50)])
        XCTAssertEqual(r.rhrBaseline, [55, 56])
        XCTAssertEqual(r.sleepBaseline, [])
        XCTAssertEqual(r.respBaseline, [])
        XCTAssertEqual(r.restorativeSleepBaseline, [1.5, 1.2])
    }

    // 3. Models phiphyy on 07-18: standard 30-night window almost empty.
    func testGapUserStarvedAtThirtyNights() {
        var nights = Array(repeating: emptyNight, count: 30)
        nights[29] = night(hrv: 48, rhr: 55, sleep: 7, resp: 14)
        let r = BaselineBuilder.build(nights: nights, t: t)
        XCTAssertLessThanOrEqual(r.hrvLnBaseline.count, 1)
        XCTAssertLessThanOrEqual(r.rhrBaseline.count, 1)
        XCTAssertLessThanOrEqual(r.sleepBaseline.count, 1)
        XCTAssertLessThanOrEqual(r.respBaseline.count, 1)
        XCTAssertTrue(r.isAutonomicStarved)
    }

    // 4. The extended 90-night scan harvests the pre-gap nights.
    func testExtendedScanFillsFromOldNights() {
        let r = BaselineBuilder.build(nights: gapNights(), t: t)
        XCTAssertGreaterThanOrEqual(r.hrvLnBaseline.count, t.minBaselineDays)
        XCTAssertGreaterThanOrEqual(r.rhrBaseline.count, t.minBaselineDays)
        XCTAssertFalse(r.isAutonomicStarved)
        // The old (index 65-70) nights' values made it into the arrays.
        XCTAssertTrue(r.hrvLnBaseline.contains(log(40)))
        XCTAssertTrue(r.hrvLnBaseline.contains(log(60)))
        XCTAssertTrue(r.rhrBaseline.contains(51))
        XCTAssertTrue(r.rhrBaseline.contains(59))
        XCTAssertTrue(r.sleepBaseline.contains(7.2))
    }

    // 5. An extended scan never inflates a baseline past `baselineDays`,
    //    and the newest usable nights win.
    func testNewestThirtyUsableNightsWin() {
        let nights = (0..<90).map(fullNight)
        let r = BaselineBuilder.build(nights: nights, t: t)
        XCTAssertEqual(r.hrvLnBaseline.count, t.baselineDays)
        XCTAssertEqual(r.rhrBaseline.count, t.baselineDays)
        XCTAssertEqual(r.sleepBaseline.count, t.baselineDays)
        XCTAssertEqual(r.respBaseline.count, t.baselineDays)
        XCTAssertEqual(r.restorativeSleepBaseline.count, t.baselineDays)
        // First entry = newest night (i=0), last = night i=29; nothing older.
        XCTAssertEqual(r.hrvLnBaseline.first, log(40))
        XCTAssertEqual(r.hrvLnBaseline.last, log(40 + 29))
        XCTAssertEqual(r.rhrBaseline.first, 50)
        XCTAssertEqual(r.rhrBaseline.last, 50 + 29)
    }

    // 6. Starvation is autonomic-only: one autonomic signal suffices, and a
    //    permanently absent secondary metric must NOT force extension.
    func testStarvationIsAutonomicOnly() {
        let nights: [NightSample] = (0..<30).map { i in
            i < 10 ? night(hrv: 45 + Double(i)) : emptyNight
        }
        let r = BaselineBuilder.build(nights: nights, t: t)
        XCTAssertEqual(r.hrvLnBaseline.count, 10)
        XCTAssertEqual(r.rhrBaseline, [])
        XCTAssertEqual(r.sleepBaseline, [])
        XCTAssertEqual(r.respBaseline, [])
        XCTAssertFalse(r.isAutonomicStarved)
    }

    // 7. Usable data only past the lookback cap: the caller stops at
    //    `baselineLookbackMaxDays`, so a fully-empty 90-night array stays
    //    starved and the score legitimately remains nil.
    func testBeyondLookbackStaysStarved() {
        let nights = Array(repeating: emptyNight, count: 90)
        let r = BaselineBuilder.build(nights: nights, t: t)
        XCTAssertTrue(r.hrvLnBaseline.isEmpty)
        XCTAssertTrue(r.rhrBaseline.isEmpty)
        XCTAssertTrue(r.sleepBaseline.isEmpty)
        XCTAssertTrue(r.respBaseline.isEmpty)
        XCTAssertTrue(r.restorativeSleepBaseline.isEmpty)
        XCTAssertTrue(r.isAutonomicStarved)
    }
}
