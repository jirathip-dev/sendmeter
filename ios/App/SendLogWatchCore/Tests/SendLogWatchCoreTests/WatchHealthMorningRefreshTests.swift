import Foundation
import XCTest
@testable import SendLogWatchCore

final class WatchHealthMorningRefreshTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Bangkok")!
    private let policy = WatchHealthMorningRefreshPolicy()

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute)
        )!
    }

    func testWindowGates() {
        XCTAssertEqual(policy.passCount, 3)
        XCTAssertFalse(policy.isMorning(at: date(day: 28, hour: 4), calendar: calendar))
        XCTAssertTrue(policy.isMorning(at: date(day: 28, hour: 5), calendar: calendar))
        XCTAssertTrue(policy.isMorning(at: date(day: 28, hour: 12), calendar: calendar))
        XCTAssertFalse(policy.isMorning(at: date(day: 28, hour: 13), calendar: calendar))
        XCTAssertFalse(policy.isMorning(at: date(day: 28, hour: 23), calendar: calendar))
    }

    func testShouldStartOncePerLocalDayOnlyInMorning() {
        // Not morning → never.
        XCTAssertFalse(
            policy.shouldStart(
                at: date(day: 28, hour: 14),
                lastStartedAt: nil,
                calendar: calendar
            )
        )
        // Morning + no previous → start.
        XCTAssertTrue(
            policy.shouldStart(
                at: date(day: 28, hour: 6),
                lastStartedAt: nil,
                calendar: calendar
            )
        )
        // Morning + started earlier today → no second window.
        XCTAssertFalse(
            policy.shouldStart(
                at: date(day: 28, hour: 7),
                lastStartedAt: date(day: 28, hour: 5, minute: 30),
                calendar: calendar
            )
        )
        // Morning + started YESTERDAY → new window.
        XCTAssertTrue(
            policy.shouldStart(
                at: date(day: 28, hour: 6),
                lastStartedAt: date(day: 27, hour: 6),
                calendar: calendar
            )
        )
    }

    func testDuePassFollowsRepollDelays() {
        let progress = WatchHealthMorningProgress(
            accountUserID: UUID(),
            startedAt: date(day: 28, hour: 5),
            nextPass: 0
        )
        // Pass 0 has delay 0 → due immediately at the start.
        XCTAssertEqual(
            policy.duePass(for: progress, at: date(day: 28, hour: 5)),
            0
        )
        XCTAssertEqual(
            policy.duePass(for: progress, at: date(day: 28, hour: 5, minute: 1)),
            0
        )
        var advanced = progress
        advanced.nextPass = 1
        XCTAssertNil(policy.duePass(for: advanced, at: date(day: 28, hour: 5)))
        XCTAssertEqual(
            policy.duePass(for: advanced, at: date(day: 28, hour: 5, minute: 5)),
            1
        )
        advanced.nextPass = 2
        XCTAssertNil(policy.duePass(for: advanced, at: date(day: 28, hour: 5, minute: 5)))
        XCTAssertEqual(
            policy.duePass(for: advanced, at: date(day: 28, hour: 5, minute: 15)),
            2
        )
        advanced.nextPass = 3
        XCTAssertNil(policy.duePass(for: advanced, at: date(day: 28, hour: 16)))
    }

    func testIsCurrentLocalDay() {
        let progress = WatchHealthMorningProgress(
            accountUserID: UUID(),
            startedAt: date(day: 28, hour: 5),
            nextPass: 0
        )
        XCTAssertTrue(
            policy.isCurrentLocalDay(progress, at: date(day: 28, hour: 22), calendar: calendar)
        )
        XCTAssertFalse(
            policy.isCurrentLocalDay(progress, at: date(day: 29, hour: 0), calendar: calendar)
        )
    }

    func testProgressLedgerCountsOncePerDay() {
        var progress = WatchHealthMorningProgress(
            accountUserID: UUID(),
            startedAt: date(day: 28, hour: 5)
        )
        progress.add(
            observation: .reconciled(2),
            acknowledgedReconciledDates: ["2026-08-27", "2026-08-28"]
        )
        progress.add(
            observation: .reconciled(2),
            acknowledgedReconciledDates: ["2026-08-28"]
        )
        XCTAssertEqual(progress.reconciledCount, 2)
        XCTAssertEqual(progress.reconciledDateKeys.count, 2)
        XCTAssertEqual(progress.successfulPasses, 2)
        XCTAssertEqual(progress.sourceDataPasses, 2)
        progress.add(observation: .noSourceData)
        XCTAssertEqual(progress.sourceDataPasses, 2)
        progress.markFailure()
        XCTAssertTrue(progress.hadFailure)
    }

    func testObservationMapping() {
        XCTAssertEqual(
            WatchHealthSyncObservation.successful(reconciledCount: 1, sourceDataCount: 1),
            .reconciled(1)
        )
        XCTAssertEqual(
            WatchHealthSyncObservation.successful(reconciledCount: 0, sourceDataCount: 2),
            .noNewData
        )
        XCTAssertEqual(
            WatchHealthSyncObservation.successful(reconciledCount: 0, sourceDataCount: 0),
            .noSourceData
        )
        XCTAssertFalse(WatchHealthSyncObservation.failed.hasSourceData)
        XCTAssertFalse(WatchHealthSyncObservation.cancelled.hasSourceData)
        XCTAssertTrue(WatchHealthSyncObservation.noNewData.hasSourceData)
    }
}
