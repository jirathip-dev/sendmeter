import Foundation
import HealthKit
import SendLogHealthCore
import SendmeterCore

@MainActor
public final class HealthKitService: ObservableObject {
    @Published public private(set) var authorizationStatus: HKAuthorizationStatus = .notDetermined
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastError: String?

    private let store: HKHealthStore
    private let calendar: Calendar

    public init(
        store: HKHealthStore = HKHealthStore(),
        timeZone: TimeZone = .current
    ) {
        self.store = store
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    public func requestAuthorization() async throws {
        guard isAvailable else { return }
        let readTypes = try requiredReadTypes()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: HealthKitError.authorizationDenied)
                }
            }
        }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            authorizationStatus = store.authorizationStatus(for: hrv)
        }
        await enableBackgroundDelivery()
    }

    public func computeTodayMetric(acwr: Double?) async throws -> HealthMetric {
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        do {
            let now = Date()
            let todayStart = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
            let baselineStart = calendar.date(byAdding: .day, value: -28, to: todayStart)!

            async let hrvMap = dailyAverages(
                identifier: .heartRateVariabilitySDNN,
                unit: .secondUnit(with: .milli),
                start: baselineStart,
                end: tomorrow
            )
            async let rhrMap = dailyAverages(
                identifier: .restingHeartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                start: baselineStart,
                end: tomorrow
            )
            async let respMap = dailyAverages(
                identifier: .respiratoryRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                start: baselineStart,
                end: tomorrow
            )
            async let sleepMap = dailySleep(start: baselineStart, end: tomorrow)
            async let bodyMass = latestQuantity(
                identifier: .bodyMass,
                unit: .gramUnit(with: .kilo),
                start: baselineStart,
                end: tomorrow
            )

            let hrv = try await hrvMap
            let rhr = try await rhrMap
            let resp = try await respMap
            let sleep = try await sleepMap
            let mass = try await bodyMass
            let today = LocalDateSupport.string(from: now, timeZone: calendar.timeZone)

            let baselineDays = (1...28).reversed().map {
                LocalDateSupport.daysAgo($0, from: now, timeZone: calendar.timeZone)
            }
            let inputs = DailyHealthInputs(
                hrvSDNNms: hrv[today],
                restingHR: rhr[today],
                sleepHours: sleep[today]?.totalHours,
                bodyMassKg: mass,
                sleepDeepHours: sleep[today]?.deepHours,
                sleepRemHours: sleep[today]?.remHours,
                respRateBpm: resp[today],
                hrvLnBaseline: baselineDays.compactMap { hrv[$0] }.filter { $0 > 0 }.map(log),
                rhrBaseline: baselineDays.compactMap { rhr[$0] },
                sleepBaseline: baselineDays.compactMap { sleep[$0]?.totalHours },
                respBaseline: baselineDays.compactMap { resp[$0] },
                restorativeSleepBaseline: baselineDays.compactMap {
                    guard let day = sleep[$0] else { return nil }
                    return day.deepHours + day.remHours
                }
            )
            let result = RecoveryEngine.compute(inputs: inputs, acwr: acwr)
            return HealthMetric(
                date: today,
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
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func requiredReadTypes() throws -> Set<HKObjectType> {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .respiratoryRate,
            .bodyMass
        ]
        var types = Set<HKObjectType>()
        for identifier in identifiers {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
                throw HealthKitError.typeUnavailable(identifier.rawValue)
            }
            types.insert(type)
        }
        guard let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitError.typeUnavailable(HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
        }
        types.insert(sleep)
        return types
    }

    private func enableBackgroundDelivery() async {
        for identifier in [
            HKQuantityTypeIdentifier.heartRateVariabilitySDNN,
            .restingHeartRate,
            .respiratoryRate
        ] {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
            await withCheckedContinuation { continuation in
                store.enableBackgroundDelivery(for: type, frequency: .daily) { _, _ in
                    continuation.resume()
                }
            }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            await withCheckedContinuation { continuation in
                store.enableBackgroundDelivery(for: sleep, frequency: .daily) { _, _ in
                    continuation.resume()
                }
            }
        }
    }

    private func dailyAverages(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw HealthKitError.typeUnavailable(identifier.rawValue)
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate]
        )
        var day = DateComponents()
        day.day = 1
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage],
                anchorDate: calendar.startOfDay(for: start),
                intervalComponents: day
            )
            query.initialResultsHandler = { [calendar] _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [:])
                    return
                }
                var values: [String: Double] = [:]
                collection.enumerateStatistics(from: start, to: end) { statistics, _ in
                    guard let quantity = statistics.averageQuantity() else { return }
                    let key = LocalDateSupport.string(
                        from: statistics.startDate,
                        timeZone: calendar.timeZone
                    )
                    values[key] = quantity.doubleValue(for: unit)
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    private func latestQuantity(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw HealthKitError.typeUnavailable(identifier.rawValue)
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictEndDate]
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func dailySleep(start: Date, end: Date) async throws -> [String: SleepDay] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitError.typeUnavailable(HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictEndDate]
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { [calendar] _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var byDay: [String: SleepDay] = [:]
                for sample in samples as? [HKCategorySample] ?? [] {
                    let seconds = max(0, sample.endDate.timeIntervalSince(sample.startDate))
                    guard seconds > 0 else { continue }
                    let key = LocalDateSupport.string(
                        from: sample.endDate.addingTimeInterval(-1),
                        timeZone: calendar.timeZone
                    )
                    var day = byDay[key] ?? SleepDay()
                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        day.deepHours += seconds / 3_600
                        day.totalHours += seconds / 3_600
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        day.remHours += seconds / 3_600
                        day.totalHours += seconds / 3_600
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                         HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        day.totalHours += seconds / 3_600
                    default:
                        break
                    }
                    byDay[key] = day
                }
                continuation.resume(returning: byDay)
            }
            store.execute(query)
        }
    }
}

private struct SleepDay {
    var totalHours: Double = 0
    var deepHours: Double = 0
    var remHours: Double = 0
}

public enum HealthKitError: Error, LocalizedError {
    case authorizationDenied
    case typeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Health access was not granted."
        case let .typeUnavailable(type):
            return "Apple Health type is unavailable: \(type)"
        }
    }
}
