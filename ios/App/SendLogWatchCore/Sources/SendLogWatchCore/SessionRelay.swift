import Foundation

/// The phone → watch auth relay contract (#265, #266).
///
/// The watch is a pure *consumer* of the phone's Supabase session, and after
/// #265 it consumes an **access token only**. It is never handed a refresh
/// token, so there is no rotating credential on the wrist for anything —
/// current code, future code, or a build several TestFlight releases old — to
/// present to `/token`. That is the structural close of #265: #196 achieved
/// the same end by convention (guards saying "never call the refreshing
/// accessor") and the convention silently regressed.
///
/// Everything the watch needs is already inside the JWT: `sub` is the user id
/// the offline queues stamp their items with, and `exp` is when the token
/// stops working. Reading them locally means consuming a relay costs no
/// network call at all (the previous `auth.setSession` spent a `GET /user`
/// per relay, on both native clients — see #265's "duplicated auth requests").
/// The claims are read, never verified: they scope local behaviour only, and
/// the server re-validates the signature on every request regardless.
public enum SessionRelay {
    /// Temporary compatibility value for watches older than #270, whose
    /// decoder rejects a signed-in relay unless a `refreshToken` key exists.
    /// The phone bridge may put this literal into the native WC dictionary;
    /// it is not accepted from JS and is never stored by current watches.
    /// Because it was never issued by Supabase, presenting it to `/token` can
    /// only fail as an invalid credential; it cannot rotate or revoke any
    /// real session family. Remove after the legacy TestFlight window closes.
    public static let legacyRefreshTokenSentinel = "sendmeter-legacy-no-refresh-token"

    /// Don't adopt a token that is about to die mid-request. Also the margin
    /// that decides when the watch asks the phone for a fresh one.
    public static let freshnessMarginS: TimeInterval = 60

    /// Decode a WatchConnectivity payload from the phone.
    ///
    /// Deliberately total: every input maps to an outcome, and a refusal
    /// carries *why*, because "the watch is signed out and won't say why" is
    /// half of #266. Nothing here ever reads `refreshToken` — a legacy payload
    /// from an older phone build still carries one, and it is ignored.
    public static func decode(_ context: [String: Any], now: TimeInterval) -> RelayOutcome {
        guard let event = context["event"] as? String else { return .rejected(.notARelay) }
        switch event {
        case "signedOut":
            return .signedOut
        case "signedIn":
            guard let accessToken = (context["accessToken"] as? String), !accessToken.isEmpty
            else { return .rejected(.missingAccessToken) }
            guard let claims = AccessTokenClaims(jwt: accessToken) else {
                return .rejected(.malformedAccessToken)
            }
            // The token's own `exp` wins over the relayed hint: it is what the
            // server will actually enforce. The hint is only a fallback for a
            // token whose payload somehow omits `exp`.
            let expiresAt = claims.expiresAt ?? (context["expiresAt"] as? Double)
            guard let expiresAt else { return .rejected(.malformedAccessToken) }
            let session = RelayedSession(
                accessToken: accessToken,
                userId: claims.userId,
                expiresAt: expiresAt,
                relayId: context["relayId"] as? String,
                // #614 F6: newer phone builds acknowledge workout beats over
                // WatchConnectivity; older ones do not. The watch must not
                // count a delivered-but-unacked send as a failure, so it only
                // engages the acknowledged/retry contract when the phone
                // proves it can reply. Absent key on an old phone = false.
                ackCapable: (context["ack_capable"] as? Bool) ?? false
            )
            // A payload that has already expired by the time it is read is
            // the normal case for `receivedApplicationContext`, which iOS
            // persists and re-delivers on a cold launch hours later. Rejecting
            // it used to matter enormously (adopting it triggered a refresh
            // and revoked the family); now it is merely useless, but adopting
            // a dead token would still park the watch in a signed-in state
            // whose every request 401s.
            guard isFresh(session, now: now) else { return .rejected(.expired) }
            return .signedIn(session)
        default:
            return .rejected(.unknownEvent)
        }
    }

    /// Whether a token has enough life left to be worth adopting/using.
    public static func isFresh(_ session: RelayedSession, now: TimeInterval) -> Bool {
        session.expiresAt > now + freshnessMarginS
    }

    /// What the watch UI should show, given whatever session is on disk.
    ///
    /// The load-bearing case is the middle one: an expired token keeps the
    /// watch **signed in**, with `tokenFresh: false`. Identity has to survive
    /// the gap, or the offline queues lose the account stamp they compare
    /// against (`shouldDrain`) and a workout recorded in a gym basement stops
    /// being attributable to anyone. Only an explicit `signedOut` relay — the
    /// phone actually signing out — clears identity.
    public static func state(for session: RelayedSession?, now: TimeInterval) -> WatchAuthState {
        guard let session else { return .signedOut }
        return .signedIn(userId: session.userId, tokenFresh: isFresh(session, now: now))
    }

    /// Whether the watch should ask the phone for a fresh relay right now:
    /// signed out entirely, or signed in with an access token that has gone
    /// stale. Deliberately recomputed from `session` + `now` on every call —
    /// **never** from a `WatchAuthState` a caller cached earlier — because a
    /// value this cheap to recompute has no excuse to go stale (#472: three
    /// call sites in `AuthManager` read a cached decision and could therefore
    /// decline to ask for a token the watch actually needed).
    public static func needsToken(for session: RelayedSession?, now: TimeInterval) -> Bool {
        switch state(for: session, now: now) {
        case .signedOut: return true
        case let .signedIn(_, tokenFresh): return !tokenFresh
        }
    }

    /// Throttle for `requestSession` asks. Several triggers converge on the
    /// same moment (bootstrap, reachability change, foreground, the waiting
    /// screen appearing), and each ask costs the phone a WebView round-trip
    /// plus a WatchConnectivity transfer.
    public static let requestIntervalS: TimeInterval = 5

    public static func shouldRequestRelay(
        now: TimeInterval,
        lastRequestAt: TimeInterval?
    ) -> Bool {
        guard let lastRequestAt else { return true }
        return now - lastRequestAt >= requestIntervalS
    }
}

/// A session as the watch holds it: an access token, who it belongs to, and
/// when it dies. There is deliberately no refresh-token field — the type
/// cannot carry one, so no future call site can accidentally start relaying,
/// persisting or presenting one.
public struct RelayedSession: Equatable, Codable, Sendable {
    public let accessToken: String
    public let userId: UUID
    /// Unix seconds.
    public let expiresAt: TimeInterval
    /// Opaque per-relay id stamped by the phone (#266). Only ever compared or
    /// displayed — it exists so two relays of the *same* Supabase session are
    /// distinguishable payloads.
    public let relayId: String?
    /// #614 F6: whether the paired phone acknowledges workout beats over
    /// WatchConnectivity (newer phone builds reply `[:]` to `liveWorkout`;
    /// older ones do not, and the watch must not count a delivered-but-
    /// unacked send as a failure — see `SessionRelay.decode`).
    ///
    /// Decoded with `decodeIfPresent` defaulting to `false` so a session
    /// persisted by a pre-#614 watch build (no key in the JSON) still loads;
    /// a hard `Bool` would throw on that older payload and silently log the
    /// user out at launch.
    public let ackCapable: Bool

    public init(
        accessToken: String,
        userId: UUID,
        expiresAt: TimeInterval,
        relayId: String? = nil,
        ackCapable: Bool = false
    ) {
        self.accessToken = accessToken
        self.userId = userId
        self.expiresAt = expiresAt
        self.relayId = relayId
        self.ackCapable = ackCapable
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, userId, expiresAt, relayId, ackCapable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        userId = try container.decode(UUID.self, forKey: .userId)
        expiresAt = try container.decode(TimeInterval.self, forKey: .expiresAt)
        relayId = try container.decodeIfPresent(String.self, forKey: .relayId)
        ackCapable = try container.decodeIfPresent(Bool.self, forKey: .ackCapable) ?? false
    }
}

/// Why a relay was not adopted. Recorded and surfaced on the watch rather than
/// dropped silently (#266) — "signed out, waiting for iPhone" with no reason
/// is exactly the state that forced users into a phone sign-out/sign-in.
public enum RelayRejection: String, Equatable, Sendable {
    /// Not an auth payload at all (no `event` key).
    case notARelay = "not-a-relay"
    case unknownEvent = "unknown-event"
    case missingAccessToken = "missing-access-token"
    case malformedAccessToken = "malformed-access-token"
    /// Arrived already expired — typically a persisted application context
    /// re-delivered on a cold launch.
    case expired

    /// One short line for the watch screen. Written for the person wearing it.
    public var watchMessage: String {
        switch self {
        case .expired: return "iPhone sent an expired sign-in. Waiting for a fresh one."
        case .missingAccessToken, .malformedAccessToken:
            return "iPhone sent a sign-in this watch couldn't read. Update the Sendmeter app."
        case .notARelay, .unknownEvent:
            return "iPhone sent something this watch didn't understand."
        }
    }
}

public enum RelayOutcome: Equatable, Sendable {
    case signedIn(RelayedSession)
    case signedOut
    case rejected(RelayRejection)
}

public enum WatchAuthState: Equatable, Sendable {
    case signedOut
    /// `tokenFresh == false` means "we know who you are, but the access token
    /// has expired and only the phone can supply another one".
    case signedIn(userId: UUID, tokenFresh: Bool)

    public var userId: UUID? {
        if case let .signedIn(userId, _) = self { return userId }
        return nil
    }
}

/// The two JWT claims the watch reads out of an access token. No signature
/// verification: these scope local behaviour (queue attribution, when to ask
/// for a fresh token), and every request is re-validated server-side anyway.
public struct AccessTokenClaims: Equatable, Sendable {
    public let userId: UUID
    /// Unix seconds, nil if the payload omits `exp`.
    public let expiresAt: TimeInterval?

    public init?(jwt: String) {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = Self.base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sub = json["sub"] as? String,
              let userId = UUID(uuidString: sub)
        else { return nil }
        self.userId = userId
        // `exp` is an integer in Supabase tokens, but JSONSerialization can
        // hand back either NSNumber flavour depending on the value.
        self.expiresAt = (json["exp"] as? NSNumber)?.doubleValue
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url drops the padding that Foundation's decoder requires.
        let remainder = b64.count % 4
        if remainder > 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: b64)
    }
}
