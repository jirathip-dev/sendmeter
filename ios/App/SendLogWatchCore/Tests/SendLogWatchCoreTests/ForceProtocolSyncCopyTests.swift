import XCTest
@testable import SendLogWatchCore

/// Regression coverage for #536: an expired-token catalog-refresh failure
/// must render as product copy — never `JWT`, PostgREST codes, HTTP codes,
/// Supabase wording, or any other raw exception text — and the banner must
/// never say the same thing twice (title carries the cache claim, message
/// carries only the recovery action).
final class ForceProtocolSyncCopyTests: XCTestCase {
    private static let allowedMessages: Set<String> = [
        "Open Sendmeter on iPhone to refresh.",
        "Connect to iPhone to refresh.",
        "Couldn\u{2019}t refresh right now."
    ]
    private static let allowedTitles: Set<String> = [
        "Showing saved protocols",
        "No saved protocols yet"
    ]

    /// #536 review finding 7: broader than "JWT" alone, and shared with
    /// `ForceProtocolCatalogTests` so the two suites can't silently diverge.
    static let rawTechnicalTerms = [
        "jwt", "jws", "postgrest", "pgrst", "http", "supabase", "row-level security",
        "401", "403", "status code", "expired", "token", "unauthorized", "denied",
        "authentication", "api key", "sqlstate"
    ]

    /// Real raw strings this exact call path can produce (verified against
    /// supabase-swift 2.51.0 and URLError, #536 review finding 3), plus edge
    /// inputs (`""`, an unrecognized DB error).
    private static let realisticRawErrors = [
        "JWT expired",
        "Status Code: 401 Body: {\"message\":\"Invalid API key\"}",
        "JWSError JWSInvalidSignature",
        "Invalid authentication credentials",
        "Could not connect to the server.",
        "A server with the specified hostname could not be found.",
        "The request timed out.",
        "duplicate key value violates unique constraint",
        ""
    ]

    func testEveryRealisticRawErrorProducesOnlyAllowedProductCopy() {
        for raw in Self.realisticRawErrors {
            let reason = BackendFailureReason(errorDescription: raw)
            let message = ForceProtocolSyncCopy.message(for: reason)
            XCTAssertTrue(
                Self.allowedMessages.contains(message),
                "unexpected message for raw input \"\(raw)\": \"\(message)\""
            )
            assertNoRawTechnicalWording(message, source: raw)

            for hasUsableRows in [true, false] {
                let presentation = ForceProtocolSyncCopy.presentation(for: reason, hasUsableRows: hasUsableRows)
                XCTAssertTrue(
                    Self.allowedTitles.contains(presentation.title),
                    "unexpected title for raw input \"\(raw)\": \"\(presentation.title)\""
                )
                XCTAssertEqual(presentation.message, message)
                assertNoRawTechnicalWording(presentation.title, source: raw)
                assertNoRawTechnicalWording(presentation.message, source: raw)
            }
        }
    }

    func testExpiredTokenShowsOpenIPhoneMessage() {
        let reason = BackendFailureReason(errorDescription: "JWT expired")
        XCTAssertEqual(reason, .authExpired)
        XCTAssertEqual(ForceProtocolSyncCopy.message(for: reason), "Open Sendmeter on iPhone to refresh.")
    }

    func testUnreachablePhoneShowsConnectMessage() {
        let reason = BackendFailureReason(errorDescription: "The request timed out.")
        XCTAssertEqual(reason, .unreachable)
        XCTAssertEqual(ForceProtocolSyncCopy.message(for: reason), "Connect to iPhone to refresh.")
    }

    func testUnrecognizedFailureFallsBackToGenericMessage() {
        let reason = BackendFailureReason(errorDescription: "duplicate key value violates unique constraint")
        XCTAssertEqual(reason, .unknown)
        XCTAssertEqual(ForceProtocolSyncCopy.message(for: reason), "Couldn\u{2019}t refresh right now.")
    }

    /// #536 review finding 1: the title must reflect actual saved rows, not
    /// merely that a cache write has happened — an empty catalog is a
    /// legitimately persisted cache.
    func testPresentationTitleReflectsUsableRowsNotJustACacheWrite() {
        let reason = BackendFailureReason(errorDescription: "JWT expired")

        XCTAssertEqual(
            ForceProtocolSyncCopy.presentation(for: reason, hasUsableRows: true).title,
            "Showing saved protocols"
        )
        XCTAssertEqual(
            ForceProtocolSyncCopy.presentation(for: reason, hasUsableRows: false).title,
            "No saved protocols yet"
        )
    }

    /// #536 review finding 2: title and message must never repeat the same
    /// claim — every combination of reason x hasUsableRows must produce a
    /// distinct title/message pair.
    func testTitleAndMessageNeverRepeatEachOther() {
        for reason in [BackendFailureReason.authExpired, .unreachable, .unknown] {
            for hasUsableRows in [true, false] {
                let presentation = ForceProtocolSyncCopy.presentation(for: reason, hasUsableRows: hasUsableRows)
                XCTAssertNotEqual(presentation.title, presentation.message)
                XCTAssertFalse(presentation.message.lowercased().contains("saved"))
                XCTAssertFalse(presentation.message.lowercased().contains("cached"))
            }
        }
    }

    func assertNoRawTechnicalWording(
        _ text: String,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lowered = text.lowercased()
        for term in Self.rawTechnicalTerms {
            XCTAssertFalse(
                lowered.contains(term),
                "product copy for raw input \"\(source)\" leaked raw technical wording \"\(term)\": \(text)",
                file: file,
                line: line
            )
        }
    }
}
