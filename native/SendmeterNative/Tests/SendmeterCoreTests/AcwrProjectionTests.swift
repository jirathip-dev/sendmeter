import XCTest
@testable import SendmeterCore

/// Numeric mirror of the web's `src/lib/acwrProjection.test.ts` — the same
/// inputs must produce the same outputs (decay constants to 6+ dp, band
/// crossings on the same day offsets, keep-in-band loads landing on the same
/// floors). The reference date is pinned so dates are deterministic and the
/// fixtures never depend on the host clock.
final class AcwrProjectionTests: XCTestCase {
    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!
    /// 2026-08-15 — a fixed "today" so `daysAhead`/dates are deterministic.
    private let reference = LocalDateSupport.date(from: "2026-08-15", timeZone: TimeZone(identifier: "Asia/Bangkok")!)!

    /// The web's `CAPACITY_BAND = { low: 0.9, high: 1.1 }`.
    private let capacityBand = AcwrProjection.Band(low: 0.9, high: 1.1)

    private func projection(
        _ state: EWMALoadState,
        _ band: AcwrProjection.Band?,
        horizon: Int = AcwrProjection.projectionDays
    ) -> AcwrProjection.Result {
        AcwrProjection.project(
            state: state,
            band: band,
            horizonDays: horizon,
            referenceDate: reference,
            timeZone: bangkok
        )!
    }

    /// The web's `history()` fixture (`acwrProjection.test.ts:38-40`): 60 days
    /// of sessions, one per day back from the reference, with deterministic
    /// varied loads. Kept inside 60 days on purpose — the EWMA lookback is 90,
    /// so nothing falls out of the window when the clock advances a day.
    private func historySessions(reference: Date) -> [Session] {
        (0..<60).map { i in
            Session(
                id: UUID(),
                date: LocalDateSupport.daysAgo(i, from: reference, timeZone: bangkok),
                type: "board",
                typeLabel: "Board",
                durationMinutes: 60,
                rpe: 5,
                load: 100 + Double((i * 37) % 210),
                phase: .capacity
            )
        }
    }

    // MARK: - Decay constants

    func testDecayConstantsMatchProductContract() {
        XCTAssertEqual(AcwrProjection.lambdaAcute, 0.25, accuracy: 1e-12)
        XCTAssertEqual(AcwrProjection.lambdaChronic, 0.0689655, accuracy: 1e-7)
        // Acceptance criterion 1: pin the rest-day decay ≈ 0.80556 to 6 dp.
        XCTAssertEqual(AcwrProjection.restDayAcwrDecay, 0.805556, accuracy: 1e-6)
        XCTAssertEqual(AcwrProjection.projectionDays, 7)
    }

    func testRestDayMultipliesByTheSameDecayWhateverTheStartingRatio() {
        for state in [
            EWMALoadState(acute: 300, chronic: 300), // 1.00
            EWMALoadState(acute: 90, chronic: 300),  // 0.30
            EWMALoadState(acute: 700, chronic: 300)  // 2.33
        ] {
            let before = AcwrProjection.acwrOf(state)!
            let after = AcwrProjection.acwrOf(AcwrProjection.stepEwmaLoad(state, load: 0))!
            XCTAssertEqual(after / before, AcwrProjection.restDayAcwrDecay, accuracy: 1e-12)
        }
    }

    func testSlideTakesOnePointTwoUnderZeroPointEightInTwoRestDays() {
        let day1 = 1.2 * AcwrProjection.restDayAcwrDecay
        let day2 = day1 * AcwrProjection.restDayAcwrDecay
        XCTAssertGreaterThan(day1, 0.8)
        XCTAssertLessThan(day2, 0.8)
    }

    // MARK: - stepEwmaLoad

    func testStepEwmaLoadIsExactlyTheRecurrenceEwmaApplies() {
        let series: [Double] = [80, 0, 240, 300, 0, 0, 155]
        let state = EWMALoadState(
            acute: TrainingMetrics.ewma(values: series, span: 7).last!!,
            chronic: TrainingMetrics.ewma(values: series, span: 28).last!!
        )
        for load in [0.0, 420.0] {
            let extended = series + [load]
            let stepped = AcwrProjection.stepEwmaLoad(state, load: load)
            XCTAssertEqual(
                stepped.acute,
                TrainingMetrics.ewma(values: extended, span: 7).last!!,
                accuracy: 1e-12
            )
            XCTAssertEqual(
                stepped.chronic,
                TrainingMetrics.ewma(values: extended, span: 28).last!!,
                accuracy: 1e-12
            )
        }
    }

    // MARK: - projectAcwr

    /// Web fixture "day 0 IS today's ratio — the same number the ACWR card
    /// shows" (`acwrProjection.test.ts:92-98`): a real 60-day session history
    /// through `ewmaLoadState`, asserting the projected day 0 equals the ratio
    /// `computeACWR` renders on the Load card directly above. This is the
    /// anti-fabrication guard — it is what would fail if the card ever got a
    /// truncated session window, a different EWMA seed, or a different
    /// reference date than the ACWR pipeline.
    func testDayZeroIsTheRatioTheACWRCardShows() throws {
        let sessions = historySessions(reference: reference)
        let state = try XCTUnwrap(TrainingMetrics.ewmaLoadState(
            sessions: sessions,
            referenceDate: reference,
            timeZone: bangkok
        ))
        let p = projection(state, capacityBand)
        XCTAssertEqual(p.days[0].dayOffset, 0)
        XCTAssertEqual(p.days[0].date, "2026-08-15")
        XCTAssertEqual(
            p.days[0].acwr,
            try XCTUnwrap(TrainingMetrics.computeACWR(
                sessions: sessions,
                referenceDate: reference,
                timeZone: bangkok
            ).ratio),
            accuracy: 1e-12
        )
    }

    /// Web fixture "a projected zero-load day reproduces what ewmaAcwr computes
    /// the next day" (`acwrProjection.test.ts:107-119`): advance the clock one
    /// day, log nothing, and the real recompute must land where day 1 predicted.
    /// Not bit-identical — the 90-day window slides, so the mean seed decays one
    /// step less than a pure forward step assumes (~1e-4 of the ratio, shrinking
    /// with history) — hence the 1e-3 tolerance, exactly as the web asserts.
    func testProjectedZeroLoadDayReproducesNextDaysComputation() throws {
        let sessions = historySessions(reference: reference)
        let state = try XCTUnwrap(TrainingMetrics.ewmaLoadState(
            sessions: sessions,
            referenceDate: reference,
            timeZone: bangkok
        ))
        let projected = projection(state, nil).days[1].acwr

        let nextDay = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-16", timeZone: bangkok))
        let recomputed = try XCTUnwrap(TrainingMetrics.computeACWR(
            sessions: sessions,
            referenceDate: nextDay,
            timeZone: bangkok
        ).ratio)
        XCTAssertEqual(recomputed, projected, accuracy: 1e-3)
    }

    /// F3 regression: `horizonDays: 0` must return a one-day projection (just
    /// today), exactly as the web's `for (let i = 1; i <= 0; i++)` does — never
    /// trap on the closed range.
    func testHorizonZeroReturnsJustToday() {
        let p = AcwrProjection.project(
            state: EWMALoadState(acute: 300, chronic: 300),
            band: capacityBand,
            horizonDays: 0,
            referenceDate: reference,
            timeZone: bangkok
        )!
        XCTAssertEqual(p.days.count, 1)
        XCTAssertEqual(p.days[0].dayOffset, 0)
        XCTAssertNil(p.fallsBelow)
        XCTAssertNil(p.entersBand)
        XCTAssertNil(p.keepInBand)
    }

    func testProjectsSevenDaysPastToday() {
        let p = projection(EWMALoadState(acute: 300, chronic: 300), capacityBand)
        XCTAssertEqual(p.days.count, 8)
        XCTAssertEqual(p.days.map(\.dayOffset), [0, 1, 2, 3, 4, 5, 6, 7])
        // Dates run today → +7.
        XCTAssertEqual(p.days.last?.date, "2026-08-22")
    }

    func testReturnsNilWithNoStateOrZeroChronicTerm() {
        XCTAssertNil(
            AcwrProjection.project(state: nil, band: capacityBand, referenceDate: reference, timeZone: bangkok)
        )
        XCTAssertNil(
            AcwrProjection.project(
                state: EWMALoadState(acute: 100, chronic: 0),
                band: capacityBand,
                referenceDate: reference,
                timeZone: bangkok
            )
        )
    }

    func testStillProjectsTheCurveWithNoBandButSaysNothingAboutFit() {
        let p = projection(EWMALoadState(acute: 300, chronic: 300), nil)
        XCTAssertEqual(p.days.count, 8)
        XCTAssertTrue(p.days.allSatisfy { $0.fit == nil })
        XCTAssertNil(p.band)
        XCTAssertNil(p.fallsBelow)
        XCTAssertNil(p.entersBand)
        XCTAssertNil(p.keepInBand)
    }

    // MARK: - Band crossing

    func testReportsTheFirstDayTheCurveDropsUnderTheFloor() {
        // 1.00 today, capacity floor 0.90: 0.806 on day 1 is already under.
        let p = projection(EWMALoadState(acute: 300, chronic: 300), capacityBand)
        XCTAssertEqual(p.days[0].fit, .onTarget)
        XCTAssertEqual(p.fallsBelow?.dayOffset, 1)
        XCTAssertNil(p.entersBand)
    }

    func testNeverCrossesInsideTheHorizonYieldsNil() {
        // Floor at 0.10 with a 1.00 start: 0.806^7 ≈ 0.196, still above.
        let p = projection(EWMALoadState(acute: 300, chronic: 300), AcwrProjection.Band(low: 0.1, high: 1.5))
        XCTAssertNil(p.fallsBelow)
        XCTAssertNil(p.keepInBand)
    }

    func testAlreadyBelowTheBandFallsBelowOnDayOne() {
        let p = projection(EWMALoadState(acute: 150, chronic: 300), capacityBand) // 0.50
        XCTAssertEqual(p.days[0].fit, .below)
        XCTAssertEqual(p.fallsBelow?.dayOffset, 1)
        XCTAssertNil(p.entersBand)
    }

    func testAlreadyAboveReportsWhenDecayBringsItBackInThenOut() {
        let p = projection(EWMALoadState(acute: 600, chronic: 300), capacityBand) // 2.00
        XCTAssertEqual(p.days[0].fit, .above)
        // 2.00 → 1.611 → 1.298 → 1.046 (in band) → 0.843 (below)
        XCTAssertEqual(p.entersBand?.dayOffset, 3)
        XCTAssertEqual(p.entersBand?.fit, .onTarget)
        XCTAssertEqual(p.fallsBelow?.dayOffset, 4)
    }

    // MARK: - loadForRatio

    func testLoadForRatioRoundTripsOntoTheRequestedRatio() {
        let states = [
            EWMALoadState(acute: 300, chronic: 300),
            EWMALoadState(acute: 40, chronic: 620),
            EWMALoadState(acute: 900, chronic: 310)
        ]
        for state in states {
            for target in [0.7, 0.9, 1.1, 1.5] {
                let load = AcwrProjection.loadForRatio(state, target: target)!
                let landed = AcwrProjection.acwrOf(AcwrProjection.stepEwmaLoad(state, load: load))!
                XCTAssertEqual(landed, target, accuracy: 1e-12)
            }
        }
    }

    func testLoadForRatioIsNegativeWhenARestDayAlreadyOvershoots() {
        // 2.00 today, aiming for 1.10 — even zero load only decays to 1.61.
        XCTAssertLessThan(AcwrProjection.loadForRatio(EWMALoadState(acute: 600, chronic: 300), target: 1.1)!, 0)
    }

    func testLoadForRatioIsNilWhereNoLoadCanReachTheTargetOrChronicIsZero() {
        let ratio = AcwrProjection.lambdaAcute / AcwrProjection.lambdaChronic
        XCTAssertNil(AcwrProjection.loadForRatio(EWMALoadState(acute: 300, chronic: 300), target: 4))
        XCTAssertNil(AcwrProjection.loadForRatio(EWMALoadState(acute: 300, chronic: 300), target: ratio))
        XCTAssertNil(AcwrProjection.loadForRatio(EWMALoadState(acute: 300, chronic: 0), target: 1))
    }

    // MARK: - keepInBand

    func testKeepInBandPricesTheFloorAsASessionOnTheDropOutDay() {
        let p = projection(EWMALoadState(acute: 300, chronic: 300), capacityBand)
        let s = p.keepInBand!
        XCTAssertEqual(s.dayOffset, p.fallsBelow!.dayOffset)
        XCTAssertEqual(s.date, p.fallsBelow!.date)
        XCTAssertEqual(s.rpe, AcwrProjection.suggestionRPE)
        // The AU it quotes really does land on the floor, from the state on
        // the day BEFORE the session (i.e. resting until then).
        let landed = AcwrProjection.acwrOf(AcwrProjection.stepEwmaLoad(EWMALoadState(acute: 300, chronic: 300), load: s.load))!
        XCTAssertEqual(landed, capacityBand.low, accuracy: 1e-12)
        // …and the minutes are that load at the quoted RPE, rounded to a
        // loggable 5-minute block.
        XCTAssertEqual(s.durationMin % 5, 0)
        XCTAssertLessThanOrEqual(abs(Double(s.durationMin) * s.rpe - s.load), (5 * s.rpe) / 2)
    }

    func testKeepInBandPricesALaterDayOffTheRestedUntilThenState() {
        let state = EWMALoadState(acute: 600, chronic: 300) // 2.00 — falls below on day 4
        let p = projection(state, capacityBand)
        let s = p.keepInBand!
        XCTAssertEqual(s.dayOffset, 4)
        var rested = state
        for _ in 0..<3 { rested = AcwrProjection.stepEwmaLoad(rested, load: 0) }
        let landed = AcwrProjection.acwrOf(AcwrProjection.stepEwmaLoad(rested, load: s.load))!
        XCTAssertEqual(landed, capacityBand.low, accuracy: 1e-12)
    }

    func testKeepInBandIsNilWhenTheCurveNeverLeavesTheBand() {
        let p = projection(EWMALoadState(acute: 300, chronic: 300), AcwrProjection.Band(low: 0.1, high: 1.5))
        XCTAssertNil(p.keepInBand)
    }

    // MARK: - Acceptance-criterion fixtures

    /// ACWR 1.20 against a 0.8–1.3 band: drops below on day 2
    /// (1.20 × 0.80556² ≈ 0.7786 < 0.8) and offers a keep-in-band session.
    func testOnePointTwoAgainstZeroPointEightToOnePointThreeBand() {
        let band = AcwrProjection.Band(low: 0.8, high: 1.3)
        let p = projection(EWMALoadState(acute: 120, chronic: 100), band)
        XCTAssertEqual(p.days[0].acwr, 1.2, accuracy: 1e-12)
        XCTAssertEqual(p.days[0].fit, .onTarget)
        XCTAssertEqual(p.days[1].fit, .onTarget) // 1.20 × 0.80556 = 0.9667
        XCTAssertEqual(p.fallsBelow?.dayOffset, 2)
        XCTAssertEqual(p.days[2].acwr, 1.2 * pow(AcwrProjection.restDayAcwrDecay, 2), accuracy: 1e-6)
        // …and a keep-in-band session is offered.
        XCTAssertNotNil(p.keepInBand)
        XCTAssertEqual(p.keepInBand!.dayOffset, 2)
    }
}
