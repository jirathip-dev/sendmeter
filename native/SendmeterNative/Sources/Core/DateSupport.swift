import Foundation

/// Gregorian-only date helpers — never `Calendar.current`, which on a
/// Thai-region device defaults to the Buddhist calendar (year +543) and once
/// corrupted every stored date. `ISO8601FormatStyle` is used instead of
/// `DateFormatter` because it is inherently Gregorian (no `calendar` property
/// to forget to pin), zero-pads to `yyyy-MM-dd`, and is `Sendable` so the
/// whole app shares one cached instance instead of allocating a
/// `DateFormatter` per call (the readiness-series path alone created 28 per
/// body pass — #664 review finding 2).
public enum LocalDateSupport {
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Shared `yyyy-MM-dd` formatter. `timeZone` is a mutable property, so the
    /// style is re-created whenever it differs — the common call site passes
    /// the same time zone every time, so this caches after the first call.
    private static let dayStyleCache = DayStyleCache()

    private final class DayStyleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedTimeZone: TimeZone?
        private var style: Date.ISO8601FormatStyle?

        func style(for timeZone: TimeZone) -> Date.ISO8601FormatStyle {
            lock.lock()
            defer { lock.unlock() }
            if let style, let cachedTimeZone, cachedTimeZone == timeZone {
                return style
            }
            var style = Date.ISO8601FormatStyle().year().month().day()
            style.timeZone = timeZone
            self.style = style
            self.cachedTimeZone = timeZone
            return style
        }
    }

    public static func string(
        from date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        dayStyleCache.style(for: timeZone).format(date)
    }

    public static func date(
        from string: String,
        timeZone: TimeZone = .current
    ) -> Date? {
        try? dayStyleCache.style(for: timeZone).parse(string)
    }

    public static func daysAgo(
        _ days: Int,
        from referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let calendar = calendar(timeZone: timeZone)
        let start = calendar.startOfDay(for: referenceDate)
        let date = calendar.date(byAdding: .day, value: -days, to: start) ?? start
        return string(from: date, timeZone: timeZone)
    }

    /// Days ahead of `referenceDate` (`daysAgo` going forward) — the web's
    /// `daysAhead(n)` for the ACWR projection's future dates.
    public static func daysAhead(
        _ days: Int,
        from referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        daysAgo(-days, from: referenceDate, timeZone: timeZone)
    }

    public static func dayDistance(
        from startDate: String,
        to endDate: String,
        timeZone: TimeZone = .current
    ) -> Int? {
        guard let start = date(from: startDate, timeZone: timeZone),
              let end = date(from: endDate, timeZone: timeZone)
        else { return nil }
        let calendar = calendar(timeZone: timeZone)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    /// How a nearby day is named in prose: "yesterday" / "today" /
    /// "tomorrow" / the plain weekday inside the coming week. Past ~6 days out
    /// a bare weekday is ambiguous (which Thursday?), so it falls back to a
    /// short date. Same as the web's `relativeDayLabel`. The locale is
    /// injected (defaulting to the device's) like `timeZone` so the prose
    /// follows the user's region while remaining testable with a fixed
    /// locale; only the calendar is pinned.
    public static func relativeDayLabel(
        for date: String,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let reference = string(from: referenceDate, timeZone: timeZone)
        guard let offset = dayDistance(from: reference, to: date, timeZone: timeZone) else {
            return date
        }
        if offset == -1 { return "yesterday" }
        if offset == 0 { return "today" }
        if offset == 1 { return "tomorrow" }
        guard let day = self.date(from: date, timeZone: timeZone) else { return date }
        var style: Date.FormatStyle
        if offset > 1 && offset <= 6 {
            style = Date.FormatStyle().weekday(.wide)
        } else {
            style = Date.FormatStyle().month(.abbreviated).day()
        }
        style.calendar = Calendar(identifier: .gregorian)
        style.locale = locale
        style.timeZone = timeZone
        return day.formatted(style)
    }

    /// An absolute, Gregorian short date such as "25 Jul". Used for the
    /// "You selected this block on …" phrasing where a relative label
    /// ("today"/"yesterday") would read awkwardly next to a concrete date.
    public static func monthDayLabel(
        for date: String,
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let day = self.date(from: date, timeZone: timeZone) else { return date }
        var style = Date.FormatStyle().month(.abbreviated).day()
        style.calendar = Calendar(identifier: .gregorian)
        style.timeZone = timeZone
        style.locale = locale
        return day.formatted(style)
    }

    public static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func iso8601Date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let exact = formatter.date(from: string) { return exact }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Canonical local-day key for a stored date string.
    ///
    /// The heatmap grid generates its keys with `string(from:timeZone:)`, so a
    /// `Session.date` that arrives as an ISO timestamp, a bare local
    /// date-time, or a legacy Buddhist-era date must be normalized before it
    /// is used as the aggregation key (#754 cause 1). Date-only values pass
    /// through unchanged; timestamps are converted into the supplied time
    /// zone's calendar day. A string that cannot be parsed as a real
    /// `YYYY-MM-DD` day returns nil so it is not silently grouped under a
    /// wrong date.
    public static func canonicalDayKey(
        _ value: String,
        timeZone: TimeZone = .current
    ) -> String? {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }

        var timestampCandidate = value
        if value.contains("T") || value.contains(" ") {
            // ISO8601DateFormatter only accepts the "T" separator. A stored
            // timestamp that uses a space still carries a real offset and
            // must be converted as an instant, not treated as a bare local
            // date below (e.g. 2026-06-10 23:00:00-05:00 is 2026-06-11 in
            // Bangkok). Bare local timestamps without an offset still fall
            // through to the date-only path below.
            if value.contains(" ") {
                let separator = value.index(value.startIndex, offsetBy: 10)
                timestampCandidate = value.replacingCharacters(
                    in: separator..<value.index(after: separator),
                    with: "T"
                )
            }
        }
        if value.contains("T") || value.contains(" "),
           let instant = iso8601Date(from: timestampCandidate) {
            return canonicalDayString(from: instant, timeZone: timeZone)
        }

        guard value.count >= 10 else { return nil }
        let prefix = String(value.prefix(10))
        let dateOnly = value.count == 10
        if !dateOnly {
            let delimiter = value[value.index(value.startIndex, offsetBy: 10)]
            guard delimiter == "T" || delimiter == " " else {
                return nil
            }
            let suffix = String(value.dropFirst(11))
            guard isBareLocalTimestampSuffix(suffix) else { return nil }
        }
        guard let parsed = parseCanonicalDateKey(prefix, timeZone: timeZone) else { return nil }
        return canonicalDayString(from: parsed, timeZone: timeZone)
    }

    private static func isBareLocalTimestampSuffix(_ value: String) -> Bool {
        guard value.contains(":") else { return false }
        return value.unicodeScalars.allSatisfy {
            $0 == ":" || $0 == "." || ($0.value >= 48 && $0.value <= 57)
        }
    }

    private static func parseCanonicalDateKey(
        _ value: String,
        timeZone: TimeZone
    ) -> Date? {
        guard let parsed = date(from: value, timeZone: timeZone),
              string(from: parsed, timeZone: timeZone) == value
        else { return nil }
        return parsed
    }

    private static func canonicalDayString(
        from date: Date,
        timeZone: TimeZone
    ) -> String? {
        let calendar = calendar(timeZone: timeZone)
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year else { return nil }

        // Legacy watch builds wrote Gregorian year +543 under a Thai region
        // (e.g. 2569-07-12). Server rows were backfilled, but an optimistic
        // or cached row must still land on the displayed Gregorian day.
        if year >= 2400 {
            components.year = year - 543
            guard let corrected = calendar.date(from: components) else { return nil }
            return string(from: corrected, timeZone: timeZone)
        }

        return string(from: date, timeZone: timeZone)
    }
}
