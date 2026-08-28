import Foundation
import XCTest
@testable import SendLogWatchCore

final class HealthMetricPrecedenceTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Bangkok")!

    private func row(
        date: String = "2026-08-28",
        computedAt: Date?,
        hasSourceData: Bool = true
    ) -> HealthPrecedenceRow {
        HealthPrecedenceRow(date: date, computedAt: computedAt, hasSourceData: hasSourceData)
    }

    // MARK: write site — watch

    func testWatchDiscardsEmptyCandidateEvenWhenRowMissing() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 6), hasSourceData: false),
            existing: nil,
            writer: .watch,
            now: date(28, hour: 6),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .discardCandidate)
    }

    func testWatchWritesWhenNoExistingRow() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 6)),
            existing: nil,
            writer: .watch,
            now: date(28, hour: 6),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .writeCandidate)
    }

    func testWatchRetainsFreshNonEmptyPhoneRow() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 6)),
            existing: row(computedAt: date(28, hour: 8)),
            writer: .watch,
            now: date(28, hour: 9),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .retainExisting)
    }

    func testWatchRetainsItsOwnEarlierFreshRowNoFlapping() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 6)),
            existing: row(computedAt: date(28, hour: 5)),
            writer: .watch,
            now: date(28, hour: 7),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .retainExisting)
    }

    func testWatchWritesOverStaleRowComputedYesterday() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 6)),
            existing: row(computedAt: date(27, hour: 23)),
            writer: .watch,
            now: date(28, hour: 6),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .writeCandidate)
    }

    func testWatchWritesOverFreshButEmptyRow() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 6)),
            existing: row(computedAt: date(28, hour: 5), hasSourceData: false),
            writer: .watch,
            now: date(28, hour: 6),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .writeCandidate)
    }

    func testWatchWritesOverRowWithoutComputedTimestamp() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 6)),
            existing: row(computedAt: nil),
            writer: .watch,
            now: date(28, hour: 6),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .writeCandidate)
    }

    func testWatchWriteIsDayBoundaryDeterministic() {
        // 00:30 — the phone row is YESTERDAY's compute: stale, watch wins.
        let early = HealthMetricPrecedence.decide(
            candidate: row(date: "2026-08-28", computedAt: date(28, hour: 0)),
            existing: row(date: "2026-08-28", computedAt: date(27, hour: 22)),
            writer: .watch,
            now: date(28, hour: 0),
            timeZone: timeZone
        )
        XCTAssertEqual(early, .writeCandidate)
    }

    // MARK: write site — phone

    func testPhoneWinsWheneverItHasNonEmptyCandidate() {
        // Even against a fresh non-empty watch row: phone wins per Guy's
        // locked rule.
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 9)),
            existing: row(computedAt: date(28, hour: 5)),
            writer: .phone,
            now: date(28, hour: 9),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .writeCandidate)
    }

    func testPhoneStillDiscardsEmptyCandidate() {
        let decision = HealthMetricPrecedence.decide(
            candidate: row(computedAt: date(28, hour: 9), hasSourceData: false),
            existing: row(computedAt: date(28, hour: 5)),
            writer: .phone,
            now: date(28, hour: 9),
            timeZone: timeZone
        )
        XCTAssertEqual(decision, .discardCandidate)
    }

    // MARK: freshness

    func testIsFreshSameLocalDayOnly() {
        XCTAssertTrue(
            HealthMetricPrecedence.isFresh(
                row(computedAt: date(28, hour: 23, minute: 50)),
                now: date(28, hour: 0),
                timeZone: timeZone
            )
        )
        XCTAssertFalse(
            HealthMetricPrecedence.isFresh(
                row(computedAt: date(27, hour: 23, minute: 50)),
                now: date(28, hour: 0),
                timeZone: timeZone
            )
        )
        XCTAssertFalse(
            HealthMetricPrecedence.isFresh(
                row(computedAt: nil),
                now: date(28, hour: 0),
                timeZone: timeZone
            )
        )
    }

    /// Regression (hosted CI, UTC Linux): `isFresh` must honor the EXPLICIT
    /// timeZone, never the host's. 00:30 Bangkok on Aug 28 IS the 27th
    /// 17:30 UTC — the same instant is same-day in Bangkok and different-day
    /// in UTC. Under the old implementation (host-local zone) this test
    /// fails on BOTH hosts: a UTC host claims Bangkok is different-day, a
    /// +07 host claims UTC is same-day.
    func testIsFreshHonorsTheExplicitTimeZoneNotTheHost() {
        let instant = date(28, hour: 0, minute: 30) // Bangkok Aug 28 00:30 = Aug 27 17:30 UTC
        let now = date(28, hour: 7)                 // Bangkok Aug 28 07:00 = Aug 28 00:00 UTC
        XCTAssertTrue(
            HealthMetricPrecedence.isFresh(
                row(computedAt: instant),
                now: now,
                timeZone: timeZone
            ),
            "Bangkok: both instants are on Aug 28 — fresh"
        )
        XCTAssertFalse(
            HealthMetricPrecedence.isFresh(
                row(computedAt: instant),
                now: now,
                timeZone: TimeZone(identifier: "UTC")!
            ),
            "UTC: the instant is Aug 27 17:30 vs now Aug 28 00:00 — not same-day"
        )
    }
}

private extension HealthMetricPrecedenceTests {
    func date(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 8
        c.day = day
        c.hour = hour
        c.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: c)!
    }
}
