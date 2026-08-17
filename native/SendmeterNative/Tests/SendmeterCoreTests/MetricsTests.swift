import XCTest
@testable import SendmeterCore

final class MetricsTests: XCTestCase {
    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!

    func testACWRStatusThresholdsMatchProductContract() {
        XCTAssertEqual(TrainingMetrics.acwrStatus(nil), .noData)
        XCTAssertEqual(TrainingMetrics.acwrStatus(0.69), .underTraining)
        XCTAssertEqual(TrainingMetrics.acwrStatus(0.70), .low)
        XCTAssertEqual(TrainingMetrics.acwrStatus(0.80), .low)
        XCTAssertEqual(TrainingMetrics.acwrStatus(0.81), .optimal)
        XCTAssertEqual(TrainingMetrics.acwrStatus(1.30), .optimal)
        XCTAssertEqual(TrainingMetrics.acwrStatus(1.31), .caution)
        XCTAssertEqual(TrainingMetrics.acwrStatus(1.50), .caution)
        XCTAssertEqual(TrainingMetrics.acwrStatus(1.51), .danger)
    }

    func testEWMAIsNullAware() {
        let result = TrainingMetrics.ewma(values: [nil, 10, nil, 20], span: 3)
        XCTAssertNil(result[0])
        XCTAssertEqual(result[1], 10)
        XCTAssertEqual(result[2], 10)
        XCTAssertEqual(result[3], 15)
    }

    func testACWRUsesNinetyDayMeanSeededEWMA() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        var sessions: [Session] = []
        for offset in 0..<14 {
            sessions.append(
                Session(
                    id: UUID(),
                    date: LocalDateSupport.daysAgo(offset, from: reference, timeZone: bangkok),
                    type: "board",
                    typeLabel: "Board Climbing",
                    durationMinutes: 60,
                    rpe: offset < 7 ? 8 : 4,
                    phase: .strength
                )
            )
        }
        let data = TrainingMetrics.computeACWR(
            sessions: sessions,
            referenceDate: reference,
            timeZone: bangkok
        )
        XCTAssertEqual(data.acute, 3_360, accuracy: 0.0001)
        XCTAssertEqual(data.chronic, 1_260, accuracy: 0.0001)
        XCTAssertNotNil(data.ratio)
        XCTAssertGreaterThan(data.ratio!, 1)
    }

    func testPhaseAgeUsesCanonicalOpenPeriod() {
        let periods = [
            PhasePeriod(
                id: UUID(),
                phase: .strength,
                startedOn: "2026-08-01",
                endedOn: nil
            )
        ]
        let age = TrainingMetrics.phaseBlockAge(
            periods: periods,
            currentPhase: .strength,
            fallbackStartDate: "2026-08-10",
            referenceDate: "2026-08-15",
            timeZone: bangkok
        )
        XCTAssertEqual(age, BlockAge(totalDays: 15, week: 3, dayInWeek: 1))
    }

    func testThreeLowReadinessDaysSuggestStepBackOnlyInLoadingPhases() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let history = (0..<3).map { offset in
            HealthMetric(
                date: LocalDateSupport.daysAgo(offset, from: reference, timeZone: bangkok),
                readiness: 35,
                zone: "recover",
                computedAt: reference,
                hrvSDNNMilliseconds: 40,
                restingHeartRate: 55,
                sleepHours: 7,
                sleepDeepHours: 1,
                sleepREMHours: 1.5,
                bodyMassKilograms: 65,
                respiratoryRate: 13
            )
        }
        XCTAssertTrue(
            TrainingMetrics.phaseStepBackSuggestion(
                readinessHistory: history,
                currentPhase: .strength,
                referenceDate: reference,
                timeZone: bangkok
            ).suggested
        )
        XCTAssertFalse(
            TrainingMetrics.phaseStepBackSuggestion(
                readinessHistory: history,
                currentPhase: .capacity,
                referenceDate: reference,
                timeZone: bangkok
            ).suggested
        )
    }

    // MARK: ACWR ratio (#661 F2)

    func testAcwrRatioMatchesComputeACWRForSameLoadSeries() throws {
        // A 90-day series with the last 4 days at heavy load — enough for a
        // chronic > 0 EWMA. The pure `acwrRatio` must produce the same ratio
        // as `computeACWR` fed an equivalent session list (the recompute path
        // reads the server, never in-memory sessions).
        var dailyLoads = Array(repeating: 0.0, count: 86)
        dailyLoads += [120, 120, 120, 120]
        let ratio = try XCTUnwrap(TrainingMetrics.acwrRatio(dailyLoads: dailyLoads))

        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-17", timeZone: bangkok))
        let sessions: [Session] = dailyLoads.enumerated().compactMap { offset, load in
            guard load > 0 else { return nil }
            return Session(
                id: UUID(),
                date: LocalDateSupport.daysAgo(dailyLoads.count - 1 - offset, from: reference, timeZone: bangkok),
                type: "fingerboard",
                typeLabel: "Fingerboard",
                durationMinutes: 10,
                rpe: 6,
                load: load,
                phase: .strength
            )
        }
        let expected = try XCTUnwrap(TrainingMetrics.computeACWR(
            sessions: sessions,
            referenceDate: reference,
            timeZone: bangkok
        ).ratio)
        XCTAssertEqual(ratio, expected, accuracy: 0.000001)
    }

    func testAcwrRatioNilWhenNoLoad() {
        XCTAssertNil(TrainingMetrics.acwrRatio(dailyLoads: Array(repeating: 0.0, count: 90)))
    // MARK: Readiness trend series (#664)

    private func makeMetric(
        dayOffset: Int,
        reference: Date,
        readiness: Int? = nil,
        zone: String? = nil,
        hrv: Double? = nil,
        rhr: Double? = nil,
        sleep: Double? = nil
    ) -> HealthMetric {
        HealthMetric(
            date: LocalDateSupport.daysAgo(dayOffset, from: reference, timeZone: bangkok),
            readiness: readiness,
            zone: zone,
            computedAt: reference,
            hrvSDNNMilliseconds: hrv,
            restingHeartRate: rhr,
            sleepHours: sleep,
            sleepDeepHours: nil,
            sleepREMHours: nil,
            bodyMassKilograms: nil,
            respiratoryRate: nil
        )
    }

    func testReadinessSeriesReturnsFourteenDaysOldestToNewest() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let series = TrainingMetrics.readinessSeries(metrics: [], referenceDate: reference, timeZone: bangkok)
        XCTAssertEqual(series.count, 14)
        XCTAssertEqual(series.first?.date, "2026-08-02")
        XCTAssertEqual(series.last?.date, "2026-08-15")
        XCTAssertEqual(series.map(\.date), series.map(\.date).sorted(), "dates are oldest → newest")
    }

    func testReadinessSeriesMapsMetricsToTheirCalendarDay() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let metrics = [
            makeMetric(dayOffset: 0, reference: reference, readiness: 82, zone: "push", hrv: 62, rhr: 48, sleep: 7.5),
            makeMetric(dayOffset: 1, reference: reference, readiness: 55, zone: "maintain"),
            makeMetric(dayOffset: 2, reference: reference, readiness: 28, zone: "recover")
        ]
        let series = TrainingMetrics.readinessSeries(metrics: metrics, referenceDate: reference, timeZone: bangkok)
        XCTAssertEqual(series[13].readiness, 82)
        XCTAssertEqual(series[13].zone, "push")
        XCTAssertEqual(series[13].hrvSDNNMilliseconds, 62)
        XCTAssertEqual(series[13].restingHeartRate, 48)
        XCTAssertEqual(series[13].sleepHours, 7.5)
        XCTAssertEqual(series[12].readiness, 55)
        XCTAssertEqual(series[11].readiness, 28)
    }

    func testReadinessSeriesGapsRenderNil() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let series = TrainingMetrics.readinessSeries(
            metrics: [makeMetric(dayOffset: 0, reference: reference, readiness: 70, zone: "push")],
            referenceDate: reference,
            timeZone: bangkok
        )
        XCTAssertNil(series[12].readiness, "a missing day reads as no data")
        XCTAssertEqual(series[13].readiness, 70, "the single metric lands on its calendar day")
    }

    func testReadinessSeriesIgnoresMetricsOutsideTheWindow() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let series = TrainingMetrics.readinessSeries(
            metrics: [makeMetric(dayOffset: 14, reference: reference, readiness: 90, zone: "push")],
            referenceDate: reference,
            timeZone: bangkok
        )
        XCTAssertEqual(series.map(\.readiness), Array(repeating: nil, count: 14), "an out-of-window metric is never plotted")
    }

    func testReadinessSeriesPinsDateValuesToGregorianDays() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let series = TrainingMetrics.readinessSeries(metrics: [], referenceDate: reference, timeZone: bangkok)
        // Independent reference — NOT LocalDateSupport, so a fallback to
        // Calendar.current (Buddhist on a Thai-region device, year +543)
        // fails this test. Review F8: the old assertion checked the
        // implementation against the same helper it calls, so it could never
        // catch the calendar regression this repo was burned by.
        let gregorianFormatter = DateFormatter()
        gregorianFormatter.calendar = Calendar(identifier: .gregorian)
        gregorianFormatter.locale = Locale(identifier: "en_US_POSIX")
        gregorianFormatter.timeZone = bangkok
        gregorianFormatter.dateFormat = "yyyy-MM-dd"
        for day in series {
            XCTAssertEqual(day.dateValue, gregorianFormatter.date(from: day.date),
                           "dateValue is the Gregorian date string's calendar day")
            XCTAssertEqual(day.date.prefix(4), "2026",
                           "series date strings must carry the Gregorian year, not the Buddhist year")
        }
    }

    func testReadinessSeriesGroupsContiguousScoredDaysIntoRuns() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        // Scored 08-02..08-04 (offsets 13..11), gap 08-05..08-14, scored 08-15.
        let metrics = [
            makeMetric(dayOffset: 13, reference: reference, readiness: 60, zone: "maintain"),
            makeMetric(dayOffset: 12, reference: reference, readiness: 55, zone: "maintain"),
            makeMetric(dayOffset: 11, reference: reference, readiness: 50, zone: "maintain"),
            makeMetric(dayOffset: 0, reference: reference, readiness: 80, zone: "push")
        ]
        let series = TrainingMetrics.readinessSeries(metrics: metrics, referenceDate: reference, timeZone: bangkok)
        XCTAssertEqual(series[0].runIndex, 1, "first run starts at 08-02")
        XCTAssertEqual(series[1].runIndex, 1)
        XCTAssertEqual(series[2].runIndex, 1)
        for index in 3..<13 {
            XCTAssertNil(series[index].runIndex, "gap day \(series[index].date) has no run")
        }
        XCTAssertEqual(series[13].runIndex, 2, "08-15 starts a new run after the gap")
        XCTAssertEqual(series.map(\.runIndex).compactMap { $0 }.max(), 2)
    }

    func testReadinessSeriesTwoDaysOfDataKeepHonestGaps() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        // A brand-new user: exactly two scored days, everything else a gap.
        let metrics = [
            makeMetric(dayOffset: 1, reference: reference, readiness: 60, zone: "maintain"),
            makeMetric(dayOffset: 0, reference: reference, readiness: 70, zone: "push")
        ]
        let series = TrainingMetrics.readinessSeries(metrics: metrics, referenceDate: reference, timeZone: bangkok)
        XCTAssertEqual(series.filter { $0.readiness != nil }.count, 2)
        XCTAssertEqual(series.filter { $0.runIndex != nil }.count, 2, "only the two scored days belong to a run")
        XCTAssertEqual(series[12].runIndex, 1)
        XCTAssertEqual(series[13].runIndex, 1)
    }

    func testReadinessSeriesDuplicateDatesResolveLastWins() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let older = makeMetric(dayOffset: 0, reference: reference, readiness: 50, zone: "maintain")
        let newer = makeMetric(dayOffset: 0, reference: reference, readiness: 80, zone: "push")
        XCTAssertEqual(older.date, newer.date, "both rows share the duplicate date")
        let series = TrainingMetrics.readinessSeries(metrics: [older, newer], referenceDate: reference, timeZone: bangkok)
        XCTAssertEqual(series.last?.readiness, 80, "duplicate date resolves last-wins like the web's Map")
    }
}
