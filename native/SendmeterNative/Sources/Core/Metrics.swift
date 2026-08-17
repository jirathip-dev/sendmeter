import Foundation

public enum TrainingMetrics {
    public static let acuteSpanDays = 7
    public static let chronicSpanDays = 28
    public static let ewmaLookbackDays = 90

    public static func acwrStatus(_ ratio: Double?) -> ACWRStatus {
        guard let ratio else { return .noData }
        if ratio < 0.7 { return .underTraining }
        if ratio <= 0.8 { return .low }
        if ratio <= 1.3 { return .optimal }
        if ratio <= 1.5 { return .caution }
        return .danger
    }

    public static func phaseFit(
        ratio: Double?,
        phase: PhaseDefinition
    ) -> PhaseFit? {
        guard let ratio else { return nil }
        if ratio < phase.acwrLow { return .below }
        if ratio > phase.acwrHigh { return .above }
        return .onTarget
    }

    public static func ewma(
        values: [Double?],
        span: Int
    ) -> [Double?] {
        precondition(span > 0, "EWMA span must be positive")
        let alpha = 2.0 / (Double(span) + 1.0)
        var result: [Double?] = []
        result.reserveCapacity(values.count)
        var running: Double?
        for value in values {
            if let value {
                running = running.map { value * alpha + $0 * (1 - alpha) } ?? value
            }
            result.append(running)
        }
        return result
    }

    public static func ewmaLoadState(
        sessions: [Session],
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> EWMALoadState? {
        let loadByDate = Dictionary(grouping: sessions, by: \Session.date)
            .mapValues { $0.reduce(0) { $0 + $1.load } }

        var dailyLoads: [Double] = []
        dailyLoads.reserveCapacity(ewmaLookbackDays)
        for offset in stride(from: ewmaLookbackDays - 1, through: 0, by: -1) {
            let day = LocalDateSupport.daysAgo(offset, from: referenceDate, timeZone: timeZone)
            dailyLoads.append(loadByDate[day] ?? 0)
        }

        guard dailyLoads.contains(where: { $0 != 0 }) else { return nil }
        let seed = dailyLoads.reduce(0, +) / Double(dailyLoads.count)
        let series: [Double?] = [seed] + dailyLoads.map(Optional.some)
        let acute = ewma(values: series, span: acuteSpanDays).last ?? nil
        let chronic = ewma(values: series, span: chronicSpanDays).last ?? nil
        guard let acute, let chronic else { return nil }
        return EWMALoadState(acute: acute, chronic: chronic)
    }

    public static func computeACWR(
        sessions: [Session],
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> ACWRData {
        let today = LocalDateSupport.daysAgo(0, from: referenceDate, timeZone: timeZone)
        let acuteStart = LocalDateSupport.daysAgo(6, from: referenceDate, timeZone: timeZone)
        let chronicStart = LocalDateSupport.daysAgo(27, from: referenceDate, timeZone: timeZone)

        let acute = sessions
            .filter { $0.date >= acuteStart && $0.date <= today }
            .reduce(0) { $0 + $1.load }
        let chronic = sessions
            .filter { $0.date >= chronicStart && $0.date <= today }
            .reduce(0) { $0 + $1.load } / 4.0

        let state = ewmaLoadState(
            sessions: sessions,
            referenceDate: referenceDate,
            timeZone: timeZone
        )
        let ratio: Double?
        if let state, state.chronic > 0 {
            ratio = state.acute / state.chronic
        } else {
            ratio = nil
        }
        return ACWRData(acute: acute, chronic: chronic, ratio: ratio)
    }

    /// ACWR ratio from a server-derived daily-load series (oldest first, one
    /// entry per day, length `ewmaLookbackDays`). Exactly the `ratio` path of
    /// `computeACWR` — same EWMA seeding/series — so a recompute that reads
    /// the server (never the in-memory `sessions`, #661 F2) produces the same
    /// number the Dashboard would show once sessions are loaded.
    public static func acwrRatio(
        dailyLoads: [Double]
    ) -> Double? {
        guard dailyLoads.contains(where: { $0 != 0 }) else { return nil }
        let seed = dailyLoads.reduce(0, +) / Double(dailyLoads.count)
        let series: [Double?] = [seed] + dailyLoads.map(Optional.some)
        let acute = ewma(values: series, span: acuteSpanDays).last ?? nil
        let chronic = ewma(values: series, span: chronicSpanDays).last ?? nil
        guard let acute, let chronic, chronic > 0 else { return nil }
        return acute / chronic
    }

    public static func weeklyLoads(
        sessions: [Session],
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [WeeklyLoad] {
        [3, 2, 1, 0].map { weekBack in
            let start = LocalDateSupport.daysAgo(
                weekBack * 7 + 6,
                from: referenceDate,
                timeZone: timeZone
            )
            let end = LocalDateSupport.daysAgo(
                weekBack * 7,
                from: referenceDate,
                timeZone: timeZone
            )
            let total = sessions
                .filter { $0.date >= start && $0.date <= end }
                .reduce(0) { $0 + $1.load }
            return WeeklyLoad(label: weekBack == 0 ? "Now" : "\(weekBack)w", total: total)
        }
    }

    public static func tindeqStats(
        recordings: [TindeqRecording],
        referenceDate: Date = Date()
    ) -> TindeqStats? {
        let measured = recordings.filter {
            $0.source != .manual && $0.peakKilograms != nil && $0.averageKilograms != nil
        }
        guard measured.count >= 2 else { return nil }
        let sorted = measured.sorted { $0.recordedAt < $1.recordedAt }
        guard let last = sorted.last, let lastPeak = last.peakKilograms else { return nil }
        let bestPeak = sorted.compactMap(\.peakKilograms).max() ?? lastPeak
        let cutoff = referenceDate.addingTimeInterval(-30 * 86_400)
        let window = sorted.filter { $0.recordedAt >= cutoff && $0.id != last.id }
        let priorPeaks = window.compactMap(\.peakKilograms)
        let average = priorPeaks.isEmpty ? nil : priorPeaks.reduce(0, +) / Double(priorPeaks.count)
        return TindeqStats(
            bestPeak: bestPeak,
            lastPeak: lastPeak,
            average30Days: average,
            delta: average.map { lastPeak - $0 }
        )
    }

    public static func canonicalPhaseStart(
        periods: [PhasePeriod],
        currentPhase: PhaseID,
        fallbackStartDate: String
    ) -> String {
        periods.first(where: { $0.endedOn == nil && $0.phase == currentPhase })?.startedOn
            ?? fallbackStartDate
    }

    public static func phaseBlockAge(
        periods: [PhasePeriod],
        currentPhase: PhaseID,
        fallbackStartDate: String,
        referenceDate: String,
        timeZone: TimeZone = .current
    ) -> BlockAge? {
        let start = canonicalPhaseStart(
            periods: periods,
            currentPhase: currentPhase,
            fallbackStartDate: fallbackStartDate
        )
        guard let distance = LocalDateSupport.dayDistance(
            from: start,
            to: referenceDate,
            timeZone: timeZone
        ), distance >= 0 else { return nil }
        let totalDays = distance + 1
        return BlockAge(
            totalDays: totalDays,
            week: ((totalDays - 1) / 7) + 1,
            dayInWeek: ((totalDays - 1) % 7) + 1
        )
    }

    public static func phaseStepBackSuggestion(
        readinessHistory: [HealthMetric],
        currentPhase: PhaseID,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> PhaseStepBackSuggestion {
        guard currentPhase == .power || currentPhase == .strength else {
            return PhaseStepBackSuggestion(suggested: false, streakDays: 0)
        }
        let byDate = Dictionary(uniqueKeysWithValues: readinessHistory.map { ($0.date, $0.readiness) })
        var streak = 0
        for offset in 0..<365 {
            let day = LocalDateSupport.daysAgo(offset, from: referenceDate, timeZone: timeZone)
            guard let nested = byDate[day], let readiness = nested, readiness < 40 else { break }
            streak += 1
        }
        return PhaseStepBackSuggestion(suggested: streak >= 3, streakDays: streak)
    }

    /// The per-day readiness series the Dashboard trend chart plots (#664) —
    /// web `ReadinessCard.tsx` parity. The web derives a date-indexed lookup
    /// over the last 14 calendar days, filling gaps with "no data"; this is
    /// the same derivation, returning the window oldest → newest. Metrics
    /// outside the window (or days with no row) fall back to nil values, so
    /// the chart always has a full 14-bar axis.
    ///
    /// Contiguous non-nil days are grouped into "runs" via `runIndex`
    /// (nil on a gap day): Swift Charts bridges nothing across a run break,
    /// so a week without a watch plots an honest gap instead of a
    /// plunge-to-zero line. The web parallels this with the 2 px empty stub
    /// (`ReadinessCard.tsx`) — same visible meaning, native marks.
    public static func readinessSeries(
        metrics: [HealthMetric],
        days: Int = 14,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [ReadinessDay] {
        precondition(days > 0, "days must be positive")
        // Last-wins on a duplicate date, same as the web's `new Map(...)`.
        let byDate = Dictionary(metrics.map { ($0.date, $0) }, uniquingKeysWith: { _, new in new })
        let window = (0..<days).reversed().map { offset in
            let day = LocalDateSupport.daysAgo(offset, from: referenceDate, timeZone: timeZone)
            let metric = byDate[day]
            return ReadinessDay(
                date: day,
                dateValue: LocalDateSupport.date(from: day, timeZone: timeZone) ?? referenceDate,
                readiness: metric?.readiness,
                zone: metric?.zone,
                hrvSDNNMilliseconds: metric?.hrvSDNNMilliseconds,
                restingHeartRate: metric?.restingHeartRate,
                sleepHours: metric?.sleepHours
            )
        }
        return groupedIntoRuns(window)
    }

    /// Assigns a `runIndex` to each contiguous run of non-nil readiness days,
    /// oldest → newest. Gap days (nil readiness) keep `runIndex` nil. Two
    /// days share a runIndex iff they are adjacent in the window AND both
    /// have a score.
    static func groupedIntoRuns(_ window: [ReadinessDay]) -> [ReadinessDay] {
        var runIndex = 0
        var previousScored = false
        var result: [ReadinessDay] = []
        result.reserveCapacity(window.count)
        for day in window {
            let scored = day.readiness != nil
            if scored && !previousScored {
                runIndex += 1
            }
            result.append(day.withRunIndex(scored ? runIndex : nil))
            previousScored = scored
        }
        return result
    }
}

public struct EWMALoadState: Equatable, Sendable {
    public let acute: Double
    public let chronic: Double

    public init(acute: Double, chronic: Double) {
        self.acute = acute
        self.chronic = chronic
    }
}

public enum PhaseFit: String, Codable, Sendable {
    case below
    case onTarget = "on"
    case above
}

public struct TindeqStats: Equatable, Sendable {
    public let bestPeak: Double
    public let lastPeak: Double
    public let average30Days: Double?
    public let delta: Double?

    public init(bestPeak: Double, lastPeak: Double, average30Days: Double?, delta: Double?) {
        self.bestPeak = bestPeak
        self.lastPeak = lastPeak
        self.average30Days = average30Days
        self.delta = delta
    }
}

public struct BlockAge: Equatable, Sendable {
    public let totalDays: Int
    public let week: Int
    public let dayInWeek: Int

    public init(totalDays: Int, week: Int, dayInWeek: Int) {
        self.totalDays = totalDays
        self.week = week
        self.dayInWeek = dayInWeek
    }
}

public struct PhaseStepBackSuggestion: Equatable, Sendable {
    public let suggested: Bool
    public let streakDays: Int

    public init(suggested: Bool, streakDays: Int) {
        self.suggested = suggested
        self.streakDays = streakDays
    }
}

/// One day of the Dashboard's 14-day readiness trend series (#664). `dateValue`
/// is the parsed chart x-coordinate (a stable Gregorian date in local time);
/// the metric fields are nil when that day has no `health_metrics` row, so
/// the chart can render a full window with honest gaps. `runIndex` groups
/// contiguous scored days — the chart must pass it through `series:` so a gap
/// between runs is never bridged by interpolation.
public struct ReadinessDay: Equatable, Identifiable, Sendable {
    public var id: String { date }
    public let date: String
    public let dateValue: Date
    public let readiness: Int?
    public let zone: String?
    public let hrvSDNNMilliseconds: Double?
    public let restingHeartRate: Double?
    public let sleepHours: Double?
    public let runIndex: Int?

    public init(
        date: String,
        dateValue: Date,
        readiness: Int?,
        zone: String?,
        hrvSDNNMilliseconds: Double?,
        restingHeartRate: Double?,
        sleepHours: Double?,
        runIndex: Int? = nil
    ) {
        self.date = date
        self.dateValue = dateValue
        self.readiness = readiness
        self.zone = zone
        self.hrvSDNNMilliseconds = hrvSDNNMilliseconds
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
        self.runIndex = runIndex
    }

    func withRunIndex(_ runIndex: Int?) -> ReadinessDay {
        ReadinessDay(
            date: date,
            dateValue: dateValue,
            readiness: readiness,
            zone: zone,
            hrvSDNNMilliseconds: hrvSDNNMilliseconds,
            restingHeartRate: restingHeartRate,
            sleepHours: sleepHours,
            runIndex: runIndex
        )
    }
}
