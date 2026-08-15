import Foundation

public enum LocalDateSupport {
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func string(
        from date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func date(
        from string: String,
        timeZone: TimeZone = .current
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: string)
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
