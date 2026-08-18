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

    func testForbiddenWithValidTokenIsPermanent() {
        // A bare 403 (no constraint code) with a valid token = the server
        // accepted the request but refuses this write. Never heals.
        XCTAssertEqual(classify("42501", 403), .permanent)
        XCTAssertEqual(classify(nil, 403), .permanent)
        XCTAssertEqual(classify("23514", 403), .permanent)
    }

    func testMalformedPayloadStatusesArePermanent() {
        XCTAssertEqual(classify(nil, 404), .permanent)
        XCTAssertEqual(classify("PGRST116", 404), .permanent)
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
