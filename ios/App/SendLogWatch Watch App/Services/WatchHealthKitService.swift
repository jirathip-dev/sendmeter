import Foundation
import HealthKit
import SendLogHealthCore
import SendLogWatchCore

/// Owns one HealthKit query and its checked continuation — a direct port of
/// the phone's `HealthKitQueryCancellation` (HealthKit invokes result
/// handlers independently of Swift task cancellation, so cancellation must
/// stop the query and resume the continuation itself; the lock makes the
/// cancellation/result race one-shot).
private final class HealthKitQueryCancellation<Value>: @unchecked Sendable {
    private let store: HKHealthStore
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var query: HKQuery?
    private var finished = false

    init(store: HKHealthStore) {
        self.store = store
    }

    deinit {
        // Keep destruction explicit: Swift 6.3.3's Release SIL optimizer can
        // mis-handle the synthesized generic deinit for this ownership mix.
        continuation = nil
        query = nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(_ query: HKQuery) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            store.stop(query)
            return false
        }
        self.query = query
        lock.unlock()
        return true
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let query = self.query
        self.continuation = nil
        self.query = nil
        lock.unlock()

        if let query {
            store.stop(query)
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let query = self.query
        self.continuation = nil
        self.query = nil
        lock.unlock()

        if let query {
            store.stop(query)
        }
        continuation?.resume(throwing: CancellationError())
    }
}

/// The watch's HealthKit read (#802 AC1): the same query set the phone's
/// `HealthKitService` uses (HRV SDNN, resting HR, respiratory rate, sleep
/// analysis, body mass) executed against the WATCH's own HealthKit store.
/// All computation is deferred to the pure `WatchHealthCompute` layer; this
/// type only performs queries and builds the per-day maps.
final class WatchHealthKitService {
    /// The types whose background delivery wakes the watch app so the
    /// morning refresh can compute without the user opening it (#802 AC3).
    /// Mirrors the phone's `HealthObserverTypes.observedIdentifiers` +
    /// `requiredReadTypes`.
    static let observedIdentifiers: [String] = [
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierRespiratoryRate",
        "HKCategoryTypeIdentifierSleepAnalysis",
        "HKQuantityTypeIdentifierBodyMass",
    ]

    private let store: HKHealthStore
    private var observersRegistered = false
    private var backgroundSetupRegistered = false

    /// Fired on the main actor when a background observer query detects new
    /// data for one of the observed types. Wired by `HealthSyncManager` to
    /// the same single-flight trigger as foreground sync — the overnight
    /// HealthKit write is the morning refresh's wake-up point.
    var onBackgroundUpdate: (@MainActor () async -> Void)?

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Idempotent per-process registration of background delivery + observer
    /// queries. The observer queries live only for this process, so a cold
    /// HealthKit wake (which relaunches the app) must re-register; call from
    /// launch/foreground triggers. Runtime delivery is device-only.
    func ensureBackgroundObserversRegistered() async {
        guard isAvailable, !backgroundSetupRegistered, !Task.isCancelled else {
            return
        }
        backgroundSetupRegistered = true
        await enableBackgroundDelivery()
        guard !Task.isCancelled else {
            backgroundSetupRegistered = false
            return
        }
        registerBackgroundObservers()
    }

    private func registerBackgroundObservers() {
        guard !observersRegistered, isAvailable else { return }
        observersRegistered = true
        for identifier in Self.observedIdentifiers {
            guard let type = Self.objectType(for: identifier) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in
                    defer { completion() }
                    guard !Task.isCancelled else { return }
                    await self?.onBackgroundUpdate?()
                }
            }
            store.execute(query)
        }
    }

    private func enableBackgroundDelivery() async {
        for identifier in Self.observedIdentifiers {
            guard !Task.isCancelled else { return }
            guard let type = Self.objectType(for: identifier) else { continue }
            await withCheckedContinuation { continuation in
                store.enableBackgroundDelivery(for: type, frequency: .daily) { _, _ in
                    continuation.resume()
                }
            }
            guard !Task.isCancelled else { return }
        }
    }

    private static func objectType(for identifier: String) -> HKSampleType? {
        if let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) {
            return type
        }
        if let type = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier)) {
            return type
        }
        return nil
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        let readTypes = try requiredReadTypes()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: WatchHealthKitError.authorizationDenied)
                }
            }
        }
        try Task.checkCancellation()
    }

    /// Per-day aggregations for the whole read window, keyed YYYY-MM-DD.
    func readDailyMaps(
        now: Date,
        timeZone: TimeZone
    ) async throws -> WatchHealthMaps {
        var calendar = Calendar.gregorianLocal
        calendar.timeZone = timeZone
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let baselineStart = calendar.date(
                  byAdding: .day,
                  value: -WatchHealthReadWindow.queryLookbackDays,
                  to: todayStart
              )
        else {
            throw WatchHealthKitError.dateCalculationFailed
        }

        async let hrv = dailyAverages(
            identifier: .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let rhr = dailyAverages(
            identifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let resp = dailyAverages(
            identifier: .respiratoryRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let sleep = dailySleep(
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let bodyMass = dailyLatestQuantities(
            identifier: .bodyMass,
            unit: .gramUnit(with: .kilo),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )

        return try await WatchHealthMaps(
            hrv: hrv,
            restingHR: rhr,
            respiratoryRate: resp,
            sleep: sleep,
            bodyMass: bodyMass
        )
    }

    private func requiredReadTypes() throws -> Set<HKObjectType> {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .respiratoryRate,
            .bodyMass,
        ]
        var types = Set<HKObjectType>()
        for identifier in identifiers {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
                throw WatchHealthKitError.typeUnavailable(identifier.rawValue)
            }
            types.insert(type)
        }
        guard let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw WatchHealthKitError.typeUnavailable(
                HKCategoryTypeIdentifier.sleepAnalysis.rawValue
            )
        }
        types.insert(sleep)
        return types
    }

    private func dailyAverages(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw WatchHealthKitError.typeUnavailable(identifier.rawValue)
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate]
        )
        var day = DateComponents()
        day.day = 1
        let cancellation = HealthKitQueryCancellation<[String: Double]>(store: store)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String: Double], Error>) in
                guard cancellation.install(continuation) else { return }
                let query = HKStatisticsCollectionQuery(
                    quantityType: type,
                    quantitySamplePredicate: predicate,
                    options: [.discreteAverage],
                    anchorDate: calendar.startOfDay(for: start),
                    intervalComponents: day
                )
                query.initialResultsHandler = { [calendar] _, collection, error in
                    if let error {
                        cancellation.finish(.failure(error))
                        return
                    }
                    guard let collection else {
                        cancellation.finish(.success([:]))
                        return
                    }
                    var values: [String: Double] = [:]
                    collection.enumerateStatistics(from: start, to: end) { statistics, _ in
                        guard let quantity = statistics.averageQuantity() else { return }
                        let key = statistics.startDate.dateString(in: calendar)
                        values[key] = quantity.doubleValue(for: unit)
                    }
                    cancellation.finish(.success(values))
                }
                guard cancellation.install(query), !cancellation.isFinished else {
                    return
                }
                store.execute(query)
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func dailyLatestQuantities(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw WatchHealthKitError.typeUnavailable(identifier.rawValue)
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate]
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let cancellation = HealthKitQueryCancellation<[String: Double]>(store: store)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String: Double], Error>) in
                guard cancellation.install(continuation) else { return }
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [sort]
                ) { [calendar] _, samples, error in
                    if let error {
                        cancellation.finish(.failure(error))
                        return
                    }
                    var values: [String: Double] = [:]
                    for sample in samples as? [HKQuantitySample] ?? [] {
                        let key = sample.endDate.dateString(in: calendar)
                        // Samples are sorted newest-first, so the first value
                        // for a local day is the latest-value semantics.
                        if values[key] == nil {
                            values[key] = sample.quantity.doubleValue(for: unit)
                        }
                    }
                    cancellation.finish(.success(values))
                }
                guard cancellation.install(query), !cancellation.isFinished else {
                    return
                }
                store.execute(query)
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func dailySleep(
        start: Date,
        end: Date,
        calendar: Calendar
    ) async throws -> [String: WatchSleepHours] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw WatchHealthKitError.typeUnavailable(
                HKCategoryTypeIdentifier.sleepAnalysis.rawValue
            )
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictEndDate]
        )
        let cancellation = HealthKitQueryCancellation<[String: WatchSleepHours]>(store: store)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String: WatchSleepHours], Error>) in
                guard cancellation.install(continuation) else { return }
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { [calendar] _, samples, error in
                    if let error {
                        cancellation.finish(.failure(error))
                        return
                    }
                    var byDay: [String: WatchSleepHours] = [:]
                    for sample in samples as? [HKCategorySample] ?? [] {
                        let seconds = max(0, sample.endDate.timeIntervalSince(sample.startDate))
                        guard seconds > 0 else { continue }
                        let key = sample.endDate
                            .addingTimeInterval(-1)
                            .dateString(in: calendar)
                        var day = byDay[key] ?? WatchSleepHours()
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
                    cancellation.finish(.success(byDay))
                }
                guard cancellation.install(query), !cancellation.isFinished else {
                    return
                }
                store.execute(query)
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }
}

/// Per-day HealthKit aggregation maps for one read window.
struct WatchHealthMaps {
    let hrv: [String: Double]
    let restingHR: [String: Double]
    let respiratoryRate: [String: Double]
    let sleep: [String: WatchSleepHours]
    let bodyMass: [String: Double]
}

enum WatchHealthKitError: Error {
    case authorizationDenied
    case typeUnavailable(String)
    case dateCalculationFailed
}
