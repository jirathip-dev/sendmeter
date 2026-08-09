import Foundation

// MARK: - Issue #472b — "have we synced in a while", surfaced on the watch itself

/// What the watch's OWN UI should say about how current its last successful
/// upload is. A different signal from `WatchQuarantineStatus`/`WatchSyncStatus`
/// in `WatchBuildReport.swift` — those describe what the PHONE was last told
/// about the watch's queues; this describes what the watch currently knows
/// about itself, computed fresh against the clock rather than read off a
/// stale relay.
///
/// Same honest-states rule as the rest of this file: a queue that has never
/// once synced successfully must not read the same as one that is current —
/// `lastSuccessfulSyncAt == nil` is carried through to `.stale` rather than
/// folded into "no elapsed time to show", so the UI can say "no successful
/// sync yet" instead of inventing a duration.
public enum SyncFreshness: Equatable, Sendable {
    /// Nothing pending right now (staleness isn't a meaningful question), or
    /// the last successful sync is recent enough that no signal is worth
    /// surfacing.
    case current
    /// Items are waiting to upload AND either nothing has ever synced
    /// successfully (`nil`) or the last successful sync is older than
    /// `SyncFreshnessPolicy.staleAfterS`.
    case stale(lastSuccessfulSyncAt: Date?)
}

public enum SyncFreshnessPolicy {
    /// How long a successful sync stays "current" before an unresolved
    /// pending queue starts reading as stale rather than merely normal —
    /// long enough that an ordinary gap between drains (a short elevator
    /// dead zone, a few minutes out of range) doesn't flap the banner.
    public static let staleAfterS: TimeInterval = 15 * 60

    public static func evaluate(
        lastSuccessfulSyncAt: Date?,
        hasPending: Bool,
        now: Date
    ) -> SyncFreshness {
        guard hasPending else { return .current }
        guard let lastSuccessfulSyncAt else { return .stale(lastSuccessfulSyncAt: nil) }
        return now.timeIntervalSince(lastSuccessfulSyncAt) >= staleAfterS
            ? .stale(lastSuccessfulSyncAt: lastSuccessfulSyncAt)
            : .current
    }
}
