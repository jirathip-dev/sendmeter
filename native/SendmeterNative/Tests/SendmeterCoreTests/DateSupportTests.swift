import XCTest
@testable import SendmeterCore

/// Direct tests for `LocalDateSupport` — the single helper that writes and
/// reads every stored date in the app (the CLAUDE.md Buddhist-calendar
/// warning is about this helper), rewritten to a shared `ISO8601FormatStyle`
/// for the #664 performance fix. Before this file, coverage was entirely
/// indirect (one `string(from:)` literal compare in `HistoryTimelineTests`)
/// (review L2).
final class DateSupportTests: XCTestCase {
    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!
    private let santiago = TimeZone(identifier: "America/Santiago")!

    func testStringFormattingIsZeroPaddedGregorian() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = bangkok
        let date = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
        let formatted = LocalDateSupport.string(from: date, timeZone: bangkok)
        // `yyyy-MM-dd`: 10 chars, fixed positions, zero-padded month/day.
        XCTAssertEqual(formatted.count, 10)
        let parts = formatted.split(separator: "-").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 4, "year is four digits")
        XCTAssertEqual(parts[1].count, 2, "month zero-padded")
        XCTAssertEqual(parts[2].count, 2, "day zero-padded")
    }

    func testFormatParseRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let string = LocalDateSupport.string(from: date, timeZone: bangkok)
        // Formatting truncates to the calendar day, so parsing yields that
        // day's start-of-day in the time zone — not the original instant.
        let parsed = LocalDateSupport.date(from: string, timeZone: bangkok)
        XCTAssertEqual(
            LocalDateSupport.string(from: parsed!, timeZone: bangkok),
            string,
            "re-formatting the parsed date returns the same date string"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = bangkok
        let startOfDay = calendar.startOfDay(for: parsed!)
        XCTAssertEqual(parsed, startOfDay, "parse yields the day's local midnight")
    }

    func testGregorianYearNotBuddhist() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let formatted = LocalDateSupport.string(from: date, timeZone: bangkok)
        // 1750000000 ≈ 2025-06-15 Gregorian; the Buddhist calendar would say 2568.
        XCTAssertEqual(formatted.prefix(4), "2025")
    }

    func testDSTGapDayParsesInsteadOfNil() {
        // America/Santiago springs forward on 2026-09-06 — no local midnight.
        // The old DateFormatter path returned nil, which `?? referenceDate`
        // silently turned into "now" (a wrong x-position); the ISO8601 style
        // resolves it to 01:00 local (review L2, latent bug the rewrite fixes).
        let parsed = LocalDateSupport.date(from: "2026-09-06", timeZone: santiago)
        XCTAssertNotNil(parsed)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = santiago
        let components = calendar.dateComponents([.year, .month, .day], from: parsed!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 6)
    }

    func testInvalidMonthRejected() {
        XCTAssertNil(LocalDateSupport.date(from: "2026-13-01", timeZone: bangkok))
    }

    func testOutOfRangeDayRollsOverDocumented() {
        // Pin the current (ISO8601FormatStyle) behavior: "2026-02-30" rolls
        // over to 2026-03-02 rather than being rejected as the old
        // DateFormatter did. Unreachable in practice (call sites are fed by
        // `daysAgo` and Postgres `date` columns), but deliberately pinned so
        // a future formatter swap can't silently change it (review L2).
        let parsed = LocalDateSupport.date(from: "2026-02-30", timeZone: bangkok)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(LocalDateSupport.string(from: parsed!, timeZone: bangkok), "2026-03-02")
    }

    func testLeadingWhitespaceRejected() {
        // The ISO8601 style is stricter than the old DateFormatter here —
        // benign, but pinned (review L2).
        XCTAssertNil(LocalDateSupport.date(from: " 2026-08-18", timeZone: bangkok))
    }

    func testDaysAgoWalksBackThroughMonthBoundary() {
        // 1785517200 = 2026-08-01 00:00 Bangkok — daysAgo(1) lands on
        // 2026-07-31, crossing the July→August boundary.
        let reference = Date(timeIntervalSince1970: 1_785_517_200)
        XCTAssertEqual(
            LocalDateSupport.daysAgo(0, from: reference, timeZone: bangkok),
            "2026-08-01"
        )
        XCTAssertEqual(
            LocalDateSupport.daysAgo(1, from: reference, timeZone: bangkok),
            "2026-07-31"
        )
    }

    func testDaysAheadWalksForwardThroughMonthBoundary() {
        // Same reference: daysAhead(1) lands on 2026-08-02, ahead(31) crosses
        // into September.
        let reference = Date(timeIntervalSince1970: 1_785_517_200)
        XCTAssertEqual(
            LocalDateSupport.daysAhead(0, from: reference, timeZone: bangkok),
            "2026-08-01"
        )
        XCTAssertEqual(
            LocalDateSupport.daysAhead(1, from: reference, timeZone: bangkok),
            "2026-08-02"
        )
        XCTAssertEqual(
            LocalDateSupport.daysAhead(31, from: reference, timeZone: bangkok),
            "2026-09-01"
        )
    }

    func testRelativeDayLabel() throws {
        // 2026-08-15 is a Saturday (Bangkok). Walk the five prose branches with
        // a pinned en_US locale so the assertions hold on any CI runner —
        // `relativeDayLabel` follows the device locale by default (the F10
        // contract), which this host (en_TH) renders as "22 Aug" vs en_US
        // "Aug 22". The helper's `locale:` injection keeps the prose
        // user-facing while the test is deterministic.
        let locale = Locale(identifier: "en_US")
        let reference = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-15", timeZone: bangkok))
        let day = { (offset: Int) in
            LocalDateSupport.daysAhead(offset, from: reference, timeZone: self.bangkok)
        }
        XCTAssertEqual(
            LocalDateSupport.relativeDayLabel(for: day(0), referenceDate: reference, timeZone: bangkok, locale: locale),
            "today"
        )
        XCTAssertEqual(
            LocalDateSupport.relativeDayLabel(for: day(-1), referenceDate: reference, timeZone: bangkok, locale: locale),
            "yesterday"
        )
        XCTAssertEqual(
            LocalDateSupport.relativeDayLabel(for: day(1), referenceDate: reference, timeZone: bangkok, locale: locale),
            "tomorrow"
        )
        // +2 (Monday) → wide weekday; +6 (Friday) → still a weekday.
        XCTAssertEqual(
            LocalDateSupport.relativeDayLabel(for: day(2), referenceDate: reference, timeZone: bangkok, locale: locale),
            "Monday"
        )
        XCTAssertEqual(
            LocalDateSupport.relativeDayLabel(for: day(6), referenceDate: reference, timeZone: bangkok, locale: locale),
            "Friday"
        )
        // +7 (next Saturday) → past the unambiguous-weekday horizon → short date.
        XCTAssertEqual(
            LocalDateSupport.relativeDayLabel(for: day(7), referenceDate: reference, timeZone: bangkok, locale: locale),
            "Aug 22"
        )
        // Unparseable input fails safely by echoing the input.
        XCTAssertEqual(
            LocalDateSupport.relativeDayLabel(for: "not-a-date", referenceDate: reference, timeZone: bangkok, locale: locale),
            "not-a-date"
        )
    }

    func testMonthDayLabelIsGregorianAndLocaleAware() throws {
        let locale = Locale(identifier: "en_GB")
        // Day-first (en_GB) short date. The Gregorian calendar is pinned inside
        // the helper, so a Thai-region device (Buddhist Calendar.current) must
        // still render the 2026 year, not 2569.
        XCTAssertEqual(
            LocalDateSupport.monthDayLabel(for: "2026-07-25", timeZone: bangkok, locale: locale),
            "25 Jul"
        )
        // Unparseable input fails safely by echoing the input.
        XCTAssertEqual(
            LocalDateSupport.monthDayLabel(for: "not-a-date", timeZone: bangkok, locale: locale),
            "not-a-date"
        )
    }

    func testDayDistance() {
        XCTAssertEqual(
            LocalDateSupport.dayDistance(from: "2026-08-01", to: "2026-08-15", timeZone: bangkok),
            14
        )
        XCTAssertNil(
            LocalDateSupport.dayDistance(from: "not-a-date", to: "2026-08-15", timeZone: bangkok)
        )
    }

    // MARK: - canonicalDayKey

    func testCanonicalDayKeyKeepsGregorianDateOnly() {
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-11", timeZone: bangkok),
            "2026-06-11"
        )
    }

    func testCanonicalDayKeyConvertsIsoTimestampToLocalDay() {
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-11T00:00:00Z", timeZone: bangkok),
            "2026-06-11"
        )
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-10T20:00:00Z", timeZone: bangkok),
            "2026-06-11",
            "a UTC timestamp near local midnight must land on the correct local day"
        )
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-11T00:00:00+07:00", timeZone: bangkok),
            "2026-06-11"
        )
    }

    func testCanonicalDayKeyTreatsBareTimestampAsLocal() {
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-11T00:00:00", timeZone: bangkok),
            "2026-06-11"
        )
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-11 00:00:00", timeZone: bangkok),
            "2026-06-11"
        )
    }

    func testCanonicalDayKeyHonorsSpaceDelimitedTimestampOffset() {
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-10 23:00:00-05:00", timeZone: bangkok),
            "2026-06-11",
            "a space-delimited timestamp with an explicit offset is an instant, not a bare local time"
        )
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2026-06-11 00:00:00+07:00", timeZone: bangkok),
            "2026-06-11"
        )
    }

    func testCanonicalDayKeyCorrectsLegacyBuddhistDate() {
        XCTAssertEqual(
            LocalDateSupport.canonicalDayKey("2569-07-12", timeZone: bangkok),
            "2026-07-12",
            "optimistic/cached rows from the pre-fix watch must land on the Gregorian day"
        )
    }

    func testCanonicalDayKeyRejectsInvalidAndGarbage() {
        XCTAssertNil(LocalDateSupport.canonicalDayKey("not-a-date", timeZone: bangkok))
        XCTAssertNil(LocalDateSupport.canonicalDayKey("2026-02-30", timeZone: bangkok))
        XCTAssertNil(LocalDateSupport.canonicalDayKey(" 2026-06-11", timeZone: bangkok))
        XCTAssertNil(LocalDateSupport.canonicalDayKey("2026-06-11 garbage", timeZone: bangkok))
        XCTAssertNil(LocalDateSupport.canonicalDayKey("2026-06-11T", timeZone: bangkok))
    }
}
