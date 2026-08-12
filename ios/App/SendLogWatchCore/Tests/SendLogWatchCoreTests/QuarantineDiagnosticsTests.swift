import Foundation
import XCTest
@testable import SendLogWatchCore

/// #599/#600: the quarantined-upload diagnostics surface's pure logic —
/// the record→display projection is engine-side (watch target, header-only
/// probe), but the display model, the copy split per `QuarantineReason`,
/// the truncation, and the retry decision all live in Core so Linux CI
/// covers them.
final class QuarantineDiagnosticsTests: XCTestCase {
    // MARK: QuarantineReason wire compatibility

    /// The raw values are part of the `.quarantine` file's on-disk shape —
    /// records written by every shipping build decode through these exact
    /// strings, and a rename here would silently strand every quarantined
    /// item on real devices as "unreadable".
    func testQuarantineReasonRawValuesAreStable() throws {
        let decoder = JSONDecoder()
        let schema = try decoder.decode(
            QuarantineReason.self,
            from: Data(#""schemaRejection""#.utf8)
        )
        XCTAssertEqual(schema, .schemaRejection)
        let stuck = try decoder.decode(
            QuarantineReason.self,
            from: Data(#""stuckRetrying""#.utf8)
        )
        XCTAssertEqual(stuck, .stuckRetrying)
    }

    func testQuarantineReasonRoundTripsItsOwnCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for reason in QuarantineReason.allCases {
            let data = try encoder.encode(reason)
            XCTAssertEqual(try decoder.decode(QuarantineReason.self, from: data), reason)
        }
    }

    // MARK: Copy split — mirrors uploadWarningPresentation (CLAUDE.md #264 wording rule)

    /// A quarantined item must never read as "waiting to upload" — and the
    /// two reasons must NOT share copy: `.schemaRejection` truly never syncs
    /// on its own, `.stuckRetrying` gets automatic + manual retries.
    func testSchemaRejectionCopySaysItWillNotRetry() {
        let title = QuarantineCopy.title(for: .schemaRejection)
        XCTAssertTrue(title.contains("will not retry"))
        XCTAssertFalse(title.lowercased().contains("waiting to upload"))
        let detail = QuarantineCopy.detail(for: .schemaRejection)
        XCTAssertTrue(detail.contains("permanently rejected"))
        XCTAssertTrue(detail.contains("retrying it won't help"))
    }

    func testStuckRetryingCopySaysItRetriesAutomaticallyAndNow() {
        let title = QuarantineCopy.title(for: .stuckRetrying)
        XCTAssertTrue(title.contains("retrying automatically"))
        XCTAssertFalse(title.lowercased().contains("waiting to upload"))
        let detail = QuarantineCopy.detail(for: .stuckRetrying)
        XCTAssertTrue(detail.contains("automatic retry"))
        XCTAssertTrue(detail.contains("retry it now"))
    }

    func testTheTwoReasonsNeverShareCopy() {
        // The #475 F13 rule pinned structurally: identical copy for the two
        // cases would tell one of them a lie, and a future "simplification"
        // must fail this test rather than ship.
        XCTAssertNotEqual(QuarantineCopy.title(for: .schemaRejection), QuarantineCopy.title(for: .stuckRetrying))
        XCTAssertNotEqual(QuarantineCopy.detail(for: .schemaRejection), QuarantineCopy.detail(for: .stuckRetrying))
    }

    func testPayloadDroppedNoteNeverDescribesARestore() {
        XCTAssertTrue(QuarantineCopy.payloadDroppedNote.contains("summary"))
        XCTAssertFalse(QuarantineCopy.payloadDroppedNote.lowercased().contains("restored"))
        XCTAssertFalse(QuarantineCopy.payloadDroppedNote.lowercased().contains("full"))
    }

    // MARK: Truncation

    func testShortErrorMessageIsUntouched() {
        let message = "new row violates check constraint"
        XCTAssertEqual(QuarantineDiagnostics.truncatedErrorMessage(message), message)
    }

    func testLongErrorMessageIsTruncatedWithAnEllipsisAtTheLimit() {
        let message = String(repeating: "x", count: QuarantineDiagnostics.errorMessageDisplayLimit + 40)
        let truncated = QuarantineDiagnostics.truncatedErrorMessage(message)
        XCTAssertEqual(truncated.count, QuarantineDiagnostics.errorMessageDisplayLimit)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertTrue(truncated.hasPrefix(String(repeating: "x", count: QuarantineDiagnostics.errorMessageDisplayLimit - 1)))
    }

    func testTruncationHonorsAnExplicitLimit() {
        XCTAssertEqual(QuarantineDiagnostics.truncatedErrorMessage("abcdefgh", limit: 5), "abcd…")
    }

    func testEmptyMessageTruncatesToNothing() {
        XCTAssertEqual(QuarantineDiagnostics.truncatedErrorMessage(""), "")
    }

    // MARK: Retry decision (#600)

    /// `.schemaRejection` is proven permanent — a manual retry is known to
    /// fail and must never be offered as an equal option.
    func testSchemaRejectionIsNotManuallyRetryable() {
        XCTAssertFalse(QuarantineRetryPolicy.isManuallyRetryable(.schemaRejection))
    }

    /// `.stuckRetrying` is a bet — the user standing there with working
    /// network is exactly the case the 7-day backoff cannot serve.
    func testStuckRetryingIsManuallyRetryable() {
        XCTAssertTrue(QuarantineRetryPolicy.isManuallyRetryable(.stuckRetrying))
    }

    func testRetryActionTitle() {
        XCTAssertEqual(QuarantineRetryPolicy.retryActionTitle, "Retry stuck uploads")
    }

    // MARK: Result copy

    func testResultSummaryCoversRestoredAndKept() {
        XCTAssertEqual(QuarantineRetryPolicy.resultSummary(restored: 1, kept: 0), "1 upload moved back to the queue")
        XCTAssertEqual(QuarantineRetryPolicy.resultSummary(restored: 2, kept: 1), "2 uploads moved back to the queue · 1 left in quarantine")
    }

    func testResultSummaryIsNilWhenNothingWasAttempted() {
        XCTAssertNil(QuarantineRetryPolicy.resultSummary(restored: 0, kept: 0))
    }
}
