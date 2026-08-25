import Foundation

/// Identifies the caller of the optional purge-generation read. Only a
/// deliberate foreground refresh may put that endpoint's rollout failure in
/// the user-facing error banner; the other paths retain the conservative
/// full-reconcile fallback silently.
public enum PurgeGenerationRefreshContext: Equatable, Sendable {
    case userInitiatedForeground
    case silent
    case realtime
    case background
}

/// Reports one generation-endpoint outage once for an account/epoch. A
/// successful generation read clears the latch, so a later independent
/// outage can be reported again without making every realtime/background
/// retry noisy.
public struct PurgeGenerationFailurePolicy: Equatable, Sendable {
    private struct ReportedScope: Equatable, Sendable {
        let accountUserID: UUID
        let accountEpoch: UInt64
    }

    private var reportedScope: ReportedScope?

    public init() {}

    /// Returns true only for the first user-initiated foreground failure in
    /// the current account epoch. Silent, realtime, and background failures
    /// deliberately return false and do not consume the report slot.
    public mutating func shouldSurface(
        context: PurgeGenerationRefreshContext,
        accountUserID: UUID,
        accountEpoch: UInt64
    ) -> Bool {
        guard context == .userInitiatedForeground else { return false }
        let scope = ReportedScope(
            accountUserID: accountUserID,
            accountEpoch: accountEpoch
        )
        guard reportedScope != scope else { return false }
        reportedScope = scope
        return true
    }

    /// A successful read ends the outage for this account/epoch. Do not clear
    /// another account's latch when a stale request completes late.
    public mutating func markAvailable(
        accountUserID: UUID,
        accountEpoch: UInt64
    ) {
        let scope = ReportedScope(
            accountUserID: accountUserID,
            accountEpoch: accountEpoch
        )
        if reportedScope == scope {
            reportedScope = nil
        }
    }
}
