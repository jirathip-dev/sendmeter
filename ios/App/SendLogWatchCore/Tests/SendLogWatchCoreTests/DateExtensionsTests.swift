import XCTest
import SendLogWatchCore

/// Regression coverage for the Buddhist-calendar date bug: Date.localDateString
/// and Calendar.gregorianLocal must always produce the Gregorian (AD) year,
/// independent of the device's Region/Calendar setting (a Thai Region
/// defaults to the Buddhist calendar, Gregorian + 543 years) AND independent
/// of whatever timezone the machine running these tests happens to be in.
final class DateExtensionsTests: XCTestCase {
    /// Round-trips (year, month, day) through the same calendar/timezone
    /// localDateString uses, so the assertion never depends on the test
    /// runner's local timezone offset from UTC.
    private func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12 // noon: clear of any DST-transition edge cases
        return Calendar.gregorianLocal.date(from: comps)!
    }

    func testLocalDateStringIsGregorianNotBuddhist() {
        let s = date(year: 2026, month: 7, day: 12).localDateString
        XCTAssertEqual(s, "2026-07-12")
        XCTAssertFalse(s.hasPrefix("2569-"), "must never emit the Buddhist-era year")
    }

    func testLocalDateStringFormatIsZeroPadded() {
        let s = date(year: 2026, month: 1, day: 5).localDateString
        XCTAssertEqual(s, "2026-01-05")
    }

    func testGregorianLocalCalendarIdentifier() {
        XCTAssertEqual(Calendar.gregorianLocal.identifier, .gregorian)
    }

    func testGregorianLocalDayArithmeticMatchesPlainGregorian() {
        let now = date(year: 2026, month: 7, day: 12)
        let plain = Calendar(identifier: .gregorian).date(byAdding: .day, value: -6, to: now)!
        let viaHelper = Calendar.gregorianLocal.date(byAdding: .day, value: -6, to: now)!
        XCTAssertEqual(plain.timeIntervalSince1970, viaHelper.timeIntervalSince1970, accuracy: 1)
    }
}
