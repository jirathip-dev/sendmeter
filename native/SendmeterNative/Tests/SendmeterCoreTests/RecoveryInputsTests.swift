import XCTest
@testable import SendmeterCore

final class RecoveryInputsTests: XCTestCase {
    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!

    func testBuildReturnsFourteenSharedDaysOldestToNewest() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let series = RecoveryInputsSeries.build(
            metrics: [],
            referenceDate: reference,
            timeZone: bangkok
        )
        XCTAssertEqual(series.days.count, 14)
        XCTAssertEqual(series.days.first?.date, "2026-08-02")
        XCTAssertEqual(series.days.last?.date, "2026-08-15")
        XCTAssertEqual(series.days.map(\.date), series.days.map(\.date).sorted())
        XCTAssertFalse(series.hasData)
    }

    func testBuildMapsRawHealthMetricsIntoRows() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let metric = makeMetric(
            dayOffset: 0,
            reference: reference,
            hrv: 62,
            rhr: 48,
            resp: 13.4,
            sleep: 7.5,
            deep: 1.2,
            rem: 1.8,
            weight: 65.4
        )
        let series = RecoveryInputsSeries.build(
            metrics: [metric],
            referenceDate: reference,
            timeZone: bangkok
        )
        XCTAssertEqual(series.rows.count, 7, "all supplied metrics render")
        let hrv = try XCTUnwrap(series.rows.first { $0.metric == .hrv })
        XCTAssertEqual(hrv.latestDay?.value, 62)
        XCTAssertEqual(hrv.days.last?.dateValue, reference)
        let weight = try XCTUnwrap(series.rows.first { $0.metric == .bodyMass })
        XCTAssertEqual(weight.latestDay?.value, 65.4)
    }

    func testPartialDataRendersOnlyPopulatedMetrics() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let hrv = makeMetric(dayOffset: 1, reference: reference, hrv: 55)
        let weight = makeMetric(dayOffset: 0, reference: reference, weight: 64)
        let series = RecoveryInputsSeries.build(
            metrics: [hrv, weight],
            referenceDate: reference,
            timeZone: bangkok
        )
        XCTAssertTrue(series.hasData)
        XCTAssertEqual(series.rows.map(\.metric).sorted { $0.id < $1.id }, [.hrv, .bodyMass].sorted { $0.id < $1.id })
        XCTAssertFalse(series.rows.contains { $0.metric == .deepSleep }, "a metric with no visible value stays out of the data rows")
    }

    func testTrendAndRunsHonorMissingDays() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        // Two contiguous readings, one missing day, then two more readings.
        let metrics = [
            makeMetric(dayOffset: 13, reference: reference, hrv: 50),
            makeMetric(dayOffset: 12, reference: reference, hrv: 60),
            makeMetric(dayOffset: 10, reference: reference, hrv: 70),
            makeMetric(dayOffset: 9, reference: reference, hrv: 80)
        ]
        let series = RecoveryInputsSeries.build(
            metrics: metrics,
            referenceDate: reference,
            timeZone: bangkok
        )
        let hrv = try XCTUnwrap(series.rows.first { $0.metric == .hrv })
        for day in hrv.days {
            if day.value == nil {
                XCTAssertNil(day.trend, "a gap day never carries a trend point")
                XCTAssertNil(day.runIndex, "a gap day never belongs to a trend run")
            } else {
                XCTAssertNotNil(day.trend, "a present day always has an EWMA value")
                XCTAssertNotNil(day.runIndex)
            }
        }
        let dates = hrv.days.filter { $0.value != nil }.map(\.date)
        XCTAssertEqual(dates.count, 4)
        XCTAssertNotEqual(hrv.days[0].runIndex, hrv.days[3].runIndex, "a missing day separates the two runs")
    }

    func testWeightRespectsImperialPreference() {
        let value = RecoveryMetric.bodyMass.formattedWithUnit(65.4, for: .imperial)
        XCTAssertEqual(value, "144.2 lb")
        XCTAssertEqual(RecoveryMetric.bodyMass.formattedWithUnit(65.4, for: .metric), "65.4 kg")
    }

    func testFormattingMatchesWebCard() {
        XCTAssertEqual(RecoveryMetric.hrv.formattedWithUnit(62.3, for: .metric), "62 ms")
        XCTAssertEqual(RecoveryMetric.restingHeartRate.formattedWithUnit(48.4, for: .metric), "48 bpm")
        XCTAssertEqual(RecoveryMetric.respiratoryRate.formattedWithUnit(13.4, for: .metric), "13.4 brpm")
        XCTAssertEqual(RecoveryMetric.sleep.formattedWithUnit(7.5, for: .metric), "7.5 h")
    }

    func testDuplicateDatesResolveLastWins() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let older = makeMetric(dayOffset: 0, reference: reference, hrv: 50)
        let newer = makeMetric(dayOffset: 0, reference: reference, hrv: 80)
        let series = RecoveryInputsSeries.build(
            metrics: [older, newer],
            referenceDate: reference,
            timeZone: bangkok
        )
        let hrv = try XCTUnwrap(series.rows.first { $0.metric == .hrv })
        XCTAssertEqual(hrv.latestDay?.value, 80)
    }

    func testGradientClassificationBoundariesAndSmoothPosition() {
        XCTAssertEqual(RecoveryBarGradient.classification(value: 100, baseline: 100), .neutral)
        XCTAssertEqual(RecoveryBarGradient.classification(value: 101, baseline: 100), .neutral)
        XCTAssertEqual(RecoveryBarGradient.classification(value: 103, baseline: 100), .above)
        XCTAssertEqual(RecoveryBarGradient.classification(value: 97, baseline: 100), .below)
        // The first-fix ramp needed a ±100% excursion to reach an endpoint,
        // which real readings never make — every bar rendered the same mid
        // blue on device (#753 Build 50). Saturation is now bounded at 12%
        // relative distance, so ordinary variance is visible.
        XCTAssertEqual(RecoveryBarGradient.position(value: 112, baseline: 100), 1.0, accuracy: 0.0001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 88, baseline: 100), 0.0, accuracy: 0.0001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 500, baseline: 100), 1.0, accuracy: 0.0001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 20, baseline: 100), 0.0, accuracy: 0.0001)
        // Inside the band the position stays smooth: 3%/6% excursions above
        // and below their 28-day baseline land at distinct, strongly-tinted
        // positions (the exponents differ per direction so the below ramp
        // escapes the gray-green middle of the yellow↔blue sRGB blend).
        XCTAssertEqual(RecoveryBarGradient.position(value: 106, baseline: 100), 0.8628198181, accuracy: 0.0000001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 103, baseline: 100), 0.7233417961, accuracy: 0.0000001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 97, baseline: 100), 0.0841181144, accuracy: 0.0000001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 94, baseline: 100), 0.0353405183, accuracy: 0.0000001)
        // The ±2% deadband stays exactly neutral.
        XCTAssertEqual(RecoveryBarGradient.position(value: 102, baseline: 100), 0.5, accuracy: 0.0001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 100, baseline: 100), 0.5, accuracy: 0.0001)
    }

    /// #753: a wear gap must never re-seed or zero the 28-day recurrence
    /// (Capacitor parity). Values 40+offset across offsets 40...0 with offset
    /// 8 missing must continue the running state through the gap: the visible
    /// window's 28d values equal the null-aware recurrence (alpha = 2/29,
    /// first non-null seeds at 80, nil days carry state untouched), the gap
    /// day carries no trend point, and the day after the gap belongs to a new
    /// run with the carried value — not a re-seed at its own reading.
    func testTwentyEightDayEWMACarriesStateAcrossVisibleGap() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let metrics = (0..<41).compactMap { offset -> HealthMetric? in
            guard offset != 8 else { return nil }
            return makeMetric(dayOffset: offset, reference: reference, hrv: 40 + Double(offset))
        }
        let series = RecoveryInputsSeries.build(metrics: metrics, referenceDate: reference, timeZone: bangkok)
        let hrv = try XCTUnwrap(series.rows.first { $0.metric == .hrv })
        let expectedTrend28: [Int: Double] = [
            13: 64.539307636, 12: 63.674527799, 11: 62.800422433, 10: 61.917634679,
            9: 61.026763322, 7: 60.059400334, 6: 59.089786518, 5: 58.118077103,
            4: 57.144416613, 3: 56.168939606, 2: 55.191771357, 1: 54.213028505,
            0: 53.232819642
        ]
        var sawGap = false
        for (index, day) in hrv.days.enumerated() {
            let offset = 13 - index
            if offset == 8 {
                sawGap = true
                XCTAssertNil(day.value)
                XCTAssertNil(day.trend)
                XCTAssertNil(day.trend28)
                XCTAssertNil(day.runIndex, "the gap day never belongs to a trend run")
                continue
            }
            let expected = try XCTUnwrap(expectedTrend28[offset])
            XCTAssertEqual(try XCTUnwrap(day.trend28), expected, accuracy: 0.0000001)
        }
        XCTAssertTrue(sawGap)
        // The day after the gap carries the pre-gap state instead of
        // re-seeding at its own value (47) or inventing a zero, and the
        // visible gap splits the runs.
        let dayAfterGap = hrv.days[6] // index 5 is the offset-8 gap day
        XCTAssertEqual(dayAfterGap.runIndex, 2)
        XCTAssertEqual(try XCTUnwrap(dayAfterGap.trend28), 60.059400334, accuracy: 0.0000001)
        XCTAssertGreaterThan(try XCTUnwrap(dayAfterGap.trend28), 47)
    }

    func testBothTrendsUseSixtyDayWarmup() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let metrics = (0..<60).map { makeMetric(dayOffset: 59 - $0, reference: reference, hrv: Double($0 + 1)) }
        let series = RecoveryInputsSeries.build(metrics: metrics, referenceDate: reference, timeZone: bangkok)
        let hrv = try XCTUnwrap(series.rows.first { $0.metric == .hrv })
        let latest = try XCTUnwrap(hrv.days.last)
        XCTAssertEqual(try XCTUnwrap(latest.trend), 57.00000012756625, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(latest.trend28), 46.69921130379113, accuracy: 0.0000001)
    }

    private func makeMetric(
        dayOffset: Int,
        reference: Date,
        hrv: Double? = nil,
        rhr: Double? = nil,
        resp: Double? = nil,
        sleep: Double? = nil,
        deep: Double? = nil,
        rem: Double? = nil,
        weight: Double? = nil
    ) -> HealthMetric {
        HealthMetric(
            date: LocalDateSupport.daysAgo(dayOffset, from: reference, timeZone: bangkok),
            readiness: nil,
            zone: nil,
            computedAt: reference,
            hrvSDNNMilliseconds: hrv,
            restingHeartRate: rhr,
            sleepHours: sleep,
            sleepDeepHours: deep,
            sleepREMHours: rem,
            bodyMassKilograms: weight,
            respiratoryRate: resp
        )
    }
}
