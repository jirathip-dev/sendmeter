import XCTest
@testable import SendmeterCore

final class TrainingBlockGuidanceTests: XCTestCase {
    private var bangkok: TimeZone { TimeZone(identifier: "Asia/Bangkok") ?? .gmt }

    private func makeMetric(
        dayOffset: Int,
        reference: Date,
        readiness: Int?
    ) -> HealthMetric {
        HealthMetric(
            date: LocalDateSupport.daysAgo(dayOffset, from: reference, timeZone: bangkok),
            readiness: readiness,
            zone: nil,
            computedAt: reference,
            hrvSDNNMilliseconds: nil,
            restingHeartRate: nil,
            sleepHours: nil,
            sleepDeepHours: nil,
            sleepREMHours: nil,
            bodyMassKilograms: nil,
            respiratoryRate: nil
        )
    }

    private func guidance(
        phase: PhaseDefinition,
        week: Int,
        acwr: Double?,
        readinessHistory: [HealthMetric] = [],
        reference: Date
    ) -> BlockGuidance {
        let age = BlockAge(totalDays: week * 7, week: week, dayInWeek: 1)
        return TrainingBlockGuidance.blockGuidance(
            phase: phase,
            age: age,
            acwr: acwr,
            readinessHistory: readinessHistory,
            referenceDate: reference,
            timeZone: bangkok
        )
    }

    func testWithinTypicalDurationContinuesCurrentBlock() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        // Strength typical range is 3–5 weeks; week 2 is comfortably inside.
        let result = guidance(phase: strength, week: 2, acwr: 0.9, reference: reference)
        XCTAssertEqual(result.state, .continueCurrent)
        XCTAssertEqual(result.signals.duration, .within)
        XCTAssertEqual(result.signals.load, .onTarget)
    }

    func testWithinDurationIgnoresSingleLowReadinessAndHighLoad() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        let history = [makeMetric(dayOffset: 0, reference: reference, readiness: 30)]
        let result = guidance(phase: strength, week: 2, acwr: 1.4, readinessHistory: history, reference: reference)
        // Never switches on a single readiness/ACWR datapoint: an in-window
        // block keeps running regardless of one bad day.
        XCTAssertEqual(result.state, .continueCurrent)
        XCTAssertEqual(result.signals.load, .above)
        XCTAssertEqual(result.signals.readiness, .low)
    }

    func testNearingEndReviewsDuration() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        // Week 4 is inside the typical 3–5 range, so it's nearing but not past.
        let result = guidance(phase: strength, week: 4, acwr: 0.9, reference: reference)
        XCTAssertEqual(result.state, .reviewDuration)
        XCTAssertEqual(result.signals.duration, .nearing)
    }

    func testPastEndWithOnTargetLoadConsidersNext() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        let history = [
            makeMetric(dayOffset: 2, reference: reference, readiness: 70),
            makeMetric(dayOffset: 1, reference: reference, readiness: 72),
            makeMetric(dayOffset: 0, reference: reference, readiness: 71)
        ]
        // Week 6 is past the typical 3–5 range, ACWR on target, readiness stable.
        let result = guidance(phase: strength, week: 6, acwr: 0.9, readinessHistory: history, reference: reference)
        XCTAssertEqual(result.state, .considerNext)
        XCTAssertEqual(result.nextPhase, .power)
        XCTAssertEqual(result.signals.duration, .beyond)
        XCTAssertEqual(result.signals.load, .onTarget)
        XCTAssertEqual(result.signals.readiness, .stable)
    }

    func testLowReadinessWithAboveTargetLoadConsidersRecovery() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        let history = [
            makeMetric(dayOffset: 2, reference: reference, readiness: 60),
            makeMetric(dayOffset: 1, reference: reference, readiness: 45),
            makeMetric(dayOffset: 0, reference: reference, readiness: 30)
        ]
        // Fatigue: past end, low readiness, load above the target band.
        let result = guidance(phase: strength, week: 6, acwr: 1.2, readinessHistory: history, reference: reference)
        XCTAssertEqual(result.state, .considerRecovery)
        XCTAssertEqual(result.signals.load, .above)
        XCTAssertEqual(result.signals.readiness, .low)
    }

    func testFallingReadinessAcrossDaysConsidersRecovery() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        let history = [
            makeMetric(dayOffset: 3, reference: reference, readiness: 78),
            makeMetric(dayOffset: 2, reference: reference, readiness: 72),
            makeMetric(dayOffset: 1, reference: reference, readiness: 66),
            makeMetric(dayOffset: 0, reference: reference, readiness: 55)
        ]
        // 55 is above the low threshold but a clear multi-day decline.
        let result = guidance(phase: strength, week: 6, acwr: 1.1, readinessHistory: history, reference: reference)
        XCTAssertEqual(result.state, .considerRecovery)
        XCTAssertEqual(result.signals.readiness, .falling)
    }

    func testExecutionAtEndHasNoForcedNext() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let execution = PhaseCatalog.definition(for: .execution)
        let history = [
            makeMetric(dayOffset: 1, reference: reference, readiness: 70),
            makeMetric(dayOffset: 0, reference: reference, readiness: 70)
        ]
        let result = guidance(phase: execution, week: 4, acwr: 0.8, readinessHistory: history, reference: reference)
        XCTAssertEqual(result.nextPhase, nil)
        XCTAssertNotEqual(result.state, .considerNext, "Execution has no natural successor")
        XCTAssertEqual(result.state, .reviewDuration)
        XCTAssertEqual(result.signals.duration, .beyond)
        XCTAssertEqual(result.signals.load, .onTarget)
    }

    func testMissingACWRIsConservative() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        let history = [
            makeMetric(dayOffset: 1, reference: reference, readiness: 70),
            makeMetric(dayOffset: 0, reference: reference, readiness: 70)
        ]
        let result = guidance(phase: strength, week: 6, acwr: nil, readinessHistory: history, reference: reference)
        XCTAssertEqual(result.signals.load, .noData)
        XCTAssertEqual(result.state, .reviewDuration, "No ACWR means no on-target confirmation")
    }

    func testMissingReadinessIsConservative() throws {
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let strength = PhaseCatalog.definition(for: .strength)
        let result = guidance(phase: strength, week: 6, acwr: 0.9, readinessHistory: [], reference: reference)
        XCTAssertEqual(result.signals.readiness, .noData)
        XCTAssertEqual(result.state, .reviewDuration, "No readiness trend means no healthy-end confirmation")
    }
}
