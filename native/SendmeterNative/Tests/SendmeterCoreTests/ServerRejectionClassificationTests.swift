import XCTest
@testable import SendmeterCore

/// #675: the web's retryable-vs-permanent taxonomy (#484) applied to the
/// native PostgREST error surface. These pin the classification rules that
/// drive the offline-queue quarantine, so a future change to what "permanent"
/// means can't silently move entries in or out of quarantine. Pure Core, so
/// `swift test` runs them without the Supabase client.
final class ServerRejectionClassificationTests: XCTestCase {
    private func classify(_ code: String?, _ status: Int) -> RejectionClass {
        ServerRejectionClassifier.classify(code: code, statusCode: status)
    }

    func testConstraintRejectionsArePermanent() {
        // SQLSTATE 23xxx: CHECK / NOT NULL / FK violation — the payload, not
        // the environment.
        for code in ["23514", "23502", "23505", "23503", "23000"] {
            XCTAssertEqual(
                classify(code, 400),
                .permanent,
                "\(code) must classify permanent"
            )
        }
        // A 23505 riding on a 409 is still permanent content — the payload
        // violates a unique constraint.
        XCTAssertEqual(classify("23505", 409), .permanent)
    }

    func testAuthFailuresParkAsAuth() {
        XCTAssertEqual(classify(nil, 401), .auth)
        XCTAssertEqual(classify("PGRST300", 401), .auth)
        XCTAssertEqual(classify("INVALID_JWT", 401), .auth)
        // The #273 rule wins over the content: a constraint code arriving
        // with a 401 is an auth park, not a quarantine — the token being
        // revoked is an environment problem, never proof the payload is bad.
        XCTAssertEqual(classify("23P01", 401), .auth)
    }

    func testPermissionDenialParksNotQuarantines() {
        // #675 F2: an RLS "permission denied" (SQLSTATE 42501 rides on the
        // 403) is an IDENTITY condition, not a payload verdict — the commonest
        // cause is that the request's session is not the account the payload
        // assumes. The web classifies this branch "permission" BEFORE "auth"
        // (monitoring.ts:477-492) and never quarantines it; this port parks
        // it exactly like auth (#273: never destroy user data over an
        // identity problem).
        XCTAssertEqual(classify("42501", 403), .parked)
        XCTAssertEqual(classify(nil, 403), .parked)
        // A constraint code riding a 403 is STILL a permission denial — the
        // 403/permission branch is checked before the 23xxx constraint
        // branch, matching the web's ordering.
        XCTAssertEqual(classify("23514", 403), .parked)
    }

    func testSchemaCacheReload404IsRetryable() {
        // #675 F2: PGRST205 (table not found during a schema-cache reload) is
        // a genuinely transient window, classified "schema" on the web and
        // never quarantined there. A cache-reload window must not quarantine
        // every queued write for the account.
        XCTAssertEqual(classify(nil, 404), .retryable)
        XCTAssertEqual(classify("PGRST205", 404), .retryable)
    }

    func testMalformedPayloadStatusesArePermanent() {
        // #675 F4: 400 is the status PostgREST actually emits for a malformed
        // body (PGRST102), an unknown column (PGRST204 — a native build ahead
        // of its migration), or a bad text representation (22P02). It was
        // missing from the set, so genuinely malformed payloads retried
        // forever — the exact condition #675 was opened to stop.
        XCTAssertEqual(classify(nil, 400), .permanent)
        XCTAssertEqual(classify("PGRST102", 400), .permanent)
        XCTAssertEqual(classify("PGRST204", 400), .permanent)
        XCTAssertEqual(classify("22P02", 400), .permanent)
        // 406/413/415/422 also refuse THIS payload's shape.
        XCTAssertEqual(classify(nil, 406), .permanent)
        XCTAssertEqual(classify(nil, 413), .permanent)
        XCTAssertEqual(classify(nil, 415), .permanent)
        XCTAssertEqual(classify(nil, 422), .permanent)
    }

    func testTransientAndRateLimitAreRetryable() {
        XCTAssertEqual(classify(nil, 500), .retryable)
        XCTAssertEqual(classify(nil, 502), .retryable)
        XCTAssertEqual(classify(nil, 503), .retryable)
        XCTAssertEqual(classify(nil, 429), .retryable)
        XCTAssertEqual(classify(nil, 408), .retryable)
        XCTAssertEqual(classify(nil, 0), .retryable)
    }

    func testUniqueViolationRaceIsRetryable() {
        // The repository already converts 23505/409 into a fetch-and-return,
        // so a surviving bare 409 (no constraint code) is a genuine race worth
        // another attempt.
        XCTAssertEqual(classify(nil, 409), .retryable)
    }
}
