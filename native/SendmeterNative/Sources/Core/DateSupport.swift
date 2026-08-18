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
    /// short date. Same as the web's `relativeDayLabel`.
    public static func relativeDayLabel(
        for date: String,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
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
        style.timeZone = timeZone
        return day.formatted(style)
    }

    public static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func iso8601Date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let exact = formatter.date(from: string) { return exact }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
