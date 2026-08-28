import Foundation
import SendLogHealthCore

// MARK: - Issue #802 AC3 — deterministic morning refresh window (watch mirror of #801)

/// Best-supported morning refresh schedule for the watch, mirroring the
/// phone's `HealthMorningRefreshPolicy` (#801): the app starts a bounded
/// window on the first morning signal and each later pass becomes eligible
/// at a deterministic relative delay, run only by a subsequent supported
/// lifecycle/observer event — no detached timer is part of the contract.
public struct WatchHealthMorningRefreshPolicy: Equatable, Sendable {
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

    public func duePass(
        for progress: WatchHealthMorningProgress,
        at now: Date
    ) -> Int? {
        guard let delay = delay(forPass: progress.nextPass),
              now >= progress.startedAt.addingTimeInterval(delay)
        else { return nil }
        return progress.nextPass
    }

    public func isCurrentLocalDay(
        _ progress: WatchHealthMorningProgress,
        at now: Date,
        calendar: Calendar
    ) -> Bool {
        return now.dateString(in: calendar)
            == progress.startedAt.dateString(in: calendar)
    }

    public func isMorning(at now: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= morningStartHour && hour < morningEndHour
    }

    /// A morning window may start only once per local day, in the morning
    /// window, and never when the previous window was started today.
    public func shouldStart(
        at now: Date,
        lastStartedAt: Date?,
        calendar: Calendar
    ) -> Bool {
        guard isMorning(at: now, calendar: calendar) else { return false }
        guard let lastStartedAt else { return true }
        return now.dateString(in: calendar)
            != lastStartedAt.dateString(in: calendar)
    }
}

/// Persisted window state for one account, mirroring
/// `HealthMorningRefreshProgress` (the watch never had a pre-ledger legacy
/// record, so `legacyReconciledCount` is intentionally absent). `nextPass`
/// is advanced only after the pass's result was recorded, so a terminated
/// pass is retried by the next supported event.
public struct WatchHealthMorningProgress: Codable, Equatable, Sendable {
    public let accountUserID: UUID
    public let startedAt: Date
    public let timeZoneIdentifier: String
    public var nextPass: Int
    public var reconciledDateKeys: Set<String>
    public var reconciledCount: Int
    public var sourceDataPasses: Int
    public var successfulPasses: Int
    public var hadFailure: Bool

    public init(
        accountUserID: UUID,
        startedAt: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        nextPass: Int = 0,
        reconciledDateKeys: Set<String> = Set<String>(),
        reconciledCount: Int = 0,
        sourceDataPasses: Int = 0,
        successfulPasses: Int = 0,
        hadFailure: Bool = false
    ) {
        self.accountUserID = accountUserID
        self.startedAt = startedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.nextPass = nextPass
        self.reconciledDateKeys = reconciledDateKeys
        self.reconciledCount = reconciledCount
        self.sourceDataPasses = sourceDataPasses
        self.successfulPasses = successfulPasses
        self.hadFailure = hadFailure
    }

    public mutating func add(
        observation: WatchHealthSyncObservation,
        acknowledgedReconciledDates: Set<String> = Set<String>()
    ) {
        successfulPasses += 1
        if !acknowledgedReconciledDates.isEmpty {
            reconciledDateKeys.formUnion(acknowledgedReconciledDates)
            reconciledCount = reconciledDateKeys.count
        }
        if observation.hasSourceData {
            sourceDataPasses += 1
        }
    }

    public mutating func markFailure() {
        hadFailure = true
    }
}

/// The per-pass observation for the watch's health sync (mirror of the
/// phone's #801 `HealthSyncObservation`), defining what a pass means
/// user-visibly and for the morning aggregate.
public enum WatchHealthSyncObservation: Equatable, Sendable {
    case reconciled(Int)
    case noNewData
    case noSourceData
    case failed
    case cancelled

    public static func successful(
        reconciledCount: Int,
        sourceDataCount: Int
    ) -> WatchHealthSyncObservation {
        if reconciledCount > 0 { return .reconciled(reconciledCount) }
        return sourceDataCount > 0 ? .noNewData : .noSourceData
    }

    public var hasSourceData: Bool {
        switch self {
        case .reconciled, .noNewData: return true
        case .noSourceData, .failed, .cancelled: return false
        }
    }
}
