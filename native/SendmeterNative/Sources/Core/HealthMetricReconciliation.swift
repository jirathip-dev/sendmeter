import Foundation

/// The result of comparing a HealthKit read window with the rows already
/// persisted for the account. The plan contains only writes that can change
/// the server, while `relayMetric` is the honest current-day value to display
/// and send to the watch.
public struct HealthMetricReconciliationPlan: Equatable, Sendable {
    public let upserts: [HealthMetric]
    public let relayMetric: HealthMetric?
    public let sourceDataDates: [String]
    public let reconciledDates: [String]

    public init(
        upserts: [HealthMetric],
        relayMetric: HealthMetric?,
        sourceDataDates: [String],
        reconciledDates: [String]
    ) {
        self.upserts = upserts
        self.relayMetric = relayMetric
        self.sourceDataDates = sourceDataDates
        self.reconciledDates = reconciledDates
    }

    public var reconciledCount: Int { reconciledDates.count }
}

/// The shared HealthKit read geometry. There are exactly 28 candidate days:
/// today and the preceding 27 days. Each candidate can use the 28 days before
/// it as a baseline, so the deepest required source date is today-55. Keeping
/// these boundaries in Core lets the production HealthKit builder and the
/// reconciliation tests use the same inclusive-window contract.
public enum HealthMetricReadWindow {
    public static let candidateDays = 28
    public static let baselineDays = 28
    public static let queryLookbackDays = candidateDays + baselineDays - 1

    public static var candidateOffsets: Range<Int> {
        0..<candidateDays
    }

    public static var baselineOffsets: ClosedRange<Int> {
        1...baselineDays
    }
}

/// Pure date-window reconciliation for the native HealthKit path (#801).
///
/// HealthKit can return a real biometric on a day for which the server has no
/// row. Historical rows are insert-if-missing: an existing historical row is
/// deliberately not rewritten by a later read. Today is the one exception and
/// continues through `ReadinessSyncPolicy`, so the existing automatic
/// afternoon freeze and manual overwrite rules remain authoritative. The
/// candidate window is today plus the preceding 27 days; the deeper baseline
/// needed to compute those candidates is owned by `HealthMetricReadWindow`.
public enum HealthMetricReconciliationPolicy {
    public static func plan(
        freshMetrics: [HealthMetric],
        existingMetrics: [HealthMetric],
        today: String,
        allowTodayReadinessOverwrite: Bool,
        timeZone: TimeZone = .current
    ) -> HealthMetricReconciliationPlan {
        let freshByDate = freshMetrics
            .filter { metric in
                hasSourceData(metric)
                    && isInWindow(
                        date: metric.date,
                        today: today,
                        timeZone: timeZone
                    )
            }
            .reduce(into: [String: HealthMetric]()) { result, metric in
                guard let current = result[metric.date] else {
                    result[metric.date] = metric
                    return
                }
                let currentComputedAt = current.computedAt ?? .distantPast
                let metricComputedAt = metric.computedAt ?? .distantPast
                if metricComputedAt > currentComputedAt {
                    result[metric.date] = metric
                }
            }
        let sourceDataDates = freshByDate.keys.sorted(by: >)
        let existingByDate = existingMetrics.reduce(
            into: [String: HealthMetric]()
        ) { result, metric in
            if result[metric.date] == nil {
                result[metric.date] = metric
            }
        }

        var upserts: [HealthMetric] = []
        var reconciledDates: [String] = []
        var relayMetric: HealthMetric?

        for date in sourceDataDates {
            guard let fresh = freshByDate[date] else { continue }
            if date == today {
                let todayPlan = ReadinessSyncPolicy.plan(
                    existingToday: existingByDate[date],
                    freshlyComputed: fresh,
                    allowReadinessOverwrite: allowTodayReadinessOverwrite
                )
                relayMetric = todayPlan.relayMetric
                if shouldUpsert(
                    existing: existingByDate[date],
                    candidate: todayPlan.upsertMetric
                ) {
                    upserts.append(todayPlan.upsertMetric)
                    reconciledDates.append(date)
                }
            } else if existingByDate[date] == nil {
                upserts.append(fresh)
                reconciledDates.append(date)
            }
        }

        return HealthMetricReconciliationPlan(
            upserts: upserts,
            relayMetric: relayMetric,
            sourceDataDates: sourceDataDates,
            reconciledDates: reconciledDates
        )
    }

    /// A metric is a source-backed candidate only when at least one raw Apple
    /// Health field is present. Readiness, zone, and computed time alone never
    /// make an empty day eligible for persistence.
    public static func hasSourceData(_ metric: HealthMetric) -> Bool {
        metric.hrvSDNNMilliseconds != nil
            || metric.restingHeartRate != nil
            || metric.sleepHours != nil
            || metric.sleepDeepHours != nil
            || metric.sleepREMHours != nil
            || metric.bodyMassKilograms != nil
            || metric.respiratoryRate != nil
    }

    private static func isInWindow(
        date: String,
        today: String,
        timeZone: TimeZone
    ) -> Bool {
        guard let distance = LocalDateSupport.dayDistance(
            from: date,
            to: today,
            timeZone: timeZone
        ) else { return false }
        return distance >= 0 && distance < HealthMetricReadWindow.candidateDays
    }

    private static func shouldUpsert(
        existing: HealthMetric?,
        candidate: HealthMetric
    ) -> Bool {
        guard let existing else { return true }
        guard biometricFieldsEqual(existing, candidate) else { return true }

        // A nil readiness/zone/computedAt means the caller is intentionally
        // preserving today's existing score. Those omitted fields are not a
        // change and must not turn every automatic refresh into an upsert.
        guard candidate.readiness != nil
                || candidate.zone != nil
                || candidate.computedAt != nil
        else { return false }

        return existing.readiness != candidate.readiness
            || existing.zone != candidate.zone
    }

    private static func biometricFieldsEqual(
        _ lhs: HealthMetric,
        _ rhs: HealthMetric
    ) -> Bool {
        lhs.hrvSDNNMilliseconds == rhs.hrvSDNNMilliseconds
            && lhs.restingHeartRate == rhs.restingHeartRate
            && lhs.sleepHours == rhs.sleepHours
            && lhs.sleepDeepHours == rhs.sleepDeepHours
            && lhs.sleepREMHours == rhs.sleepREMHours
            && lhs.bodyMassKilograms == rhs.bodyMassKilograms
            && lhs.respiratoryRate == rhs.respiratoryRate
    }
}

/// The server request semantics for the two health write classes. Historical
/// rows are immutable after they exist, so their request must use atomic
/// conflict-ignore semantics. Today's row remains the one merge-upsert path
/// because its biometrics and readiness can legitimately change.
public enum HealthMetricWriteOperation: Equatable, Sendable {
    case historicalInsert
    case todayMerge

    public var preferHeader: String {
        switch self {
        case .historicalInsert:
            return "resolution=ignore-duplicates,return=representation"
        case .todayMerge:
            return "resolution=merge-duplicates,return=minimal"
        }
    }
}

public enum HealthMetricWritePolicy {
    public static func operation(
        for date: String,
        today: String
    ) -> HealthMetricWriteOperation {
        date == today ? .todayMerge : .historicalInsert
    }
}

/// A completed health read's user-facing meaning. Automatic callers only
/// announce `.reconciled`; an empty read, a no-op reconciliation, and a
/// failure remain observable through state but never claim that data changed.
public enum HealthSyncObservation: Equatable, Sendable {
    case reconciled(Int)
    case noNewData
    case noSourceData
    case failed
    case cancelled

    public static func successful(
        reconciledCount: Int,
        sourceDataCount: Int
    ) -> HealthSyncObservation {
        if reconciledCount > 0 {
            return .reconciled(reconciledCount)
        }
        return sourceDataCount > 0 ? .noNewData : .noSourceData
    }

    public var reconciledCount: Int {
        guard case let .reconciled(count) = self else { return 0 }
        return count
    }

    public var hasSourceData: Bool {
        switch self {
        case .reconciled, .noNewData: return true
        case .noSourceData, .failed, .cancelled: return false
        }
    }

    /// Automatic refreshes use this only for a real reconciliation. In
    /// particular, no-source and no-op reads intentionally return nil.
    public var automaticConfirmationMessage: String? {
        guard case let .reconciled(count) = self, count > 0 else { return nil }
        let suffix = count == 1 ? "day" : "days"
        return "Apple Health updated · \(count) \(suffix)"
    }

    public var manualMessage: String? {
        switch self {
        case let .reconciled(count):
            let suffix = count == 1 ? "day" : "days"
            return "Apple Health synced · \(count) \(suffix)"
        case .noNewData:
            return "Apple Health checked — no new data"
        case .noSourceData:
            return "No Apple Health data found"
        case .failed, .cancelled:
            return nil
        }
    }
}

/// Best-supported morning refresh schedule. iOS does not promise a precise
/// wall-clock wake for HealthKit delivery or BGAppRefresh, so the app starts
/// this bounded window on the first morning lifecycle/observer signal. Each
/// later pass becomes eligible at a deterministic relative delay, but is run
/// only by a subsequent supported lifecycle, observer, or BGAppRefresh event;
/// no detached timer is part of the contract.
public struct HealthMorningRefreshPolicy: Equatable, Sendable {
    public let morningStartHour: Int
    public let morningEndHour: Int
    public let repollDelays: [TimeInterval]

    public init(
        morningStartHour: Int = 5,
        morningEndHour: Int = 13,
        repollDelays: [TimeInterval] = [0, 5 * 60, 15 * 60]
    ) {
        self.morningStartHour = morningStartHour
        self.morningEndHour = morningEndHour
        self.repollDelays = repollDelays
    }

    public var passCount: Int { repollDelays.count }

    public func delay(forPass pass: Int) -> TimeInterval? {
        guard repollDelays.indices.contains(pass) else { return nil }
        return repollDelays[pass]
    }

    public func interval(
        fromPass previousPass: Int,
        toPass nextPass: Int
    ) -> TimeInterval? {
        guard let previous = delay(forPass: previousPass),
              let next = delay(forPass: nextPass)
        else { return nil }
        return max(0, next - previous)
    }

    public func duePass(
        for progress: HealthMorningRefreshProgress,
        at now: Date
    ) -> Int? {
        guard let delay = delay(forPass: progress.nextPass),
              now >= progress.startedAt.addingTimeInterval(delay)
        else { return nil }
        return progress.nextPass
    }

    public func isCurrentLocalDay(
        _ progress: HealthMorningRefreshProgress,
        at now: Date,
        calendar: Calendar
    ) -> Bool {
        let passCalendar = LocalDateSupport.calendar(timeZone: calendar.timeZone)
        return LocalDateSupport.string(
            from: progress.startedAt,
            timeZone: passCalendar.timeZone
        ) == LocalDateSupport.string(
            from: now,
            timeZone: passCalendar.timeZone
        )
    }

    /// Convenience for callers that intentionally resume a persisted window
    /// without an external pass context. AppModel uses the overload above so
    /// its current pass snapshot also governs the progress day boundary.
    public func isCurrentLocalDay(
        _ progress: HealthMorningRefreshProgress,
        at now: Date
    ) -> Bool {
        isCurrentLocalDay(
            progress,
            at: now,
            calendar: LocalDateSupport.calendar(timeZone: progress.timeZone)
        )
    }

    public func isMorning(at now: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= morningStartHour && hour < morningEndHour
    }

    public func shouldStart(
        at now: Date,
        lastStartedAt: Date?,
        calendar: Calendar
    ) -> Bool {
        guard isMorning(at: now, calendar: calendar) else { return false }
        guard let lastStartedAt else { return true }
        let today = LocalDateSupport.string(from: now, timeZone: calendar.timeZone)
        let previousDay = LocalDateSupport.string(
            from: lastStartedAt,
            timeZone: calendar.timeZone
        )
        return today != previousDay
    }
}

/// Persisted state for the account-scoped morning refresh window. `nextPass`
/// is written before the first await, so termination during a HealthKit read
/// leaves an explicit pass to retry on a later supported event. The aggregate
/// is persisted with it so only the final pass owns the completion toast.
public struct HealthMorningRefreshProgress: Codable, Equatable, Sendable {
    public let accountUserID: UUID
    public let startedAt: Date
    /// The Gregorian time-zone snapshot used when this refresh window was
    /// started. It is the deterministic fallback for consumers that resume a
    /// window without an active pass context; AppModel passes its current
    /// per-pass snapshot explicitly.
    public let timeZoneIdentifier: String
    public var nextPass: Int
    public var reconciledCount: Int
    public var sourceDataPasses: Int
    public var successfulPasses: Int
    public var hadFailure: Bool

    public init(
        accountUserID: UUID,
        startedAt: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        nextPass: Int = 0,
        reconciledCount: Int = 0,
        sourceDataPasses: Int = 0,
        successfulPasses: Int = 0,
        hadFailure: Bool = false
    ) {
        self.accountUserID = accountUserID
        self.startedAt = startedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.nextPass = nextPass
        self.reconciledCount = reconciledCount
        self.sourceDataPasses = sourceDataPasses
        self.successfulPasses = successfulPasses
        self.hadFailure = hadFailure
    }

    private enum CodingKeys: String, CodingKey {
        case accountUserID
        case startedAt
        case timeZoneIdentifier
        case nextPass
        case reconciledCount
        case sourceDataPasses
        case successfulPasses
        case hadFailure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountUserID = try container.decode(UUID.self, forKey: .accountUserID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        // Progress written before the time-zone snapshot was introduced is
        // still safe to resume; interpret it in the zone current at decode
        // time rather than discarding an otherwise valid account marker.
        timeZoneIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .timeZoneIdentifier
        ) ?? TimeZone.current.identifier
        nextPass = try container.decode(Int.self, forKey: .nextPass)
        reconciledCount = try container.decode(Int.self, forKey: .reconciledCount)
        sourceDataPasses = try container.decode(Int.self, forKey: .sourceDataPasses)
        successfulPasses = try container.decode(Int.self, forKey: .successfulPasses)
        hadFailure = try container.decode(Bool.self, forKey: .hadFailure)
    }

    public mutating func add(_ observation: HealthSyncObservation) {
        successfulPasses += 1
        reconciledCount += observation.reconciledCount
        if observation.hasSourceData {
            sourceDataPasses += 1
        }
    }

    public mutating func markFailure() {
        hadFailure = true
    }

    public var finalObservation: HealthSyncObservation? {
        // A later reconciliation is stronger evidence than an earlier
        // transient pass failure. Do not suppress the confirmation for a day
        // that was inserted successfully on a subsequent supported event.
        if reconciledCount > 0 {
            return .reconciled(reconciledCount)
        }
        if hadFailure { return .failed }
        guard successfulPasses > 0 else { return nil }
        return .successful(
            reconciledCount: reconciledCount,
            sourceDataCount: sourceDataPasses
        )
    }

    /// A malformed/legacy identifier falls back to the current time zone at
    /// the point the progress is read. Date grouping itself remains pinned to
    /// the Gregorian calendar by `LocalDateSupport`.
    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }
}

/// Synchronous claim used before the first await of a morning refresh. The
/// same app lifecycle can emit appear, foreground, and observer callbacks
/// together; only one of them owns the bounded repoll window.
public struct HealthRepollGate: Equatable, Sendable {
    private var claimed = false

    public init() {}

    public var isClaimed: Bool { claimed }

    public mutating func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    public mutating func release() {
        claimed = false
    }
}
