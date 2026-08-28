import Foundation
import SendLogHealthCore

// MARK: - Issue #802 AC1 — on-watch HealthKit read geometry + readiness compute

/// One local day's sleep totals, keyed by the day the sleep ENDS. Built by
/// the watch HealthKit service from `HKCategoryValueSleepAnalysis` samples;
/// `totalHours` is the sum of all asleep stages, `deepHours`/`remHours` the
/// restorative subset (SL-18 the phone's `SleepDay` folding).
public struct WatchSleepHours: Equatable, Sendable {
    public var totalHours: Double = 0
    public var deepHours: Double = 0
    public var remHours: Double = 0

    public init(totalHours: Double = 0, deepHours: Double = 0, remHours: Double = 0) {
        self.totalHours = totalHours
        self.deepHours = deepHours
        self.remHours = remHours
    }
}

/// The on-watch readiness metric: same column contract as the phone's
/// `HealthMetric` (SendmeterCore), kept in the shared Core package so both
/// the pure reconciliation and the Supabase row model can be tested on the
/// host without HealthKit.
public struct WatchHealthMetric: Codable, Equatable, Sendable, Identifiable {
    public var id: String { date }
    public let date: String
    public let readiness: Int?
    public let zone: String?
    /// Optional for the #661 keep-last-reading rule: when a pass preserves
    /// an existing score, the upsert omits `computed_at` so the DB row is
    /// not stamped as a fresh compute.
    public let computedAt: Date?
    public let hrvSDNNMilliseconds: Double?
    public let restingHeartRate: Double?
    public let sleepHours: Double?
    public let sleepDeepHours: Double?
    public let sleepREMHours: Double?
    public let bodyMassKilograms: Double?
    public let respiratoryRate: Double?

    public init(
        date: String,
        readiness: Int?,
        zone: String?,
        computedAt: Date?,
        hrvSDNNMilliseconds: Double?,
        restingHeartRate: Double?,
        sleepHours: Double?,
        sleepDeepHours: Double?,
        sleepREMHours: Double?,
        bodyMassKilograms: Double?,
        respiratoryRate: Double?
    ) {
        self.date = date
        self.readiness = readiness
        self.zone = zone
        self.computedAt = computedAt
        self.hrvSDNNMilliseconds = hrvSDNNMilliseconds
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
        self.sleepDeepHours = sleepDeepHours
        self.sleepREMHours = sleepREMHours
        self.bodyMassKilograms = bodyMassKilograms
        self.respiratoryRate = respiratoryRate
    }

    /// A candidate is source-backed only when at least one raw biometric is
    /// present; readiness/zone/computedAt alone never make an empty day
    /// eligible for persistence (#801 invariant, shared with the phone).
    public var hasSourceData: Bool {
        hrvSDNNMilliseconds != nil
            || restingHeartRate != nil
            || sleepHours != nil
            || sleepDeepHours != nil
            || sleepREMHours != nil
            || bodyMassKilograms != nil
            || respiratoryRate != nil
    }

    /// Same biometric columns with readiness/zone/computedAt nil — the
    /// `encodeIfPresent` omission that lets ON CONFLICT merge update only
    /// the inputs while an existing row keeps its score and timestamp.
    public func omittingReadiness() -> WatchHealthMetric {
        WatchHealthMetric(
            date: date,
            readiness: nil,
            zone: nil,
            computedAt: nil,
            hrvSDNNMilliseconds: hrvSDNNMilliseconds,
            restingHeartRate: restingHeartRate,
            sleepHours: sleepHours,
            sleepDeepHours: sleepDeepHours,
            sleepREMHours: sleepREMHours,
            bodyMassKilograms: bodyMassKilograms,
            respiratoryRate: respiratoryRate
        )
    }
}

/// Mirror of the phone's `HealthMetricReadWindow` (#801): exactly 28
/// candidate days (today plus the preceding 27), each using up to 28
/// preceding days as baseline — the deepest required source date is
/// today-55. The watch's HealthKit query must cover `queryLookbackDays`.
public enum WatchHealthReadWindow {
    public static let candidateDays = 28
    public static let baselineDays = 28
    public static let queryLookbackDays = candidateDays + baselineDays - 1

    public static var candidateOffsets: Range<Int> { 0..<candidateDays }
    public static var baselineOffsets: ClosedRange<Int> { 1...baselineDays }
}

/// Pure on-watch readiness compute (#802 AC1): takes the per-day HealthKit
/// aggregations (decoded by the watch app's HealthKit service) and runs the
/// same `RecoveryEngine` the phone uses, with the same baseline geometry.
/// No HealthKit, no Supabase — unit-tested on the host.
public enum WatchHealthCompute {
    /// Builds the candidate-window metrics from per-day HealthKit maps
    /// (keys are YYYY-MM-DD local days).
    public static func metrics(
        hrv: [String: Double],
        restingHR: [String: Double],
        respiratoryRate: [String: Double],
        sleep: [String: WatchSleepHours],
        bodyMass: [String: Double],
        acwrByDate: [String: Double] = [:],
        now: Date,
        timeZone: TimeZone
    ) throws -> [WatchHealthMetric] {
        var calendar = Calendar.gregorianLocal
        calendar.timeZone = timeZone
        let todayStart = calendar.startOfDay(for: now)
        let sourceDates = Set(hrv.keys)
            .union(restingHR.keys)
            .union(respiratoryRate.keys)
            .union(sleep.filter { $0.value.totalHours > 0 }.keys)
            .union(bodyMass.keys)

        var metrics: [WatchHealthMetric] = []
        metrics.reserveCapacity(WatchHealthReadWindow.candidateDays)
        for offset in WatchHealthReadWindow.candidateOffsets {
            guard let dateStart = calendar.date(
                byAdding: .day,
                value: -offset,
                to: todayStart
            ) else {
                throw WatchHealthReadError.dateCalculationFailed
            }
            let date = dateStart.dateString(in: calendar)
            guard sourceDates.contains(date) else { continue }

            let baselineDays = WatchHealthReadWindow.baselineOffsets.reversed().map {
                calendar.date(byAdding: .day, value: -Int($0), to: dateStart)?
                    .dateString(in: calendar) ?? ""
            }
            let inputs = DailyHealthInputs(
                hrvSDNNms: hrv[date],
                restingHR: restingHR[date],
                sleepHours: sleep[date]?.totalHours,
                bodyMassKg: latestBodyMass(onOrBefore: date, valuesByDate: bodyMass),
                sleepDeepHours: sleep[date]?.deepHours,
                sleepRemHours: sleep[date]?.remHours,
                respRateBpm: respiratoryRate[date],
                hrvLnBaseline: baselineDays
                    .compactMap { hrv[$0] }
                    .filter { $0 > 0 }
                    .map(log),
                rhrBaseline: baselineDays.compactMap { restingHR[$0] },
                sleepBaseline: baselineDays.compactMap { sleep[$0]?.totalHours },
                respBaseline: baselineDays.compactMap { respiratoryRate[$0] },
                restorativeSleepBaseline: baselineDays.compactMap {
                    guard let day = sleep[$0] else { return nil }
                    return day.deepHours + day.remHours
                }
            )
            let result = RecoveryEngine.compute(
                inputs: inputs,
                acwr: acwrByDate[date]
            )
            metrics.append(
                WatchHealthMetric(
                    date: date,
                    readiness: result.score,
                    zone: result.zone?.rawValue,
                    computedAt: now,
                    hrvSDNNMilliseconds: inputs.hrvSDNNms,
                    restingHeartRate: inputs.restingHR,
                    sleepHours: inputs.sleepHours,
                    sleepDeepHours: inputs.sleepDeepHours,
                    sleepREMHours: inputs.sleepRemHours,
                    bodyMassKilograms: inputs.bodyMassKg,
                    respiratoryRate: inputs.respRateBpm
                )
            )
        }
        return metrics
    }

    /// One ACWR per candidate date from the server's session loads (#661 F2:
    /// the server is the ACWR authority, never the in-memory session list).
    /// Each date's ratio uses the 90-day window ENDING that date, so a
    /// recompute is identical to the phone's per-date projection.
    public static func acwrByDate(
        rows: [SessionLoadRow],
        now: Date,
        timeZone: TimeZone,
        days: Int = 28,
        lookback: Int = 90
    ) -> [String: Double] {
        var calendar = Calendar.gregorianLocal
        calendar.timeZone = timeZone
        let todayStart = calendar.startOfDay(for: now)
        var result: [String: Double] = [:]
        guard !rows.isEmpty else { return result }
        for offset in 0..<min(days, WatchHealthReadWindow.candidateDays) {
            guard let dateStart = calendar.date(
                byAdding: .day,
                value: -offset,
                to: todayStart
            ) else { continue }
            let series = dailyLoadSeries(
                rows: rows,
                days: lookback,
                now: dateStart,
                timeZone: timeZone
            )
            if let ratio = ewmaAcwr(dailyLoads: series) {
                result[dateStart.dateString(in: calendar)] = ratio
            }
        }
        return result
    }

    private static func latestBodyMass(
        onOrBefore date: String,
        valuesByDate: [String: Double]
    ) -> Double? {
        guard let latestDate = valuesByDate.keys
            .filter({ $0 <= date })
            .max()
        else { return nil }
        return valuesByDate[latestDate]
    }
}

public enum WatchHealthReadError: Error, Equatable {
    case dateCalculationFailed
}
