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
        XCTAssertEqual(RecoveryBarGradient.position(value: 120, baseline: 100), 0.6, accuracy: 0.0001)
        XCTAssertEqual(RecoveryBarGradient.position(value: 80, baseline: 100), 0.4, accuracy: 0.0001)
    }

    func testBothTrendsUseSixtyDayWarmup() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let metrics = (0..<60).map { makeMetric(dayOffset: 59 - $0, reference: reference, hrv: Double($0 + 1)) }
        let series = RecoveryInputsSeries.build(metrics: metrics, referenceDate: reference, timeZone: bangkok)
        let hrv = try XCTUnwrap(series.rows.first { $0.metric == .hrv })
        XCTAssertTrue(hrv.days.allSatisfy { $0.trend != nil && $0.trend28 != nil })
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
