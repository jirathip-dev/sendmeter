import Foundation

/// Watch-facing copy for a `ForceProtocolCatalog` refresh failure (#536).
///
/// The picker must never render `error.localizedDescription` — real
/// observed text included `JWT expired`, which is an implementation detail,
/// not something a climber can act on. This turns a `BackendFailureReason`
/// plus "do we already have something cached to fall back to" into the exact
/// banner message; the caller is responsible for keeping the original
/// technical error in `Logger` only.
public enum ForceProtocolSyncCopy {
    /// `hasCachedSnapshot` picks between "here's what to do, and your saved
    /// protocols still work" and "here's what to do, nothing saved yet" for
    /// the same underlying cause — the recovery action doesn't change, but
    /// whether the picker still has usable rows does.
    public static func message(
        for reason: BackendFailureReason,
        hasCachedSnapshot: Bool
    ) -> String {
        switch reason {
        case .authExpired:
            return hasCachedSnapshot
                ? "Open Sendmeter on iPhone to refresh · showing saved protocols"
                : "Open Sendmeter on iPhone to refresh."
        case .unreachable:
            return hasCachedSnapshot
                ? "Connect to iPhone to refresh · showing saved protocols"
                : "Connect to iPhone to refresh."
        case .unknown:
            return hasCachedSnapshot
                ? "Couldn’t sync · showing saved protocols"
                : "Couldn’t sync protocols."
        }
    }
}
