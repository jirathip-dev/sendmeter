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
