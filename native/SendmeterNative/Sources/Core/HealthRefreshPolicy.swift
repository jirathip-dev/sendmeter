import Foundation
import SendLogHealthCore

/// What triggered a health/readiness refresh (#661).
public enum HealthRefreshTrigger: Equatable, Sendable {
    /// The Dashboard appeared — the natural first screen after launch and the
    /// tab the user returns to.
    case appear
    /// The app transitioned to the foreground (scenePhase `.active`).
    case foreground
    /// A background HealthKit observer fire.
    case background
    /// An explicit user gesture (pull-to-refresh on the Dashboard).
    case manual

    /// The #109 `SyncTrigger` an app-driven trigger maps to. Appear,
    /// foreground and background are all automatic (an app-driven HealthKit
    /// re-sync, subject to the post-noon lock); only the user's pull is
    /// manual and thus authoritative.
    public var syncTrigger: SyncTrigger {
        switch self {
        case .manual: return .manual
        case .appear, .foreground, .background: return .automatic
        }
    }
}

/// The silence/coalescing policy for health refreshes (#661).
///
/// A health query is expensive (a 28-day HealthKit read + readiness compute +
/// upsert), so triggers within `coalescingWindow` of the last *started*
/// refresh collapse into one — a launch's appear followed a moment later by
/// the app-active transition must not hammer HealthKit twice.
///
/// Coalescing is by start-time window (the caller stamps when a refresh
/// actually starts), unlike the web's in-flight-promise join (`syncHealthNow`
/// returns the in-flight promise within `FOREGROUND_SYNC_COALESCE_MS`). The
/// caller separately joins an in-flight pass via the `ReadinessRecomputeGate`
/// so a second trigger inside the window still coalesces at most one follow-up
/// pass instead of two concurrent HealthKit reads.
///
/// The window constant mirrors the web's `FOREGROUND_SYNC_COALESCE_MS` (5000).
public struct HealthRefreshPolicy: Equatable, Sendable {
    public let coalescingWindow: TimeInterval

    public init(coalescingWindow: TimeInterval) {
        self.coalescingWindow = coalescingWindow
    }

    /// Whether a refresh should start now. `.manual` (pull-to-refresh) bypasses
    /// the window — it is the only user-initiated HealthKit resync and must
    /// never be absorbed by a recent automatic refresh. All other triggers
    /// coalesce within the window of the last started refresh.
    ///
    /// `lastStartedAt`/`now` are MONOTONIC (seconds on the same clock — the
    /// caller uses `ProcessInfo.processInfo.systemUptime`), not wall-clock:
    /// an NTP step or a user changing the clock must never make the delta
    /// negative and suppress every refresh for the skew.
    public func shouldRefresh(trigger: HealthRefreshTrigger, lastStartedAt: TimeInterval?, now: TimeInterval) -> Bool {
        if trigger == .manual { return true }
        guard let lastStartedAt else { return true }
        return now - lastStartedAt >= coalescingWindow
    }
}
