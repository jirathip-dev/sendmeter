import Foundation

/// Coarse, keyword-based classification of a raw backend/transport error
/// description into the handful of causes the watch UI is allowed to
/// distinguish. Shared by `ErrorText` and `ForceProtocolSyncCopy` (catalog
/// refresh failures, #536) so there is one taxonomy, not a parallel one per
/// surface — `ErrorText` currently has no wired call site of its own, but
/// this classifier is the one place either would ever add one.
///
/// Falling through to `.unknown` for anything unrecognized — rather than
/// trying to enumerate every possible PostgREST/HTTP failure — is what keeps
/// JWT/PostgREST/HTTP/Supabase wording out of product copy: a caller can
/// only ever render one of a fixed set of product strings, never the raw
/// string.
///
/// The keyword lists are verified (#536 review round 1) against the actual
/// shapes this app's supabase-swift dependency and URLSession produce:
/// `PostgrestError.localizedDescription` is just its `message` field, so a
/// raw `"JWT expired"` or `"Invalid API key"` arrives verbatim; `HTTPError`
/// (thrown when a body isn't decodable as `PostgrestError`) renders as
/// `"Status Code: 401 Body: <raw>"`; `URLError.cannotConnectToHost` /
/// `.cannotFindHost` render as "Could not connect to the server." / "A
/// server with the specified hostname could not be found."
public enum BackendFailureReason: Sendable, Equatable {
    /// Auth/session/RLS wording — the relayed access token is stale, missing
    /// or rejected (JWT/JWS expired or invalid, "not authenticated",
    /// "permission denied", row-level security, an HTTP 401 or 403, ...).
    case authExpired
    /// Network/timeout/offline/host-unreachable wording — no reachable
    /// backend right now.
    case unreachable
    /// Anything else.
    case unknown

    public init(errorDescription: String) {
        let m = errorDescription.lowercased()
        if Self.matchesAuthFailure(m) {
            self = .authExpired
        } else if Self.matchesUnreachable(m) {
            self = .unreachable
        } else {
            self = .unknown
        }
    }

    /// A `nil` error means every attempt was cancelled or otherwise produced
    /// no result without ever surfacing a thrown error — practically "the
    /// phone never answered", so this classifies directly as `.unreachable`
    /// rather than laundering an empty string through the keyword matcher as
    /// `.unknown` (#536 review finding 8).
    public init(error: Error?) {
        guard let error else {
            self = .unreachable
            return
        }
        self.init(errorDescription: error.localizedDescription)
    }

    private static func matchesAuthFailure(_ m: String) -> Bool {
        if m.contains("row-level security") || m.contains("jwt") || m.contains("jws")
            || m.contains("not authenticated") || m.contains("unauthorized")
            || m.contains("authentication") || m.contains("permission")
            || m.contains("api key") {
            return true
        }
        // 403 is included alongside 401: the realistic 403 body already
        // matches "permission" above, but a bare status-only 403 (no body
        // wording) is still the same "the relayed credential was rejected"
        // shape, not a genuinely unrecognized failure (#536 review round 2
        // finding C).
        guard let code = statusCode(in: m) else { return false }
        return code == 401 || code == 403
    }

    private static func matchesUnreachable(_ m: String) -> Bool {
        m.contains("offline") || m.contains("network") || m.contains("connect")
            || m.contains("hostname") || m.contains("timed out") || m.contains("timeout")
    }

    /// Parses `HTTPError`'s `"Status Code: 401 Body: ..."` shape (already
    /// lowercased by the caller to `"status code: 401 body: ..."`) without a
    /// regex dependency.
    private static func statusCode(in m: String) -> Int? {
        guard let range = m.range(of: "status code: ") else { return nil }
        let digits = m[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
