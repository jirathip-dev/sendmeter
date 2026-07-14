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

        func nightWindow(endingOn day: Date) -> DateInterval {
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
            let start = cal.date(byAdding: .hour, value: -18, to: noon)! // 18:00 prev day
            return DateInterval(start: start, end: noon)
        }

        let todayWindow = nightWindow(endingOn: now)

        async let hrvToday = meanQuantity(
            .heartRateVariabilitySDNN, in: todayWindow,
            unit: .secondUnit(with: .milli)
        )
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
        for d in 1...t.baselineDays {
            guard let day = cal.date(byAdding: .day, value: -d, to: now) else { continue }
            let w = nightWindow(endingOn: day)
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
            if let s = try? await sleepBreakdown(in: w).totalHours, s > 0 {
                sleepBase.append(s)
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
            sleepBaseline: sleepBase
        )
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
