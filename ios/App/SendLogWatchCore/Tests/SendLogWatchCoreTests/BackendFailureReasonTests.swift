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
            "permission denied for table tindeq_presets"
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
            "connection lost"
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
            "Something went wrong"
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
}
