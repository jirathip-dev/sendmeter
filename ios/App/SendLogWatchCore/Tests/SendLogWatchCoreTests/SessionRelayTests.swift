import XCTest
import SendLogWatchCore

private let userA = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let userB = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A structurally-real (unsigned — nothing here verifies signatures) Supabase
/// access token: header.payload.signature with `sub` and `exp` claims.
private func jwt(sub: UUID = userA, exp: TimeInterval? = 2_000, extra: [String: Any] = [:]) -> String {
    var payload: [String: Any] = ["sub": sub.uuidString, "iss": "supabase", "role": "authenticated"]
    if let exp { payload["exp"] = exp }
    payload.merge(extra) { _, new in new }
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"])
    let body = try! JSONSerialization.data(withJSONObject: payload)
    return "\(base64URL(header)).\(base64URL(body)).c2lnbmF0dXJl"
}

private func signedIn(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var ctx: [String: Any] = [
        "event": "signedIn",
        "accessToken": jwt(),
        "expiresAt": 2_000.0,
        "relayId": "relay-1"
    ]
    ctx.merge(overrides) { _, new in new }
    return ctx
}

final class AccessTokenClaimsTests: XCTestCase {
    func testReadsSubAndExp() {
        let claims = AccessTokenClaims(jwt: jwt(sub: userB, exp: 1_700_000_000))
        XCTAssertEqual(claims?.userId, userB)
        XCTAssertEqual(claims?.expiresAt, 1_700_000_000)
    }

    func testDecodesPayloadsWhoseBase64NeedsPadding() {
        // base64url strips '=' padding; a payload whose length isn't a
        // multiple of 3 bytes is the common case, so this is not an edge case
        // — getting it wrong would reject most real tokens.
        for filler in ["a", "ab", "abc", "abcd"] {
            let token = jwt(extra: ["pad": filler])
            XCTAssertEqual(AccessTokenClaims(jwt: token)?.userId, userA, "padding case: \(filler)")
        }
    }

    func testNilForNonJWTOrNonUUIDSubject() {
        XCTAssertNil(AccessTokenClaims(jwt: "not-a-jwt"))
        XCTAssertNil(AccessTokenClaims(jwt: "only.two"))
        let header = base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "none"]))
        let body = base64URL(try! JSONSerialization.data(withJSONObject: ["sub": "service_role"]))
        XCTAssertNil(AccessTokenClaims(jwt: "\(header).\(body).sig"))
    }

    func testExpMayBeAbsent() {
        XCTAssertNil(AccessTokenClaims(jwt: jwt(exp: nil))?.expiresAt)
        XCTAssertEqual(AccessTokenClaims(jwt: jwt(exp: nil))?.userId, userA)
    }
}

final class SessionRelayDecodeTests: XCTestCase {
    func testAdoptsAFreshSignedInPayload() {
        guard case let .signedIn(session) = SessionRelay.decode(signedIn(), now: 1_000) else {
            return XCTFail("expected signedIn")
        }
        XCTAssertEqual(session.userId, userA)
        XCTAssertEqual(session.expiresAt, 2_000)
        XCTAssertEqual(session.relayId, "relay-1")
    }

    // ------------------------------------------------------------------
    // #265's invariant. These are the tests that must fail if anyone ever
    // reintroduces a refresh token on the wire or on the wrist.
    // ------------------------------------------------------------------

    func testARefreshTokenInThePayloadIsIgnoredEntirely() {
        // A phone build older than #265 still relays `refreshToken`. Decoding
        // must produce EXACTLY the same result as the payload without it —
        // i.e. the field is not read, not stored, and not consulted.
        let withToken = SessionRelay.decode(
            signedIn(["refreshToken": "rt-226-two-rotations-stale"]), now: 1_000
        )
        let without = SessionRelay.decode(signedIn(), now: 1_000)
        XCTAssertEqual(withToken, without)
    }

    func testCompatibilityFixtureWorksForCurrentAndLegacyDecoders() {
        let fixture = signedIn([
            "refreshToken": SessionRelay.legacyRefreshTokenSentinel
        ])
        guard case .signedIn = SessionRelay.decode(fixture, now: 1_000) else {
            return XCTFail("current watch must decode the compatibility payload")
        }
        // This exactly models the pre-#270 guard: the old watch only required
        // a non-empty String before passing the payload to supabase-swift.
        let legacyGuardAccepted = (fixture["accessToken"] as? String)?.isEmpty == false
            && (fixture["refreshToken"] as? String)?.isEmpty == false
        XCTAssertTrue(legacyGuardAccepted)
        XCTAssertFalse(SessionRelay.legacyRefreshTokenSentinel.hasPrefix("eyJ"))
    }

    func testTheStoredSessionCannotCarryARefreshTokenAtAll() {
        // Structural, not conventional: `RelayedSession` has no field for one,
        // so an encoded session cannot smuggle one to disk. If someone adds a
        // field back, this fails.
        guard case let .signedIn(session) = SessionRelay.decode(
            signedIn(["refreshToken": "rt-should-vanish"]), now: 1_000
        ) else { return XCTFail("expected signedIn") }
        let encoded = try! JSONEncoder().encode(session)
        let keys = Set(
            (try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]).keys
        )
        XCTAssertEqual(keys, ["accessToken", "userId", "expiresAt", "relayId"])
        XCTAssertFalse(
            String(data: encoded, encoding: .utf8)!.contains("rt-should-vanish")
        )
    }

    func testAPayloadCarryingOnlyARefreshTokenIsRefused() {
        // The watch has nothing it could do with one. It must refuse and say
        // so, never fall back to "well, I'll try signing in with this".
        var ctx = signedIn()
        ctx.removeValue(forKey: "accessToken")
        ctx["refreshToken"] = "rt-only"
        XCTAssertEqual(
            SessionRelay.decode(ctx, now: 1_000), .rejected(.missingAccessToken)
        )
    }

    // ------------------------------------------------------------------
    // Freshness + refusals
    // ------------------------------------------------------------------

    func testRefusesAnExpiredPayloadWithAReason() {
        // The persisted `receivedApplicationContext` re-delivered on a cold
        // launch hours later is the case this exists for.
        XCTAssertEqual(
            SessionRelay.decode(signedIn(), now: 1_999), .rejected(.expired)
        )
    }

    func testRefusesAPayloadInsideTheFreshnessMargin() {
        XCTAssertEqual(
            SessionRelay.decode(signedIn(), now: 2_000 - SessionRelay.freshnessMarginS),
            .rejected(.expired)
        )
        guard case .signedIn = SessionRelay.decode(
            signedIn(), now: 2_000 - SessionRelay.freshnessMarginS - 1
        ) else { return XCTFail("a token outside the margin is usable") }
    }

    func testTheTokensOwnExpiryWinsOverTheRelayedHint() {
        // The hint is the phone's `session.expires_at`; the claim is what the
        // server enforces. A payload claiming a long life for a dead token
        // must not be adopted.
        let ctx = signedIn(["accessToken": jwt(exp: 1_500), "expiresAt": 9_999.0])
        XCTAssertEqual(SessionRelay.decode(ctx, now: 1_600), .rejected(.expired))
    }

    func testFallsBackToTheRelayedExpiryOnlyWhenTheTokenOmitsExp() {
        let ctx = signedIn(["accessToken": jwt(exp: nil), "expiresAt": 2_000.0])
        guard case let .signedIn(session) = SessionRelay.decode(ctx, now: 1_000) else {
            return XCTFail("expected signedIn")
        }
        XCTAssertEqual(session.expiresAt, 2_000)

        var noHint = ctx
        noHint.removeValue(forKey: "expiresAt")
        XCTAssertEqual(SessionRelay.decode(noHint, now: 1_000), .rejected(.malformedAccessToken))
    }

    func testRefusesGarbageWithADistinctReason() {
        XCTAssertEqual(SessionRelay.decode([:], now: 1_000), .rejected(.notARelay))
        XCTAssertEqual(
            SessionRelay.decode(["event": "somethingElse"], now: 1_000),
            .rejected(.unknownEvent)
        )
        XCTAssertEqual(
            SessionRelay.decode(signedIn(["accessToken": "garbage"]), now: 1_000),
            .rejected(.malformedAccessToken)
        )
        XCTAssertEqual(
            SessionRelay.decode(signedIn(["accessToken": ""]), now: 1_000),
            .rejected(.missingAccessToken)
        )
    }

    func testSignedOutIsAlwaysHonoured() {
        // No freshness check: the phone signing out is authoritative whenever
        // it arrives.
        XCTAssertEqual(SessionRelay.decode(["event": "signedOut"], now: 9_999), .signedOut)
    }

    func testEveryRejectionHasSomethingToShowTheUser() {
        for rejection in [
            RelayRejection.notARelay, .unknownEvent, .missingAccessToken,
            .malformedAccessToken, .expired
        ] {
            XCTAssertFalse(rejection.watchMessage.isEmpty, "\(rejection)")
        }
    }
}

final class WatchAuthStateTests: XCTestCase {
    private func session(expiresAt: TimeInterval) -> RelayedSession {
        RelayedSession(accessToken: jwt(), userId: userA, expiresAt: expiresAt)
    }

    func testNoSessionIsSignedOut() {
        XCTAssertEqual(SessionRelay.state(for: nil, now: 1_000), .signedOut)
    }

    func testAnExpiredTokenKEEPSTheWatchSignedIn() {
        // THE offline-window invariant (#265's tradeoff). An access-token-only
        // watch out of range of its phone for over an hour must not forget who
        // it is: `OfflineQueue`/`PendingSessionQueue` stamp each item with the
        // signed-in user and refuse to drain when that is nil, so dropping to
        // signedOut here would strand every gym-basement workout.
        XCTAssertEqual(
            SessionRelay.state(for: session(expiresAt: 1_000), now: 50_000),
            .signedIn(userId: userA, tokenFresh: false)
        )
    }

    func testAFreshTokenIsSignedInAndUsable() {
        XCTAssertEqual(
            SessionRelay.state(for: session(expiresAt: 50_000), now: 1_000),
            .signedIn(userId: userA, tokenFresh: true)
        )
    }

    func testUserIdSurvivesTokenExpiry() {
        XCTAssertEqual(
            SessionRelay.state(for: session(expiresAt: 1_000), now: 50_000).userId, userA
        )
        XCTAssertNil(SessionRelay.state(for: nil, now: 1_000).userId)
    }
}

final class RelayRequestThrottleTests: XCTestCase {
    func testFirstAskAlwaysGoesOut() {
        XCTAssertTrue(SessionRelay.shouldRequestRelay(now: 1_000, lastRequestAt: nil))
    }

    func testCoincidingTriggersCollapseIntoOneAsk() {
        // bootstrap + reachability + foreground + the waiting screen appearing
        // all fire within a moment of each other on a cold launch.
        XCTAssertFalse(SessionRelay.shouldRequestRelay(now: 1_001, lastRequestAt: 1_000))
    }

    func testARetryLaterIsAllowed() {
        XCTAssertTrue(
            SessionRelay.shouldRequestRelay(
                now: 1_000 + SessionRelay.requestIntervalS, lastRequestAt: 1_000
            )
        )
    }
}
