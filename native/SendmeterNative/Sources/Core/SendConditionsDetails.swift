import Foundation

/// One day in the same-hour-of-day comparison chart. `date` is the local
/// calendar day at the historical hour; `id` is the day's slot index so a
/// null day still reserves its place in the chart and never shifts later
/// bars (web parity: the archive keeps null hourly placeholders).
public struct SendConditionsHistoryDay: Identifiable, Hashable, Sendable {
    public let id: Int
    public let date: Date
    public let daysAgo: Int
    public let score: Int?
    public let tempC: Double?
    public let humidity: Double?
    public let isToday: Bool

    public init(
        id: Int,
        date: Date,
        daysAgo: Int,
        score: Int?,
        tempC: Double?,
        humidity: Double?,
        isToday: Bool
    ) {
        self.id = id
        self.date = date
        self.daysAgo = daysAgo
        self.score = score
        self.tempC = tempC
        self.humidity = humidity
        self.isToday = isToday
    }
}

/// The chart series built from a `SendConditions` reading. History days keep
/// every same-hour slot, including nulls, so missing archive hours are honest
/// gaps rather than collapsed bars. `today` is appended separately and is
/// excluded from `median`, matching the banner's rank-against-history claim.
public struct SendConditionsHistory: Equatable, Sendable {
    public let days: [SendConditionsHistoryDay]
    public let today: SendConditionsHistoryDay
    public let median: Double?

    public init(days: [SendConditionsHistoryDay], today: SendConditionsHistoryDay, median: Double?) {
        self.days = days
        self.today = today
        self.median = median
    }

    public var allDays: [SendConditionsHistoryDay] {
        days + [today]
    }

    public var dateDomain: ClosedRange<Date>? {
        guard let first = days.first?.date else { return nil }
        return first...today.date
    }

    public var scoreValues: [Int] {
        days.compactMap(\.score)
    }
}

public enum SendConditionsHistoryBuilder {
    /// Build the same-hour series for the conditions the card is showing.
    /// `fetchedAt` anchors the archive's ERA5 lag onto the calendar, so the
    /// chart's x-domain and slot labels agree with `sameHourDaysAgo`.
    public static func build(conditions: SendConditions) -> SendConditionsHistory? {
        guard let hist = conditions.hist else { return nil }
        return build(
            hist: hist,
            hourOfDay: conditions.hourOfDay,
            currentScore: conditions.score,
            currentTempC: conditions.tempC,
            currentHumidity: conditions.humidity,
            referenceDate: conditions.fetchedAt
        )
    }

    public static func build(
        hist: ClimateSummary,
        hourOfDay: Int,
        currentScore: Int,
        currentTempC: Double,
        currentHumidity: Double,
        referenceDate: Date
    ) -> SendConditionsHistory? {
        guard (0..<24).contains(hourOfDay) else { return nil }
        let slotCount = hist.scores.count > hourOfDay
            ? (hist.scores.count - hourOfDay + 23) / 24
            : 0
        guard slotCount > 0 else { return nil }

        let calendar = LocalDateSupport.calendar()
        let today = calendar.startOfDay(for: referenceDate)
        guard let latestArchiveDay = calendar.date(
            byAdding: .day,
            value: -SendConditionsScore.era5LagDays,
            to: today
        ), let firstDay = calendar.date(
            byAdding: .day,
            value: -(slotCount - 1),
            to: latestArchiveDay
        ) else { return nil }

        var days: [SendConditionsHistoryDay] = []
        days.reserveCapacity(slotCount)
        for offset in 0..<slotCount {
            let index = hourOfDay + offset * 24
            let date = calendar.date(byAdding: .day, value: offset, to: firstDay)
                ?? firstDay.addingTimeInterval(Double(offset) * 86_400)
            days.append(
                SendConditionsHistoryDay(
                    id: offset,
                    date: date,
                    daysAgo: SendConditionsScore.sameHourDaysAgo(
                        index: offset,
                        length: slotCount
                    ),
                    score: optionalValue(at: index, in: hist.scores),
                    tempC: optionalValue(at: index, in: hist.tempScores),
                    humidity: optionalValue(at: index, in: hist.humidityScores),
                    isToday: false
                )
            )
        }

        let todayDay = SendConditionsHistoryDay(
            id: -1,
            date: today,
            daysAgo: 0,
            score: currentScore,
            tempC: currentTempC,
            humidity: currentHumidity,
            isToday: true
        )
        return SendConditionsHistory(
            days: days,
            today: todayDay,
            median: SendConditionsScore.median(days.compactMap(\.score))
        )
    }

    private static func optionalValue(at index: Int, in values: [Int?]) -> Int? {
        guard index < values.count else { return nil }
        return values[index]
    }

    private static func optionalValue(at index: Int, in values: [Double?]?) -> Double? {
        guard let values, index < values.count else { return nil }
        return values[index]
    }
}

/// Exact copy decisions from the web sheet (`SendConditionsSheet.tsx`).
public enum SendConditionsDetails {
    /// The headline's percentile suffix. Percentile 100 says "best of the
    /// last N days" rather than "top 0%"; below 40 the bad-window label and
    /// callout already make the point.
    public static func headlineSuffix(percentile: Int, daysTotal: Int?) -> String? {
        if percentile == 100 {
            return daysTotal.map { "best of the last \($0) days" }
        }
        if percentile >= 40 {
            return "top \(max(1, 100 - percentile))%"
        }
        return nil
    }

    /// The percentile callout's terminal phrase, exact web copy.
    public static func percentilePhrase(_ percentile: Int) -> String {
        if percentile >= 75 { return "A standout window for here." }
        if percentile >= 40 { return "A typical day here." }
        return "Below par for here."
    }

    public static func percentileCallout(
        daysBelow: Int?,
        daysTotal: Int?,
        percentile: Int?
    ) -> String? {
        guard let daysBelow, let daysTotal, let percentile else { return nil }
        return "Better than \(daysBelow) of the last \(daysTotal) days at this time of day. \(percentilePhrase(percentile))"
    }

    /// The full explainer paragraph, including the honest per-climate driver
    /// sentence. Web text uses non-breaking spaces around degree values.
    public static func explainer(conditions: SendConditions) -> String {
        var parts: [String] = []
        if conditions.percentile != nil {
            parts.append(
                "The headline compares right now with the same time of day over the last 30 days at your location — a high rank means this is a good window for here, whatever the absolute score says."
            )
        }
        parts.append(
            "The absolute score rewards cold and dry (friction peaks near 6\u{00A0}°C); above ~23\u{00A0}°C the temperature part bottoms out, so in a warm climate the day-to-day ranking is driven almost entirely by humidity."
        )
        if let hist = conditions.hist {
            if SendConditionsScore.isTempRangeSaturated(
                tempMin: hist.tempMin,
                tempMax: hist.tempMax
            ) {
                parts.append(
                    "Temperature is maxed out here year-round — today ranks on humidity: \(Int(conditions.humidity.rounded()))% against the local \(Int(hist.humMin.rounded()))–\(Int(hist.humMax.rounded()))% range."
                )
            } else if SendConditionsScore.tempFrictionScore(tempC: conditions.tempC) == 0 {
                parts.append(
                    "Temperature is maxed out in this range — today ranks on humidity: \(Int(conditions.humidity.rounded()))% against the local \(Int(hist.humMin.rounded()))–\(Int(hist.humMax.rounded()))% range."
                )
            } else {
                parts.append(
                    "Today ranks on the mix of \(Int(conditions.tempC.rounded()))°C against the local \(Int(hist.tempMin.rounded()))–\(Int(hist.tempMax.rounded()))°C range and \(Int(conditions.humidity.rounded()))% against \(Int(hist.humMin.rounded()))–\(Int(hist.humMax.rounded()))% humidity."
                )
            }
        }
        parts.append("Weather is from Open-Meteo for your current location.")
        return parts.joined(separator: " ")
    }
}
