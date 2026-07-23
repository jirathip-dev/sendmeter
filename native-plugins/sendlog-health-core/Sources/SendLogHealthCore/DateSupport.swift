import Foundation

extension Calendar {
    /// Always Gregorian, regardless of the device's Region/Calendar setting.
    /// A Thai Region, for example, defaults to the Buddhist calendar
    /// (Gregorian year + 543); `Calendar.current` silently follows that,
    /// which corrupted every date the watch wrote. Every date computed for
    /// storage or comparison against the database must go through this.
    public static var gregorianLocal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    /// The overnight window HRV/sleep/respiratory-rate readings are drawn
    /// from: 18:00 the previous day through 12:00 (noon) on `day`, both as
    /// wall-clock times on `day`'s calendar. `endingOn` is always the
    /// calendar day, never clamped to the current time, so this window is
    /// identical whether it's queried at 7am or 7pm.
    ///
    /// Uses `bySettingHour` on each side rather than "noon minus 18 hours" —
    /// raw hour arithmetic across a DST transition shifts the wall-clock
    /// start by an hour; setting 18:00 on the previous day and 12:00 on
    /// `day` directly does not.
    ///
    /// Must be called on a Gregorian calendar (`Calendar.gregorianLocal`) —
    /// `.current` can silently be the Buddhist calendar, corrupting the
    /// window's dates the same way it corrupts stored dates elsewhere.
    public func nightWindow(endingOn day: Date) -> DateInterval {
        assert(
            identifier == .gregorian,
            "nightWindow must be called on a Gregorian calendar — use Calendar.gregorianLocal"
        )
        let previousDay = self.date(byAdding: .day, value: -1, to: day)!
        let start = self.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay)!
        let end = self.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        return DateInterval(start: start, end: end)
    }
}

extension Date {
    /// Local calendar date as YYYY-MM-DD (mirrors web src/lib/dates.ts).
    /// Forces Gregorian + en_US_POSIX so the year is always AD, never a
    /// locale-specific era — see Calendar.gregorianLocal.
    public var localDateString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}
