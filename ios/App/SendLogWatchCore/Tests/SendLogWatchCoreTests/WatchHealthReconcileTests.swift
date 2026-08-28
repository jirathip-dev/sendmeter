import Foundation
import XCTest
@testable import SendLogWatchCore

final class WatchHealthReconcileTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Bangkok")!
    private let today = "2026-08-28"

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private func date(day: Int, hour: Int = 6) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour)
        )!
    }

    private func metric(
        date: String,
        readiness: Int? = 80,
        computedAt: Date? = nil,
        hrv: Double? = 60
    ) -> WatchHealthMetric {
        WatchHealthMetric(
            date: date,
            readiness: readiness,
            zone: readiness == nil ? nil : "maintain",
            computedAt: computedAt,
            hrvSDNNMilliseconds: hrv,
            restingHeartRate: nil,
            sleepHours: nil,
            sleepDeepHours: nil,
            sleepREMHours: nil,
            bodyMassKilograms: nil,
            respiratoryRate: nil
        )
    }

    func testWholeWindowPlanFillsMissingHistoricalDates() {
        let fresh = [
            metric(date: "2026-08-28", computedAt: date(day: 28)),
            metric(date: "2026-08-27", computedAt: date(day: 27)),
            metric(date: "2026-08-26", computedAt: date(day: 26)),
        ]
        let plan = WatchHealthReconcile.plan(
            freshMetrics: fresh,
            existingToday: nil,
            existingDates: ["2026-08-26", "2026-08-25"],
            today: today,
            now: date(day: 28),
            timeZone: timeZone
        )
        // Today written (no existing), Aug 27 missing → filled, Aug 26 present → skipped.
        XCTAssertEqual(plan.upserts.map(\.date).sorted(), ["2026-08-27", "2026-08-28"])
        XCTAssertEqual(plan.reconciledDates.sorted(), ["2026-08-27", "2026-08-28"])
        XCTAssertEqual(plan.reconciledCount, 2)
        XCTAssertEqual(plan.todayMetric?.date, "2026-08-28")
    }

    /// Two computed metrics for the SAME date: the newest `computedAt` wins
    /// the per-date dedupe (mirrors the phone's #801 latest-wins rule).
    func testDuplicateDateMetricsKeepTheNewestComputedTimestamp() {
        let older = metric(date: "2026-08-27", readiness: 60, computedAt: date(day: 27, hour: 6))
        let newer = metric(date: "2026-08-27", readiness: 90, computedAt: date(day: 27, hour: 9))
        let plan = WatchHealthReconcile.plan(
            freshMetrics: [older, newer],
            existingToday: nil,
            existingDates: [],
            today: today,
            now: date(day: 28),
            timeZone: timeZone
        )
        XCTAssertEqual(plan.upserts.map(\.date), ["2026-08-27"])
        XCTAssertEqual(plan.upserts.first?.readiness, 90)
    }

    func testTodayRetainedWhenFreshScoredRowExists() {
        let existing = metric(
            date: today,
            readiness: 85,
            computedAt: date(day: 28, hour: 5)
        )
        let fresh = [metric(date: today, computedAt: date(day: 28, hour: 7))]
        let plan = WatchHealthReconcile.plan(
            freshMetrics: fresh,
            existingToday: existing,
            existingDates: [today],
            today: today,
            now: date(day: 28, hour: 7),
            timeZone: timeZone
        )
        XCTAssertTrue(plan.upserts.isEmpty, "fresh non-empty row must be retained")
        XCTAssertTrue(plan.reconciledDates.isEmpty)
        XCTAssertEqual(plan.todayMetric?.readiness, 85)
    }

    func testTodayWinsOverFreshButEmptyRow() {
        // Guy's rule: watch wins when the phone row is EMPTY — even a fresh
        // empty row (e.g. a legacy row carrying only a score, no biometrics).
        let existing = metric(date: today, readiness: nil, computedAt: date(day: 28, hour: 5), hrv: nil)
        let fresh = [metric(date: today, readiness: 82, computedAt: date(day: 28, hour: 7))]
        let plan = WatchHealthReconcile.plan(
            freshMetrics: fresh,
            existingToday: existing,
            existingDates: [today],
            today: today,
            now: date(day: 28, hour: 7),
            timeZone: timeZone
        )
        XCTAssertEqual(plan.upserts.map(\.date), [today])
        XCTAssertEqual(plan.todayMetric?.readiness, 82)
    }

    func testTodayWritesWhenStaleRowExists() {
        // Row computed yesterday (for today's date) is stale → watch wins.
        let existing = metric(date: today, readiness: 70, computedAt: date(day: 27, hour: 20))
        let fresh = [metric(date: today, readiness: 88, computedAt: date(day: 28, hour: 6))]
        let plan = WatchHealthReconcile.plan(
            freshMetrics: fresh,
            existingToday: existing,
            existingDates: [today],
            today: today,
            now: date(day: 28, hour: 6),
            timeZone: timeZone
        )
        XCTAssertEqual(plan.upserts.map(\.date), [today])
        XCTAssertEqual(plan.todayMetric?.readiness, 88)
    }

    func testTodayWriteKeepsExistingScoreWhenOverwriteForbidden() {
        let existing = metric(date: today, readiness: 74, computedAt: date(day: 27, hour: 20))
        let fresh = [metric(date: today, readiness: 88, computedAt: date(day: 28, hour: 6))]
        let plan = WatchHealthReconcile.plan(
            freshMetrics: fresh,
            existingToday: existing,
            existingDates: [today],
            today: today,
            now: date(day: 28, hour: 6),
            timeZone: timeZone,
            allowReadinessOverwrite: false
        )
        XCTAssertEqual(plan.upserts.count, 1)
        XCTAssertNil(plan.upserts[0].readiness, "readiness must be omitted to keep the row")
        XCTAssertNil(plan.upserts[0].computedAt)
        XCTAssertEqual(plan.todayMetric?.readiness, 74)
    }

    func testSourceLessFreshMetricIsNeverWritten() {
        let fresh = [metric(date: today, readiness: nil, computedAt: date(day: 28, hour: 6), hrv: nil)]
        let plan = WatchHealthReconcile.plan(
            freshMetrics: fresh,
            existingToday: nil,
            existingDates: [],
            today: today,
            now: date(day: 28, hour: 6),
            timeZone: timeZone
        )
        XCTAssertTrue(plan.upserts.isEmpty)
        XCTAssertTrue(plan.sourceDataDates.isEmpty, "no source-backed date observed")
    }

    func testHistoricalUpsertsOnlyMissingSourceBackedDates() {
        let fresh = [
            metric(date: "2026-08-25", computedAt: date(day: 25)),
            metric(date: "2026-08-24", computedAt: date(day: 24)),
            metric(date: today, computedAt: date(day: 28)),
        ]
        let upserts = WatchHealthReconcile.historicalUpserts(
            freshMetrics: fresh,
            existingDates: ["2026-08-24"],
            today: today
        )
        XCTAssertEqual(upserts.map(\.date), ["2026-08-25"])
    }
}
