import XCTest
@testable import SendLogWatchCore

/// Regression coverage for #536: an expired-token catalog-refresh failure
/// must render as product copy — never `JWT`, PostgREST codes, HTTP codes,
/// Supabase wording, or any other raw exception text — and the banner must
/// never say the same thing twice (title carries the sync-outcome claim,
/// message carries only the recovery action).
final class ForceProtocolSyncCopyTests: XCTestCase {
    private static let allowedMessages: Set<String> = [
        "Open Sendmeter on iPhone to refresh.",
        "Connect to iPhone to refresh.",
        "Couldn\u{2019}t refresh right now."
    ]
    private static let allowedTitles: Set<String> = [
        "Showing saved protocols",
        "No saved protocols yet",
        "Couldn\u{2019}t sync protocols"
    ]
    private static let allRowsStates: [ForceProtocolSyncCopy.RowsState] = [
        .cachedWithRows, .cachedEmpty, .neverSynced
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
        "Status Code: 403 Body: {\"message\":\"nope\"}",
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

            for rows in Self.allRowsStates {
                let presentation = ForceProtocolSyncCopy.presentation(for: reason, rows: rows)
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

    /// A bare 403 (no "permission" wording in the body) still reads as an
    /// auth failure (#536 review round 2 finding C).
    func testBareStatusCode403ClassifiesAsAuthExpired() {
        let reason = BackendFailureReason(errorDescription: "Status Code: 403 Body: {\"message\":\"nope\"}")
        XCTAssertEqual(reason, .authExpired)
    }

    /// #536 review finding 1: the title must reflect actual saved rows, not
    /// merely that a cache write has happened — an empty catalog is a
    /// legitimately persisted cache.
    func testCachedRowsStatesReflectActualCountNotJustACacheWrite() {
        XCTAssertEqual(ForceProtocolSyncCopy.title(for: .cachedWithRows), "Showing saved protocols")
        XCTAssertEqual(ForceProtocolSyncCopy.title(for: .cachedEmpty), "No saved protocols yet")
    }

    /// #536 review round 2 finding A: a request that never had a prior
    /// successful fetch to fall back on must not claim a count either way —
    /// "we couldn't find out" stays distinguishable from "you have none".
    func testNeverSyncedTitleDoesNotClaimACount() {
        let title = ForceProtocolSyncCopy.title(for: .neverSynced)
        XCTAssertEqual(title, "Couldn\u{2019}t sync protocols")
        XCTAssertFalse(title.lowercased().contains("saved"))
        XCTAssertNotEqual(title, ForceProtocolSyncCopy.title(for: .cachedEmpty))
    }

    /// #536 review finding 2: title and message must never repeat the same
    /// claim — every combination of reason x rows must produce a distinct,
    /// non-overlapping title/message pair.
    func testTitleAndMessageNeverRepeatEachOther() {
        for reason in [BackendFailureReason.authExpired, .unreachable, .unknown] {
            for rows in Self.allRowsStates {
                let presentation = ForceProtocolSyncCopy.presentation(for: reason, rows: rows)
                XCTAssertNotEqual(presentation.title, presentation.message)
                XCTAssertFalse(presentation.message.lowercased().contains("saved"))
                XCTAssertFalse(presentation.message.lowercased().contains("cached"))
                XCTAssertFalse(presentation.message.lowercased().contains("sync"))
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
