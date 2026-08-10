import XCTest
@testable import SendLogWatchCore

final class BackendFailureReasonTests: XCTestCase {
    func testJWTAndAuthWordingClassifyAsAuthExpired() {
        for description in [
            "JWT expired",
            "The JWT has expired",
            "Row-level security policy violation",
            "User not authenticated",
            "unauthorized",
            "permission denied for table tindeq_presets",
            // Real shapes verified against supabase-swift 2.51.0 (#536 review finding 3).
            "JWSError JWSInvalidSignature",
            "Invalid authentication credentials",
            "Invalid API key",
            "Status Code: 401 Body: {\"message\":\"Invalid API key\"}",
            // #536 review round 2 finding C: a bare 403 (no "permission"
            // wording) is still an auth failure, not unrecognized.
            "Status Code: 403 Body: {\"message\":\"nope\"}"
        ] {
            XCTAssertEqual(
                BackendFailureReason(errorDescription: description),
                .authExpired,
                "expected \(description) to classify as authExpired"
            )
        }
    }

    func testNetworkWordingClassifiesAsUnreachable() {
        for description in [
            "The Internet connection appears to be offline.",
            "A network error occurred.",
            "The request timed out.",
            "connection lost",
            // Real URLError shapes (#536 review finding 3).
            "Could not connect to the server.",
            "A server with the specified hostname could not be found."
        ] {
            XCTAssertEqual(
                BackendFailureReason(errorDescription: description),
                .unreachable,
                "expected \(description) to classify as unreachable"
            )
        }
    }

    func testUnrecognizedWordingClassifiesAsUnknown() {
        for description in [
            "",
            "PGRST116",
            "duplicate key value violates unique constraint",
            "Something went wrong",
            "Status Code: 500 Body: {\"message\":\"internal error\"}"
        ] {
            XCTAssertEqual(
                BackendFailureReason(errorDescription: description),
                .unknown,
                "expected \(description) to classify as unknown"
            )
        }
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(BackendFailureReason(errorDescription: "JWT EXPIRED"), .authExpired)
        XCTAssertEqual(BackendFailureReason(errorDescription: "NETWORK ERROR"), .unreachable)
    }

    /// #536 review finding 8: a `nil` error (every attempt cancelled/produced
    /// no result without ever throwing) means "the phone never answered",
    /// which is `.unreachable`, not an unrecognized empty string.
    func testNilErrorClassifiesAsUnreachable() {
        XCTAssertEqual(BackendFailureReason(error: nil), .unreachable)
    }

    func testErrorInitializerDelegatesToLocalizedDescription() {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "JWT expired" }
        }
        XCTAssertEqual(BackendFailureReason(error: SampleError()), .authExpired)
    }

    /// #536 review finding 5: `TimeoutError`'s classification must not depend
    /// on Swift's synthesized `localizedDescription` embedding the type's own
    /// name — it needs an explicit, stable description.
    func testTimeoutErrorClassifiesAsUnreachableViaItsOwnDescription() {
        XCTAssertEqual(TimeoutError().errorDescription, "The request timed out.")
        XCTAssertEqual(
            BackendFailureReason(errorDescription: TimeoutError().localizedDescription),
            .unreachable
        )
    }
}
