import Foundation

/// What triggered a health/readiness refresh (#661).
public enum HealthRefreshTrigger: Equatable, Sendable {
    /// The Dashboard appeared — the natural first screen after launch and the
    /// tab the user returns to.
    case appear
    /// The app transitioned to the foreground (scenePhase `.active`).
    case foreground
    /// An explicit user gesture (pull-to-refresh).
    case manual
}

/// The silence/coalescing policy for health refreshes (#661).
///
/// Mirror of the web's `syncHealthNow` (#612 round 2): a health query is
/// expensive (a 28-day HealthKit read + readiness compute + upsert), so
/// triggers within `coalescingWindow` of the last completed refresh collapse
/// into one — a launch's appear followed a moment later by the app-active
/// transition must not hammer HealthKit twice. The window is measured from
/// when the refresh STARTED on the reference clock the caller supplies
/// (monotonic `Date().timeIntervalSinceReferenceDate` on the native side),
/// so the policy stays pure and unit-testable.
public struct HealthRefreshPolicy: Equatable, Sendable {
    public let coalescingWindow: TimeInterval

    public init(coalescingWindow: TimeInterval) {
        self.coalescingWindow = coalescingWindow
    }

    /// Whether a refresh should start now. Only a `.manual` trigger bypasses
    /// the coalescing window (pull-to-refresh is always authoritative and is
    /// also the `.refreshable` path — it must never be absorbed).
    public func shouldRefresh(trigger: HealthRefreshTrigger, lastStartedAt: Date?, now: Date) -> Bool {
        if trigger == .manual { return true }
        guard let lastStartedAt else { return true }
        return now.timeIntervalSince(lastStartedAt) >= coalescingWindow
    }
}
