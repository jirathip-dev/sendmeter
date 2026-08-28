import Foundation
import XCTest
@testable import SendLogWatchCore

final class WatchHealthComputeTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Bangkok")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// `dayOffset` days before/after Aug 28 2026, at 07:00 local.
    private func makeDate(offset: Int, hour: Int = 7) -> Date {
        let base = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 28, hour: hour)
        )!
        return calendar.date(byAdding: .day, value: offset, to: base)!
    }

    private func makeDate(day: Int, hour: Int = 7) -> Date {
        let today = makeDate(offset: 0, hour: 0)
        return calendar.date(byAdding: .day, value: day - 28, to: today)!
    }

    private func key(offset: Int) -> String {
        makeDate(offset: offset).dateString(in: calendar)
    }

    private func key(day: Int) -> String {
        makeDate(day: day).dateString(in: calendar)
    }

    /// HRV varying across the baseline (σ > 0) so the RecoveryEngine z-score
    /// is computable, with today's value 60.
    private func hrvMap(today: Int = 28) -> [String: Double] {
        var map: [String: Double] = [:]
        for offset in 0...27 {
            // 45...54 ramp, then today 60 — never constant, so σ > 0.
            map[key(day: today - offset)] = Double(45 + (offset % 10))
        }
        map[key(day: today)] = 60
        return map
    }

    func testEmptYInputsProduceNoMetrics() throws {
        let metrics = try WatchHealthCompute.metrics(
            hrv: [:],
            restingHR: [:],
            respiratoryRate: [:],
            sleep: [:],
            bodyMass: [:],
            now: makeDate(day: 28),
            timeZone: timeZone
        )
        XCTAssertTrue(metrics.isEmpty)
    }

    func testSourceDayWithinWindowIsComputedWithSameRecoveryEngine() throws {
        let metrics = try WatchHealthCompute.metrics(
            hrv: hrvMap(),
            restingHR: [:],
            respiratoryRate: [:],
            sleep: [:],
            bodyMass: [:],
            acwrByDate: [:],
            now: makeDate(day: 28),
            timeZone: timeZone
        )
        // Every day in the HRV map (today-27 … today) has source data.
        XCTAssertEqual(metrics.count, 28)
        guard let today = metrics.first(where: { $0.date == key(day: 28) }) else {
            return XCTFail("missing today metric")
        }
        XCTAssertEqual(today.hrvSDNNMilliseconds, 60)
        XCTAssertEqual(today.restingHeartRate, nil)
        XCTAssertTrue(today.hasSourceData)
        XCTAssertNotNil(today.readiness)
        XCTAssertNotNil(today.zone)
    }

    func testDayBeyondWindowIsExcluded() throws {
        var map: [String: Double] = [:]
        map[key(day: 28)] = 60
        // 29 days back (offset -29) — outside the 28-day window.
        map[key(offset: -29)] = 60
        let metrics = try WatchHealthCompute.metrics(
            hrv: map,
            restingHR: [:],
            respiratoryRate: [:],
            sleep: [:],
            bodyMass: [:],
            now: makeDate(day: 28),
            timeZone: timeZone
        )
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.date, key(day: 28))
    }

    func testSleepRestorativeAndRespFoldIntoInputs() throws {
        var sleep: [String: WatchSleepHours] = [:]
        sleep[key(day: 28)] = WatchSleepHours(totalHours: 8, deepHours: 2, remHours: 1.5)
        // Baseline-day sleep feeds the trailing sleep/restorative baselines.
        for offset in 1...27 {
            sleep[key(day: 28 - offset)] = WatchSleepHours(
                totalHours: 7,
                deepHours: 1.5,
                remHours: 1
            )
        }
        var resp: [String: Double] = [:]
        resp[key(day: 28)] = 14
        for offset in 1...27 {
            resp[key(day: 28 - offset)] = 13
        }
        let metrics = try WatchHealthCompute.metrics(
            hrv: hrvMap(),
            restingHR: [:],
            respiratoryRate: resp,
            sleep: sleep,
            bodyMass: [:],
            now: makeDate(day: 28),
            timeZone: timeZone
        )
        guard let today = metrics.first(where: { $0.date == key(day: 28) }) else {
            return XCTFail("missing today metric")
        }
        XCTAssertEqual(today.id, key(day: 28))
        XCTAssertEqual(today.sleepHours, 8)
        XCTAssertEqual(today.sleepDeepHours, 2)
        XCTAssertEqual(today.sleepREMHours, 1.5)
        XCTAssertEqual(today.respiratoryRate, 14)
    }

    func testLatestBodyMassOnOrBeforeDateIsUsed() throws {
        var mass: [String: Double] = [:]
        mass[key(day: 25)] = 70
        mass[key(day: 26)] = 71
        let metrics = try WatchHealthCompute.metrics(
            hrv: hrvMap(),
            restingHR: [:],
            respiratoryRate: [:],
            sleep: [:],
            bodyMass: mass,
            now: makeDate(day: 28),
            timeZone: timeZone
        )
        guard let today = metrics.first(where: { $0.date == key(day: 28) }) else {
            return XCTFail("missing today metric")
        }
        XCTAssertEqual(today.bodyMassKilograms, 71) // latest on/before today
        if let twentyFive = metrics.first(where: { $0.date == key(day: 25) }) {
            XCTAssertEqual(twentyFive.bodyMassKilograms, 70)
        }
    }

    func testACWRByDateUsesPerDateWindows() {
        // One heavy session 5 days ago; the ratio changes per date window.
        let rows = [SessionLoadRow(date: key(day: 23), load: 100)]
        let byDate = WatchHealthCompute.acwrByDate(
            rows: rows,
            now: makeDate(day: 28),
            timeZone: timeZone
        )
        XCTAssertFalse(byDate.isEmpty)
        XCTAssertNotNil(byDate[key(day: 28)])
        XCTAssertNotNil(byDate[key(day: 23)])
    }

    func testACWRByDateEmptyWithoutRows() {
        let byDate = WatchHealthCompute.acwrByDate(
            rows: [],
            now: makeDate(day: 28),
            timeZone: timeZone
        )
        XCTAssertTrue(byDate.isEmpty)
    }
}
