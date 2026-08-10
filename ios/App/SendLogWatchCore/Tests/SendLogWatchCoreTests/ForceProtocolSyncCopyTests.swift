import XCTest
@testable import SendLogWatchCore

/// Regression coverage for #536: an expired-token catalog-refresh failure
/// must render as product copy — never `JWT`, PostgREST codes, HTTP codes,
/// Supabase wording, or any other raw exception text.
final class ForceProtocolSyncCopyTests: XCTestCase {
    private static let rawTechnicalTerms = [
        "jwt", "postgrest", "pgrst", "http", "supabase", "row-level security",
        "401", "403", "sqlstate"
    ]

    func testExpiredTokenWithCachedSnapshotShowsOpenIPhoneCopyOnly() {
        let reason = BackendFailureReason(errorDescription: "JWT expired")
        XCTAssertEqual(reason, .authExpired)

        let message = ForceProtocolSyncCopy.message(for: reason, hasCachedSnapshot: true)

        XCTAssertEqual(message, "Open Sendmeter on iPhone to refresh · showing saved protocols")
        assertNoRawTechnicalWording(message)
    }

    func testExpiredTokenWithoutCachedSnapshotShowsOpenIPhoneCopyOnly() {
        let reason = BackendFailureReason(errorDescription: "JWT expired")
        let message = ForceProtocolSyncCopy.message(for: reason, hasCachedSnapshot: false)

        XCTAssertEqual(message, "Open Sendmeter on iPhone to refresh.")
        assertNoRawTechnicalWording(message)
    }

    func testUnreachablePhoneShowsConnectCopy() {
        let reason = BackendFailureReason(errorDescription: "The request timed out.")
        XCTAssertEqual(reason, .unreachable)

        XCTAssertEqual(
            ForceProtocolSyncCopy.message(for: reason, hasCachedSnapshot: true),
            "Connect to iPhone to refresh · showing saved protocols"
        )
        XCTAssertEqual(
            ForceProtocolSyncCopy.message(for: reason, hasCachedSnapshot: false),
            "Connect to iPhone to refresh."
        )
    }

    func testUnrecognizedFailureFallsBackToGenericCopy() {
        let reason = BackendFailureReason(errorDescription: "duplicate key value violates unique constraint")
        XCTAssertEqual(reason, .unknown)

        XCTAssertEqual(
            ForceProtocolSyncCopy.message(for: reason, hasCachedSnapshot: true),
            "Couldn\u{2019}t sync · showing saved protocols"
        )
        XCTAssertEqual(
            ForceProtocolSyncCopy.message(for: reason, hasCachedSnapshot: false),
            "Couldn\u{2019}t sync protocols."
        )
    }

    func testNoRawTechnicalWordingSurvivesForAnyReasonOrCacheState() {
        for reason in [BackendFailureReason.authExpired, .unreachable, .unknown] {
            for hasCachedSnapshot in [true, false] {
                let message = ForceProtocolSyncCopy.message(for: reason, hasCachedSnapshot: hasCachedSnapshot)
                assertNoRawTechnicalWording(message)
            }
        }
    }

    private func assertNoRawTechnicalWording(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = message.lowercased()
        for term in Self.rawTechnicalTerms {
            XCTAssertFalse(
                lowered.contains(term),
                "product copy leaked raw technical wording \"\(term)\": \(message)",
                file: file,
                line: line
            )
        }
    }
}
