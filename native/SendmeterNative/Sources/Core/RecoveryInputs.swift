import Foundation

/// The seven raw HealthKit inputs behind the daily readiness score (#753).
///
/// This is the native data-driven replacement for the web's
/// `RecoveryStatsCard.tsx` metric table. It deliberately owns the metric
/// extraction and formatting so the seven rows are one list instead of seven
/// hand-written chart bodies; the UI only resolves colors and chart marks.
public enum RecoveryMetric: String, CaseIterable, Identifiable, Sendable {
    case hrv
    case restingHeartRate
    case respiratoryRate
    case sleep
    case deepSleep
    case remSleep
    case bodyMass

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hrv: return "HRV"
        case .restingHeartRate: return "Resting HR"
        case .respiratoryRate: return "Resp Rate"
        case .sleep: return "Sleep"
        case .deepSleep: return "Deep Sleep"
        case .remSleep: return "REM Sleep"
        case .bodyMass: return "Weight"
        }
    }

    public var unit: String {
        switch self {
        case .hrv: return "ms"
        case .restingHeartRate: return "bpm"
        case .respiratoryRate: return "brpm"
        case .sleep, .deepSleep, .remSleep: return "h"
        case .bodyMass: return "kg"
        }
    }

    public func value(from metric: HealthMetric?) -> Double? {
        guard let metric else { return nil }
        switch self {
        case .hrv: return metric.hrvSDNNMilliseconds
        case .restingHeartRate: return metric.restingHeartRate
        case .respiratoryRate: return metric.respiratoryRate
        case .sleep: return metric.sleepHours
        case .deepSleep: return metric.sleepDeepHours
        case .remSleep: return metric.sleepREMHours
        case .bodyMass: return metric.bodyMassKilograms
        }
    }

    /// The unit shown next to a value, honoring the app's mass preference for
    /// the weight row while all other metrics keep their canonical unit.
    public func displayUnit(for preference: UnitsPreference) -> String {
        switch self {
        case .bodyMass: return MassFormatting.unit(for: preference).symbol
        default: return unit
        }
    }

    /// Display value without a unit. Weight is converted to the selected unit;
    /// all other metrics use the same formatting as the web card.
    public func formatted(_ value: Double, for preference: UnitsPreference) -> String {
        switch self {
        case .hrv: return String(format: "%.0f", value)
        case .restingHeartRate: return String(format: "%.0f", value)
        case .respiratoryRate: return String(format: "%.1f", value)
        case .sleep, .deepSleep, .remSleep: return String(format: "%.1f", value)
        case .bodyMass:
            return String(
                format: "%.1f",
                MassFormatting.value(value, in: MassFormatting.unit(for: preference))
            )
        }
    }

    /// The complete value-plus-unit string used by VoiceOver and tooltips.
    public func formattedWithUnit(_ value: Double, for preference: UnitsPreference) -> String {
        "\(formatted(value, for: preference)) \(displayUnit(for: preference))"
    }
}

/// One slot on the shared 14-day X axis. Every metric row uses the same dates
/// and `dateValue`, so a selection made in any row can highlight the same
/// column in every other row.
public struct RecoverySeriesDay: Equatable, Identifiable, Sendable {
    public var id: String { date }
    public let date: String
    public let dateValue: Date

    public init(date: String, dateValue: Date) {
        self.date = date
        self.dateValue = dateValue
    }
}

/// One metric's value at one shared date, plus its 7-day EWMA trend.
///
/// `trend` is nil on a missing day even though the EWMA state carries forward:
/// the line must not visually bridge a wear gap. `runIndex` groups contiguous
/// present days and is passed through the chart's `series:` so Swift Charts
/// treats each run as its own line.
public struct RecoveryMetricDay: Equatable, Identifiable, Sendable {
    public var id: String { date }
    public let date: String
    public let dateValue: Date
    public let value: Double?
    public let trend: Double?
    public let runIndex: Int?

    public init(
        date: String,
        dateValue: Date,
        value: Double?,
        trend: Double?,
        runIndex: Int? = nil
    ) {
        self.date = date
        self.dateValue = dateValue
        self.value = value
        self.trend = trend
        self.runIndex = runIndex
    }

    func withRunIndex(_ runIndex: Int?) -> RecoveryMetricDay {
        RecoveryMetricDay(
            date: date,
            dateValue: dateValue,
            value: value,
            trend: trend,
            runIndex: runIndex
        )
    }
}

/// One metric's 14-day series, useful to the chart only when it has data.
public struct RecoveryMetricSeries: Equatable, Identifiable, Sendable {
    public var id: String { metric.id }
    public let metric: RecoveryMetric
    public let days: [RecoveryMetricDay]

    public init(metric: RecoveryMetric, days: [RecoveryMetricDay]) {
        self.metric = metric
        self.days = days
    }

    public var hasData: Bool {
        days.contains { $0.value != nil }
    }

    /// Newest non-nil value in the visible window, matching the web card's
    /// "latest" semantics: with a trailing wear gap this is the most recent
    /// observed reading, never a fabricated zero.
    public var latestDay: RecoveryMetricDay? {
        days.reversed().first { $0.value != nil }
    }

    /// The own-row Y domain, expanded so bars and the trend line never clip.
    public var yDomain: ClosedRange<Double>? {
        var present: [Double] = []
        for day in days {
            if let value = day.value { present.append(value) }
            if let trend = day.trend { present.append(trend) }
        }
        guard let minimum = present.min(), let maximum = present.max() else { return nil }
        if minimum == maximum {
            let padding = minimum == 0 ? 1 : abs(minimum) * 0.1
            return (minimum - padding)...(maximum + padding)
        }
        let padding = (maximum - minimum) * 0.08
        return (minimum - padding)...(maximum + padding)
    }
}

/// Immutable snapshot of the whole Recovery Inputs sheet.
public struct RecoveryInputsSeries: Equatable, Sendable {
    public let days: [RecoverySeriesDay]
    /// Only metrics with at least one value in the visible window. An empty
    /// array means the sheet should show the whole-sheet empty state.
    public let rows: [RecoveryMetricSeries]

    public var hasData: Bool { !rows.isEmpty }

    public init(days: [RecoverySeriesDay], rows: [RecoveryMetricSeries]) {
        self.days = days
        self.rows = rows
    }

    /// Builds the shared 14-day window plus per-metric bars and a single
    /// 7-day EWMA. The trend uses a longer warm-up window so it is not just
    /// chasing the first visible bar (the web uses 60 fetched days for the
    /// same reason), while the chart itself always exposes 14 day slots.
    public static func build(
        metrics: [HealthMetric],
        visibleDays: Int = 14,
        trendSpan: Int = 7,
        warmupDays: Int = 60,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> RecoveryInputsSeries {
        precondition(visibleDays > 0, "visibleDays must be positive")
        precondition(trendSpan > 0, "trendSpan must be positive")
        precondition(warmupDays >= visibleDays, "warmupDays must cover the visible window")

        let byDate = Dictionary(
            metrics.map { ($0.date, $0) },
            uniquingKeysWith: { _, new in new }
        )
        let totalDays = max(warmupDays, visibleDays)
        let allDates = (0..<totalDays).reversed().map { offset in
            let day = LocalDateSupport.daysAgo(offset, from: referenceDate, timeZone: timeZone)
            return RecoverySeriesDay(
                date: day,
                dateValue: LocalDateSupport.date(from: day, timeZone: timeZone) ?? referenceDate
            )
        }
        let visibleDates = Array(allDates.suffix(visibleDays))

        let rows = RecoveryMetric.allCases.compactMap { metric -> RecoveryMetricSeries? in
            let rawValues = allDates.map { metric.value(from: byDate[$0.date]) }
            let trends = TrainingMetrics.ewma(values: rawValues, span: trendSpan)
            let dated = allDates.indices.map { index in
                let day = allDates[index]
                let value = rawValues[index]
                return RecoveryMetricDay(
                    date: day.date,
                    dateValue: day.dateValue,
                    value: value,
                    trend: value == nil ? nil : trends[index]
                )
            }
            let grouped = groupedIntoRuns(Array(dated.suffix(visibleDays)))
            let series = RecoveryMetricSeries(metric: metric, days: grouped)
            return series.hasData ? series : nil
        }

        return RecoveryInputsSeries(days: visibleDates, rows: rows)
    }

    /// Assigns run numbers to contiguous days with a value. Gap days keep
    /// nil, so the trend line never bridges a missing overnight reading.
    static func groupedIntoRuns(_ days: [RecoveryMetricDay]) -> [RecoveryMetricDay] {
        var runIndex = 0
        var previousPresent = false
        var result: [RecoveryMetricDay] = []
        result.reserveCapacity(days.count)
        for day in days {
            let present = day.value != nil
            if present && !previousPresent {
                runIndex += 1
            }
            result.append(day.withRunIndex(present ? runIndex : nil))
            previousPresent = present
        }
        return result
    }
}
