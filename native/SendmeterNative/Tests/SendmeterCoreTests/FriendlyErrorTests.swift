import Foundation
import XCTest
@testable import SendmeterCore

private struct RawSampleError: LocalizedError {
    let raw: String
    var errorDescription: String? { raw }
}

private struct ClassifiedSampleError: Error, FriendlyErrorClassifying {
    let classification: FriendlyErrorClass
    var friendlyErrorClass: FriendlyErrorClass { classification }
}

final class FriendlyErrorTests: XCTestCase {
    func testFixedClassesUseStableActionableCopy() {
        let expectations: [(FriendlyErrorClass, String)] = [
            (.offline, "Couldn\u{2019}t reach Sendmeter. Check your Internet connection and try again."),
            (.timeout, "Sendmeter took too long to respond. Check your connection and try again."),
            (.authExpired, "Your session has expired. Sign in again, then try again."),
            (.authClockSkew, "Your iPhone\u{2019}s date and time may be wrong. Turn on Set Automatically in Settings \u{2192} General \u{2192} Date & Time, then try again."),
            (.authRejected, "That email and password combination wasn\u{2019}t recognised. Try again, or use a magic link."),
            (.authEmailNotConfirmed, "Check your email to confirm your account, then try again."),
            (.accountAlreadyExists, "An account already exists for that email. Try signing in instead."),
            (.weakPassword, "That password isn\u{2019}t strong enough. Try a longer password with a mix of letters and numbers."),
            (.rateLimited, "Too many attempts. Wait a moment, then try again."),
            (.authFailed, "Sign-in couldn\u{2019}t complete. Check your details and try again."),
            (.passkeyAlreadyExists, "That passkey is already registered. Try signing in with it."),
            (.passkeyLimitReached, "You\u{2019}ve reached the passkey limit. Remove one in Settings, then try again."),
            (.accessDenied, "Sendmeter couldn\u{2019}t save this for your account. Sign in again, then try again."),
            (.serverRejected, "Sendmeter couldn\u{2019}t save this. Retry it, or discard it if you don\u{2019}t need it."),
            (.saveFailed, "Couldn\u{2019}t save this. Try again."),
            (.missingAttempt, "Record at least one attempt before finishing the workout."),
            (.previousRecordingUnfinished, "Save or discard the previous pull before starting another."),
            (.progressorNotConnected, "Connect the Progressor before starting."),
            (.progressorUnavailable, "Bluetooth is unavailable. Turn it on and try connecting again."),
            (.progressorConnectFailed, "Couldn\u{2019}t connect to the Progressor. Make sure it\u{2019}s on and nearby, then try again."),
            (.progressorDisconnected, "The Progressor disconnected. Reconnect it and try again."),
            (.progressorUnsupported, "This device can\u{2019}t connect to a Progressor over Bluetooth."),
            (.progressorUnrecognized, "The Progressor wasn\u{2019}t recognised. Turn it off and on, then try connecting again."),
            (.healthPermissionDenied, "Sendmeter can\u{2019}t read Apple Health. Allow Health access in Settings, then try again."),
            (.healthUnavailable, "Apple Health isn\u{2019}t available on this device."),
            (.storageFull, "This iPhone doesn\u{2019}t have enough free storage. Free up space and try again."),
            (.unknown, "Something went wrong while completing that. Try again.")
        ]
        for (classification, expected) in expectations {
            XCTAssertEqual(UserFacingError.message(for: classification), expected)
        }
    }

    func testTypedClassificationWins() {
        XCTAssertEqual(
            UserFacingError.message(for: ClassifiedSampleError(classification: .offline)),
            UserFacingError.message(for: .offline)
        )
        XCTAssertEqual(
            UserFacingError.message(for: ClassifiedSampleError(classification: .serverRejected)),
            UserFacingError.message(for: .serverRejected)
        )
    }

    func testURLErrorsClassifyWithoutLeakingDescriptions() {
        XCTAssertEqual(
            UserFacingError.message(for: URLError(.notConnectedToInternet)),
            UserFacingError.message(for: .offline)
        )
        XCTAssertEqual(
            UserFacingError.message(for: URLError(.timedOut)),
            UserFacingError.message(for: .timeout)
        )
    }

    func testBackendWordingStillUsesFixedCopy() {
        XCTAssertEqual(
            UserFacingError.message(for: RawSampleError(raw: "JWT expired")),
            UserFacingError.message(for: .authExpired)
        )
        XCTAssertEqual(
            UserFacingError.message(for: RawSampleError(raw: "Could not connect to the server.")),
            UserFacingError.message(for: .offline)
        )
    }

    func testAuthErrorCodesUseSpecificFixedCopy() {
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "invalid_credentials"),
            UserFacingError.message(for: .authRejected)
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "email_not_confirmed"),
            UserFacingError.message(for: .authEmailNotConfirmed)
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "email_exists"),
            UserFacingError.message(for: .accountAlreadyExists)
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "weak_password"),
            UserFacingError.message(for: .weakPassword)
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "over_request_rate_limit"),
            UserFacingError.message(for: .rateLimited)
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "session_expired"),
            UserFacingError.message(for: .authExpired)
        )
        for code in ["invalid_claim", "bad_jwt", "invalid_jwt", "refresh_token_already_used"] {
            XCTAssertEqual(
                UserFacingError.message(forAuthErrorCode: code),
                UserFacingError.message(for: .authExpired),
                code
            )
        }
        XCTAssertEqual(
            UserFacingError.friendlyErrorClass(
                forAuthErrorCode: "invalid_claim",
                message: "JWT issued at future"
            ),
            .authExpired
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "webauthn_credential_exists"),
            UserFacingError.message(for: .passkeyAlreadyExists)
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "too_many_passkeys"),
            UserFacingError.message(for: .passkeyLimitReached)
        )
        XCTAssertEqual(
            UserFacingError.message(forAuthErrorCode: "unexpected_failure"),
            UserFacingError.message(for: .authFailed)
        )
    }

    func testUnknownErrorNeverLeaksRawDescriptionOrTechnicalIdentifiers() {
        let raws = [
            "Status Code: 500 Body: {\"message\":\"internal error\"}",
            "PGRST116",
            "SQLSTATE 23505 duplicate key",
            "The request timed out.",
            "JWT expired",
            "This is an implementation detail."
        ]
        for raw in raws {
            let message = UserFacingError.message(for: RawSampleError(raw: raw))
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains(raw),
                "user copy must not contain the raw description: \(message)"
            )
            XCTAssertFalse(message.localizedCaseInsensitiveContains("SQLSTATE"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("PGRST"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("Status Code"))
        }
    }

    func testDiagnosticDetailUsesFixedCopy() {
        XCTAssertEqual(
            UserFacingError.message(forDiagnosticDetail: "Auth invalid_credentials: Invalid login credentials"),
            UserFacingError.message(for: .authRejected)
        )
        XCTAssertEqual(
            UserFacingError.message(forDiagnosticDetail: "Auth email_exists: User already registered"),
            UserFacingError.message(for: .accountAlreadyExists)
        )
        XCTAssertEqual(
            UserFacingError.message(forDiagnosticDetail: "Session refresh failed: JWT expired"),
            UserFacingError.message(for: .authExpired)
        )
        XCTAssertEqual(
            UserFacingError.message(forDiagnosticDetail: "PostgREST status=401: Unauthorized"),
            UserFacingError.message(for: .authExpired)
        )
        XCTAssertEqual(
            UserFacingError.message(forDiagnosticDetail: "The request timed out."),
            UserFacingError.message(for: .timeout)
        )
        XCTAssertEqual(
            UserFacingError.message(
                forDiagnosticDetail: "Status Code: 500 Body: {\"message\":\"internal error\"}"
            ),
            UserFacingError.message(for: .unknown)
        )
    }

    func testQuarantineRejectionUsesKindCopy() {
        XCTAssertEqual(
            UserFacingError.message(
                for: QueueRejection(kind: .permanent, code: "23505", detail: "duplicate key")
            ),
            UserFacingError.message(for: .serverRejected)
        )
        XCTAssertEqual(
            UserFacingError.message(
                for: QueueRejection(kind: .auth, code: "PGRST301", detail: "JWT expired")
            ),
            UserFacingError.message(for: .authExpired)
        )
        XCTAssertEqual(
            UserFacingError.message(
                for: QueueRejection(kind: .parked, code: "42501", detail: "permission denied")
            ),
            UserFacingError.message(for: .accessDenied)
        )
        XCTAssertEqual(
            UserFacingError.message(
                for: QueueRejection(kind: .retryable, code: nil, detail: "offline")
            ),
            UserFacingError.message(for: .offline)
        )
    }

    func testStorageFullClassifies() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteOutOfSpace.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]
        )
        XCTAssertEqual(
            UserFacingError.message(for: error),
            UserFacingError.message(for: .storageFull)
        )
    }

    func testQueueBreadcrumbReasonsUsePlainCopy() {
        XCTAssertEqual(
            UserFacingError.message(forQueueBreadcrumbReason: "uploaded"),
            "Uploaded"
        )
        XCTAssertEqual(
            UserFacingError.message(forQueueBreadcrumbReason: "recording-deleted"),
            "Recording deleted"
        )
        XCTAssertEqual(
            UserFacingError.message(forQueueBreadcrumbReason: "replaced-by-delete"),
            "Pending upload deleted"
        )
        XCTAssertEqual(
            UserFacingError.message(forQueueBreadcrumbReason: "quarantine-discarded"),
            "Rejected upload discarded"
        )
        let raw = "recording-delete-ordering-proof-not-durable"
        let message = UserFacingError.message(forQueueBreadcrumbReason: raw)
        XCTAssertFalse(message.localizedCaseInsensitiveContains(raw))
    }

    func testQueueRejectionLabelsDoNotExposeInternalRawValues() {
        let expectations: [(RejectionClass, String)] = [
            (.retryable, "temporary issue"),
            (.auth, "sign-in required"),
            (.parked, "permission issue"),
            (.permanent, "server rejection")
        ]
        for (kind, expected) in expectations {
            XCTAssertEqual(UserFacingError.label(for: kind), expected)
            XCTAssertFalse(UserFacingError.label(for: kind).contains(kind.rawValue))
        }
    }
}
