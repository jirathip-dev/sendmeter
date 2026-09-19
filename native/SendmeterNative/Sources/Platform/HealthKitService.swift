import Foundation
import HealthKit
import SendLogHealthCore
import SendmeterCore

/// Owns one HealthKit query and its checked continuation. HealthKit invokes
/// result handlers independently of Swift task cancellation, so cancellation
/// must stop the query and resume the continuation itself. The lock makes the
/// cancellation/result race one-shot: exactly one path takes ownership of the
/// continuation and query, and a late HealthKit callback is ignored.
private final class HealthKitQueryCancellation<Value>: @unchecked Sendable {
    private let store: HKHealthStore
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var query: HKQuery?
    private var finished = false

    init(store: HKHealthStore) {
        self.store = store
    }

    func install(
        _ continuation: CheckedContinuation<Value, Error>
    ) -> Bool {
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

@MainActor
public final class HealthKitService: ObservableObject {
    @Published public private(set) var authorizationStatus: HKAuthorizationStatus = .notDetermined
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastError: String?

    /// Fired on the main actor when a background HealthKit observer query
    /// detects new data for one of the observed types. Wired by
    /// `AppModel` to the same recompute path as foreground sync so a
    /// background wake recomputes readiness, upserts `health_metrics` and
    /// relays the result to the watch (parity with the shipped plugin, #629).
    public var onBackgroundUpdate: (@MainActor () async -> Void)?

    private let store: HKHealthStore
    private var observersRegistered = false
    private var backgroundSetupRegistered = false

    /// The deterministic-read seam the app-target tests use (#919).
    ///
    /// The health WRITE path cannot be driven end-to-end on a simulator: a
    /// real HealthKit read needs samples and an authorization the test host
    /// cannot grant. The seam replaces only the read — the recovery, the
    /// write policy, the durable queue and the cache under test are the
    /// production ones. It is `internal` on purpose: the shipped app can never
    /// steer its own health reads.
    var metricsReader: (@Sendable ([String: Double], TimeZone) async throws -> [HealthMetric])?

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
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
        try Task.checkCancellation()
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            authorizationStatus = store.authorizationStatus(for: hrv)
        }
        await ensureBackgroundObserversRegistered()
    }

    /// Idempotent per-process registration of background delivery + observer
    /// queries for the types in `HealthObserverTypes.observedIdentifiers`.
    /// Observer queries live only for the current process, so a cold launch —
    /// including a HealthKit background wake that relaunches the app — must
    /// re-register; `AppModel` calls this from launch and on foreground.
    public func ensureBackgroundObserversRegistered() async {
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

    /// Reads the whole local HealthKit window and returns only dates with at
    /// least one real source-backed value. HealthKit is the merged Apple Health
    /// store, so samples written by third-party wearables are included by the
    /// same queries; no source/application filter is applied here.
    public func computeMetrics(
        acwrByDate: [String: Double] = [:],
        timeZone: TimeZone = .current
    ) async throws -> [HealthMetric] {
        try Task.checkCancellation()
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        if let metricsReader {
            return try await metricsReader(acwrByDate, timeZone)
        }
        let calendar = LocalDateSupport.calendar(timeZone: timeZone)
        do {
            let metrics = try await readMetrics(
                now: Date(),
                acwrByDate: acwrByDate,
                calendar: calendar,
                timeZone: timeZone
            )
            try Task.checkCancellation()
            return metrics
        } catch {
            if !Task.isCancelled {
                lastError = UserFacingError.message(for: error)
            }
            throw error
        }
    }

    /// Compatibility wrapper for callers that only need today's value. The
    /// reconciliation path uses `computeMetrics` so a no-source day can never
    /// accidentally become an empty persisted row.
    public func computeTodayMetric(acwr: Double?) async throws -> HealthMetric {
        let passTimeZone = TimeZone.current
        let today = LocalDateSupport.string(
            from: Date(),
            timeZone: passTimeZone
        )
        var acwrByDate: [String: Double] = [:]
        if let acwr {
            acwrByDate[today] = acwr
        }
        let metrics = try await computeMetrics(
            acwrByDate: acwrByDate,
            timeZone: passTimeZone
        )
        guard let metric = metrics.first(where: { $0.date == today }) else {
            throw HealthKitError.noSourceData
        }
        return metric
    }

    private func readMetrics(
        now: Date,
        acwrByDate: [String: Double],
        calendar: Calendar,
        timeZone: TimeZone
    ) async throws -> [HealthMetric] {
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let baselineStart = calendar.date(
                  byAdding: .day,
                  value: -HealthMetricReadWindow.queryLookbackDays,
                  to: todayStart
              )
        else {
            throw HealthKitError.dateCalculationFailed
        }

        async let hrvMap = dailyAverages(
            identifier: .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let rhrMap = dailyAverages(
            identifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let respMap = dailyAverages(
            identifier: .respiratoryRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let sleepMap = dailySleep(
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )
        async let bodyMassMap = dailyLatestQuantities(
            identifier: .bodyMass,
            unit: .gramUnit(with: .kilo),
            start: baselineStart,
            end: tomorrow,
            calendar: calendar
        )

        let hrv = try await hrvMap
        let rhr = try await rhrMap
        let resp = try await respMap
        let sleep = try await sleepMap
        let bodyMass = try await bodyMassMap
        let today = LocalDateSupport.string(from: now, timeZone: timeZone)
        let sourceDates = Set(hrv.keys)
            .union(rhr.keys)
            .union(resp.keys)
            .union(sleep.filter { $0.value.totalHours > 0 }.keys)
            .union(bodyMass.keys)

        var metrics: [HealthMetric] = []
        metrics.reserveCapacity(HealthMetricReadWindow.candidateDays)
        for offset in HealthMetricReadWindow.candidateOffsets {
            guard let dateStart = calendar.date(
                byAdding: .day,
                value: -offset,
                to: todayStart
            ) else {
                throw HealthKitError.dateCalculationFailed
            }
            let date = LocalDateSupport.string(
                from: dateStart,
                timeZone: timeZone
            )
            guard sourceDates.contains(date) else { continue }

            let baselineDays = HealthMetricReadWindow.baselineOffsets
                .reversed()
                .map {
                    LocalDateSupport.daysAgo(
                        $0,
                        from: dateStart,
                        timeZone: timeZone
                    )
                }
            let inputs = DailyHealthInputs(
                hrvSDNNms: hrv[date],
                restingHR: rhr[date],
                sleepHours: sleep[date]?.totalHours,
                bodyMassKg: latestBodyMass(onOrBefore: date, valuesByDate: bodyMass),
                sleepDeepHours: sleep[date]?.deepHours,
                sleepRemHours: sleep[date]?.remHours,
                respRateBpm: resp[date],
                hrvLnBaseline: baselineDays
                    .compactMap { hrv[$0] }
                    .filter { $0 > 0 }
                    .map(log),
                rhrBaseline: baselineDays.compactMap { rhr[$0] },
                sleepBaseline: baselineDays.compactMap { sleep[$0]?.totalHours },
                respBaseline: baselineDays.compactMap { resp[$0] },
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
                HealthMetric(
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

    private func latestBodyMass(
        onOrBefore date: String,
        valuesByDate: [String: Double]
    ) -> Double? {
        guard let latestDate = valuesByDate.keys
            .filter({ $0 <= date })
            .max()
        else { return nil }
        return valuesByDate[latestDate]
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

    /// One observer query per delivered type, so HealthKit can wake the app
    /// for each independently (the shipped plugin observes only
    /// HRV; observing the full delivered set means a mid-day sleep-stage or
    /// resting-HR write lands too). A fired query funnels into
    /// `onBackgroundUpdate`, which `AppModel` routes through the same
    /// single-flight recompute path as foreground sync.
    private func registerBackgroundObservers() {
        guard !observersRegistered, isAvailable else { return }
        observersRegistered = true
        for identifier in HealthObserverTypes.observedIdentifiers {
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
        for identifier in HealthObserverTypes.observedIdentifiers {
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

    private func dailyAverages(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date,
        calendar: Calendar
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
                        let key = LocalDateSupport.string(
                            from: statistics.startDate,
                            timeZone: calendar.timeZone
                        )
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
            throw HealthKitError.typeUnavailable(identifier.rawValue)
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
                        let key = LocalDateSupport.string(
                            from: sample.endDate,
                            timeZone: calendar.timeZone
                        )
                        // Samples are sorted newest-first, so the first value for
                        // a local day is the same latest-value semantics as the
                        // old single-row query.
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
    ) async throws -> [String: SleepDay] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitError.typeUnavailable(HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictEndDate]
        )
        let cancellation = HealthKitQueryCancellation<[String: SleepDay]>(store: store)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String: SleepDay], Error>) in
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

private struct SleepDay {
    var totalHours: Double = 0
    var deepHours: Double = 0
    var remHours: Double = 0
}

public enum HealthKitError: Error, LocalizedError, FriendlyErrorClassifying {
    case authorizationDenied
    case typeUnavailable(String)
    case dateCalculationFailed
    case noSourceData

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Health access was not granted."
        case let .typeUnavailable(type):
            return "Apple Health type is unavailable: \(type)"
        case .dateCalculationFailed:
            return "Apple Health date range could not be calculated."
        case .noSourceData:
            return "Apple Health has no source data for this window yet."
        }
    }

    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .authorizationDenied: return .healthPermissionDenied
        case .typeUnavailable, .dateCalculationFailed, .noSourceData: return .healthUnavailable
        }
    }
}
