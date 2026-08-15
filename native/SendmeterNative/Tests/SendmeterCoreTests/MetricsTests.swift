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
}
