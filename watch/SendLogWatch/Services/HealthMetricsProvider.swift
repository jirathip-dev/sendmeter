import Foundation
import HealthKit

protocol HealthMetricsProviding {
    func readToday() async throws -> DailyHealthInputs
}

/// Reads last night's HRV / resting HR / sleep / body mass plus 30-day
/// baselines from HealthKit. Night window: 18:00 yesterday → 12:00 today.
final class HealthKitMetricsProvider: HealthMetricsProviding {
    private let store = HKHealthStore()
    private let t: RecoveryTunables

    init(tunables: RecoveryTunables = .default) {
        self.t = tunables
    }

    func requestAuthorization() async throws {
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.bodyMass),
            HKCategoryType(.sleepAnalysis),
        ]
        try await store.requestAuthorization(toShare: [], read: read)
    }

    func readToday() async throws -> DailyHealthInputs {
        try await requestAuthorization()
        let now = Date()
        let cal = Calendar.current

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
        async let sleepToday = sleepHours(in: todayWindow)
        async let mass = latestQuantity(
            .bodyMass,
            in: DateInterval(start: cal.date(byAdding: .day, value: -30, to: now)!, end: now),
            unit: .gramUnit(with: .kilo)
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
            if let s = try? await sleepHours(in: w), s > 0 {
                sleepBase.append(s)
            }
        }

        return DailyHealthInputs(
            hrvSDNNms: try await hrvToday,
            restingHR: try await rhrToday,
            sleepHours: try await sleepToday,
            bodyMassKg: try await mass,
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

    /// Total asleep hours in the window, overlapping intervals merged
    /// (multiple sources can double-report).
    private func sleepHours(in window: DateInterval) async throws -> Double? {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let intervals = try await samples(HKCategoryType(.sleepAnalysis), in: window)
            .compactMap { s -> DateInterval? in
                guard let cs = s as? HKCategorySample, asleepValues.contains(cs.value) else { return nil }
                return DateInterval(start: cs.startDate, end: cs.endDate)
            }
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
}

/// Plausible canned data for the simulator (it can't seed resting HR) and
/// for exercising the UI without a real night of watch wear.
struct FakeHealthMetricsProvider: HealthMetricsProviding {
    func readToday() async throws -> DailyHealthInputs {
        DailyHealthInputs(
            hrvSDNNms: 72,
            restingHR: 52,
            sleepHours: 7.4,
            bodyMassKg: 71.2,
            hrvLnBaseline: (0..<30).map { log(60 + Double($0 % 7) * 3) },
            rhrBaseline: (0..<30).map { 54 + Double($0 % 5) - 2 },
            sleepBaseline: (0..<30).map { 7.0 + Double($0 % 4) * 0.3 - 0.4 }
        )
    }
}
