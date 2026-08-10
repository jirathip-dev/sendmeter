import Foundation

/// Coarse, keyword-based classification of a raw backend/transport error
/// description into the handful of causes the watch UI is allowed to
/// distinguish. Shared by `ErrorText` (save failures) and
/// `ForceProtocolSyncCopy` (catalog refresh failures, #536) so there is one
/// taxonomy, not a parallel one per surface.
///
/// Falling through to `.unknown` for anything unrecognized — rather than
/// trying to enumerate every possible PostgREST/HTTP failure — is what keeps
/// JWT/PostgREST/HTTP/Supabase wording out of product copy: a caller can
/// only ever render one of three fixed messages, never the raw string.
public enum BackendFailureReason: Sendable, Equatable {
    /// Auth/session/RLS wording — the relayed access token is stale, missing
    /// or rejected (JWT expired, "not authenticated", "permission denied",
    /// row-level security, ...).
    case authExpired
    /// Network/timeout/offline wording — no reachable backend right now.
    case unreachable
    /// Anything else.
    case unknown

    public init(errorDescription: String) {
        let m = errorDescription.lowercased()
        if m.contains("row-level security") || m.contains("jwt")
            || m.contains("not authenticated") || m.contains("unauthorized")
            || m.contains("permission") {
            self = .authExpired
        } else if m.contains("offline") || m.contains("network")
            || m.contains("connection") || m.contains("timed out")
            || m.contains("timeout") {
            self = .unreachable
        } else {
            self = .unknown
        }
    }
}
