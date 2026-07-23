import Foundation
import HealthKit
import SendLogHealthCore

protocol HealthMetricsProviding {
    func readToday() async throws -> DailyHealthInputs
}

/// Reads last night's HRV / resting HR / sleep / body mass / respiratory rate
/// plus 30-day baselines from HealthKit. Night window: 18:00 yesterday →
/// 12:00 today. Ported from the watch's HealthMetricsProvider — the only
/// change is that it now runs on the **iPhone**, whose HealthKit store is the
/// merged aggregate (Oura/Garmin/etc. write there via their companion apps),
/// so third-party wearable data is captured.
final class HealthKitReader: HealthMetricsProviding {
    private let store = HKHealthStore()
    private let t: RecoveryTunables

    init(tunables: RecoveryTunables = .default) {
        self.t = tunables
    }

    static var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.bodyMass),
            HKQuantityType(.respiratoryRate),
            HKCategoryType(.sleepAnalysis),
        ]
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// HKObserverQuery background delivery needs an observed sample type; HRV
    /// is the primary readiness driver so we observe it.
    static let observedType = HKQuantityType(.heartRateVariabilitySDNN)
    var healthStore: HKHealthStore { store }

    func readToday() async throws -> DailyHealthInputs {
        try await requestAuthorization()
        let now = Date()
        let cal = Calendar.gregorianLocal

        let todayWindow = cal.nightWindow(endingOn: now)

        async let hrvToday = meanQuantity(
            .heartRateVariabilitySDNN, in: todayWindow,
            unit: .secondUnit(with: .milli)
        )
        // NOT bound to todayWindow: Apple's daily resting-HR estimate is
        // often timestamped mid-day rather than overnight, so night-windowing
        // it would frequently make today's RHR nil (and could starve the
        // baseline below minBaselineDays, silently dropping the whole term).
        // #109's intraday-instability fix instead lives at the write layer
        // (see HealthSyncManager + ReadinessWritePolicy) — an automatic
        // re-sync stops overwriting an already-computed today after noon,
        // rather than trying to make the HealthKit read itself stable.
        async let rhrToday = latestQuantity(
            .restingHeartRate, in: DateInterval(start: cal.startOfDay(for: now), end: now),
            unit: .count().unitDivided(by: .minute())
        )
        async let sleepToday = sleepBreakdown(in: todayWindow)
        async let mass = latestQuantity(
            .bodyMass,
            in: DateInterval(start: cal.date(byAdding: .day, value: -30, to: now)!, end: now),
            unit: .gramUnit(with: .kilo)
        )
        async let respRateToday = meanQuantity(
            .respiratoryRate, in: todayWindow,
            unit: .count().unitDivided(by: .minute())
        )

        // Baselines: per-night aggregates over the trailing window (excluding today)
        var hrvBase: [Double] = []
        var rhrBase: [Double] = []
        var sleepBase: [Double] = []
        var respBase: [Double] = []        // SL-18
        var restBase: [Double] = []        // SL-18: deep+REM hours
        for d in 1...t.baselineDays {
            guard let day = cal.date(byAdding: .day, value: -d, to: now) else { continue }
            let w = cal.nightWindow(endingOn: day)
            if let hrv = try? await meanQuantity(
                .heartRateVariabilitySDNN, in: w, unit: .secondUnit(with: .milli)
            ), hrv > 0 {
                hrvBase.append(log(hrv))
            }
            if let rhr = try? await latestQuantity(
                .restingHeartRate,
                in: DateInterval(start: cal.startOfDay(for: day), end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!),
                unit: .count().unitDivided(by: .minute())
            ) {
                rhrBase.append(rhr)
            }
            if let sb = try? await sleepBreakdown(in: w) {
                if let total = sb.totalHours, total > 0 { sleepBase.append(total) }
                let rest = (sb.deepHours ?? 0) + (sb.remHours ?? 0)
                if rest > 0 { restBase.append(rest) }
            }
            if let resp = try? await meanQuantity(
                .respiratoryRate, in: w, unit: .count().unitDivided(by: .minute())
            ), resp > 0 {
                respBase.append(resp)
            }
        }

        let sleep = try await sleepToday
        return DailyHealthInputs(
            hrvSDNNms: try await hrvToday,
            restingHR: try await rhrToday,
            sleepHours: sleep.totalHours,
            bodyMassKg: try await mass,
            sleepDeepHours: sleep.deepHours,
            sleepRemHours: sleep.remHours,
            respRateBpm: try await respRateToday,
            hrvLnBaseline: hrvBase,
            rhrBaseline: rhrBase,
            sleepBaseline: sleepBase,
            respBaseline: respBase,
            restorativeSleepBaseline: restBase
        )
    }

    /// One night's worth of aggregates, computed once and reused as both a
    /// day's own values and (for later days) a baseline entry — so a history
    /// backfill is O(days + baselineDays) night reads, not O(days × baseline).
    private struct NightAggregate {
        var hrv: Double?
        var rhr: Double?
        var sleepTotal: Double?
        var sleepDeep: Double?
        var sleepRem: Double?
        var resp: Double?
    }

    private func nightAggregate(endingOn day: Date, capEnd: Date?) async throws -> NightAggregate {
        let cal = Calendar.gregorianLocal
        let night = cal.nightWindow(endingOn: day)
        let dayStart = cal.startOfDay(for: day)
        let dayEndFull = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let dayEnd = capEnd.map { min(dayEndFull, $0) } ?? dayEndFull

        async let hrv = meanQuantity(
            .heartRateVariabilitySDNN, in: night, unit: .secondUnit(with: .milli)
        )
        async let rhr = latestQuantity(
            .restingHeartRate, in: DateInterval(start: dayStart, end: dayEnd),
            unit: .count().unitDivided(by: .minute())
        )
        async let sleep = sleepBreakdown(in: night)
        async let resp = meanQuantity(
            .respiratoryRate, in: night, unit: .count().unitDivided(by: .minute())
        )

        let s = try await sleep
        return NightAggregate(
            hrv: try await hrv, rhr: try await rhr,
            sleepTotal: s.totalHours, sleepDeep: s.deepHours, sleepRem: s.remHours,
            resp: try await resp
        )
    }

    /// Rebuild the trailing `days` of daily inputs (newest first) from HealthKit
    /// — each day computed against its own trailing baseline window, exactly as
    /// `readToday` does for today, but for the whole span. Per-night aggregates
    /// are computed once and shared across days' baselines to keep the query
    /// count linear. Used by the "Clear & resync" full-history backfill.
    func readHistory(days: Int) async throws -> [(date: String, inputs: DailyHealthInputs)] {
        try await requestAuthorization()
        let cal = Calendar.gregorianLocal
        let now = Date()
        let total = days + t.baselineDays

        var agg: [NightAggregate] = []
        agg.reserveCapacity(total)
        for o in 0..<total {
            let day = cal.date(byAdding: .day, value: -o, to: now)!
            agg.append(try await nightAggregate(endingOn: day, capEnd: o == 0 ? now : nil))
        }

        var out: [(date: String, inputs: DailyHealthInputs)] = []
        for o in 0..<days {
            let day = cal.date(byAdding: .day, value: -o, to: now)!
            var hrvBase: [Double] = []
            var rhrBase: [Double] = []
            var sleepBase: [Double] = []
            var respBase: [Double] = []    // SL-18
            var restBase: [Double] = []    // SL-18: deep+REM hours
            for b in 1...t.baselineDays {
                let a = agg[o + b]
                if let h = a.hrv, h > 0 { hrvBase.append(log(h)) }
                if let r = a.rhr { rhrBase.append(r) }
                if let s = a.sleepTotal, s > 0 { sleepBase.append(s) }
                if let rp = a.resp, rp > 0 { respBase.append(rp) }
                let rest = (a.sleepDeep ?? 0) + (a.sleepRem ?? 0)
                if rest > 0 { restBase.append(rest) }
            }
            let massWindow = DateInterval(
                start: cal.date(byAdding: .day, value: -30, to: day)!, end: day
            )
            let mass = (try? await latestQuantity(
                .bodyMass, in: massWindow, unit: .gramUnit(with: .kilo)
            )) ?? nil
            let a = agg[o]
            out.append((
                date: day.localDateString,
                inputs: DailyHealthInputs(
                    hrvSDNNms: a.hrv,
                    restingHR: a.rhr,
                    sleepHours: a.sleepTotal,
                    bodyMassKg: mass,
                    sleepDeepHours: a.sleepDeep,
                    sleepRemHours: a.sleepRem,
                    respRateBpm: a.resp,
                    hrvLnBaseline: hrvBase,
                    rhrBaseline: rhrBase,
                    sleepBaseline: sleepBase,
                    respBaseline: respBase,
                    restorativeSleepBaseline: restBase
                )
            ))
        }
        return out
    }

    // MARK: HealthKit query helpers

    private func samples(
        _ type: HKSampleType, in window: DateInterval
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: window.start, end: window.end)
            let q = HKSampleQuery(
                sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            store.execute(q)
        }
    }

    private func meanQuantity(
        _ id: HKQuantityTypeIdentifier, in window: DateInterval, unit: HKUnit
    ) async throws -> Double? {
        let values = try await samples(HKQuantityType(id), in: window)
            .compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: unit) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func latestQuantity(
        _ id: HKQuantityTypeIdentifier, in window: DateInterval, unit: HKUnit
    ) async throws -> Double? {
        let all = try await samples(HKQuantityType(id), in: window)
        return (all.last as? HKQuantitySample)?.quantity.doubleValue(for: unit)
    }

    private struct SleepBreakdown {
        var totalHours: Double?
        var deepHours: Double?
        var remHours: Double?
    }

    /// Total asleep hours plus deep/REM stage breakdown. Stages are merged
    /// independently (a source double-reporting the same stage shouldn't
    /// double-count it), never merged across stages since they're mutually
    /// exclusive. Stage data needs no new HealthKit permission — it's part of
    /// the same sleepAnalysis samples already being read for the total.
    private func sleepBreakdown(in window: DateInterval) async throws -> SleepBreakdown {
        let allAsleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let raw = try await samples(HKCategoryType(.sleepAnalysis), in: window)
            .compactMap { $0 as? HKCategorySample }

        func mergedHours(matching values: Set<Int>) -> Double? {
            let intervals = raw
                .filter { values.contains($0.value) }
                .map { DateInterval(start: $0.startDate, end: $0.endDate) }
                .sorted { $0.start < $1.start }
            guard !intervals.isEmpty else { return nil }
            var merged: [DateInterval] = []
            for iv in intervals {
                if let last = merged.last, iv.start <= last.end {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, iv.end))
                } else {
                    merged.append(iv)
                }
            }
            return merged.reduce(0) { $0 + $1.duration } / 3600
        }

        return SleepBreakdown(
            totalHours: mergedHours(matching: allAsleepValues),
            deepHours: mergedHours(matching: [HKCategoryValueSleepAnalysis.asleepDeep.rawValue]),
            remHours: mergedHours(matching: [HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        )
    }
}
