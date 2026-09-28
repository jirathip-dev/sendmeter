import Foundation
import GRDB
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
            (.cacheUnavailable, "Sendmeter couldn\u{2019}t read its saved data on this iPhone. Reopen the app, then try again."),
            // #1004: the remedy is a retry, not "update the app" — the
            // owner of the device this banner fired on was already on the
            // newest build, and the stored row that would not decode is set
            // aside and rebuilt from the server.
            (.dataUnreadable, "Sendmeter couldn\u{2019}t read some of its data. Try again \u{2014} unreadable data on this iPhone is set aside and rebuilt from your account."),
            (.secureStorageUnavailable, "Sendmeter couldn\u{2019}t reach its saved sign-in on this iPhone. Reopen the app, then try again."),
            (.loadFailed, "Sendmeter couldn\u{2019}t load your data. Try again."),
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

    // MARK: - #964: the launch-path failure families stop collapsing to `.unknown`

    /// A `DecodingError` is what an unexpected payload produces — a stored row
    /// or a received response the build cannot read. It must read as that
    /// family, never as the unexplained fallback.
    func testDecodingFailureClassifiesAsUnreadableData() {
        let error = DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "The data couldn\u{2019}t be read because it isn\u{2019}t in the correct format."
            )
        )
        XCTAssertEqual(UserFacingError.classification(for: error), .dataUnreadable)
        XCTAssertEqual(
            UserFacingError.message(for: error),
            UserFacingError.message(for: .dataUnreadable)
        )
        XCTAssertNotEqual(
            UserFacingError.message(for: error),
            UserFacingError.message(for: .unknown),
            "a decode failure must not read as the generic fallback"
        )
        XCTAssertFalse(
            UserFacingError.message(for: error)
                .localizedCaseInsensitiveContains("DecodingError")
        )
    }

    /// The GRDB-backed cache: open/read/write failures are their own family,
    /// and a full disk keeps the existing "free up space" class.
    func testCacheStorageFailuresClassifyAsCacheUnavailable() {
        let cantOpen = DatabaseError(
            resultCode: .SQLITE_CANTOPEN,
            message: "unable to open database file"
        )
        XCTAssertEqual(UserFacingError.classification(for: cantOpen), .cacheUnavailable)
        let corrupt = DatabaseError(
            resultCode: .SQLITE_CORRUPT,
            message: "database disk image is malformed"
        )
        XCTAssertEqual(UserFacingError.classification(for: corrupt), .cacheUnavailable)
        let full = DatabaseError(resultCode: .SQLITE_FULL, message: "database or disk is full")
        XCTAssertEqual(UserFacingError.classification(for: full), .storageFull)
        // The same failure bridged through the module boundary the app sees.
        let bridged = NSError(domain: "GRDB.DatabaseError", code: 14)
        XCTAssertEqual(UserFacingError.classification(for: bridged), .cacheUnavailable)

        let message = UserFacingError.message(for: cantOpen)
        XCTAssertEqual(message, UserFacingError.message(for: .cacheUnavailable))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("SQLITE"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("database file"))
    }

    /// The Keychain-backed session store: raw `OSStatus` values and the
    /// Supabase Auth SDK's internal `KeychainError` bridge domain.
    func testKeychainFailuresClassifyAsSecureStorageUnavailable() {
        let notAvailable = NSError(domain: NSOSStatusErrorDomain, code: -25291)
        XCTAssertEqual(
            UserFacingError.classification(for: notAvailable),
            .secureStorageUnavailable
        )
        let sdkKeychain = NSError(domain: "Auth.KeychainError", code: 1)
        XCTAssertEqual(
            UserFacingError.classification(for: sdkKeychain),
            .secureStorageUnavailable
        )
        XCTAssertEqual(
            UserFacingError.message(for: notAvailable),
            UserFacingError.message(for: .secureStorageUnavailable)
        )
    }

    /// HealthKit's own `HKError` codes (the app's typed `HealthKitError`
    /// already classifies itself; these are the framework's).
    func testHealthKitFrameworkFailuresClassifyByCodeFamily() {
        for code in [4, 5, 10] {
            XCTAssertEqual(
                UserFacingError.classification(
                    for: NSError(domain: "com.apple.healthkit", code: code)
                ),
                .healthPermissionDenied,
                "HKError authorization code \(code)"
            )
        }
        for code in [1, 2, 6, 11] {
            XCTAssertEqual(
                UserFacingError.classification(
                    for: NSError(domain: "com.apple.healthkit", code: code)
                ),
                .healthUnavailable,
                "HKError availability code \(code)"
            )
        }
        // Codes the app cannot explain honestly (invalid argument, user
        // cancelled, workout-session states) keep the generic fallback.
        XCTAssertEqual(
            UserFacingError.classification(
                for: NSError(domain: "com.apple.healthkit", code: 7)
            ),
            .unknown
        )
    }

    /// Core-owned storage errors ride the same families instead of `.unknown`.
    func testCoreStorageErrorsClassifyInsteadOfFallingToUnknown() {
        XCTAssertEqual(
            UserFacingError.classification(for: LocalCacheError.invalidPayload),
            .dataUnreadable
        )
        XCTAssertEqual(
            UserFacingError.classification(for: LocalCacheError.invalidJSON),
            .cacheUnavailable
        )
        XCTAssertEqual(
            UserFacingError.classification(for: DurableQueueError.invalidDirectory),
            .cacheUnavailable
        )
        // Internal invariants keep the honest generic copy.
        XCTAssertEqual(
            UserFacingError.classification(for: DurableQueueError.itemNotFound),
            .unknown
        )
        XCTAssertEqual(
            UserFacingError.classification(for: DurableQueueError.accountMismatch),
            .unknown
        )
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

    // MARK: - #964 round 2: the launch-path load funnel

    /// The delta reader's fail-closed errors are a launch-path data-load
    /// family: the page the app asked for is not in the shape/order it can
    /// consume, or the read could not be completed in one pass. Before this
    /// round they were `.unknown` — the copy the owner's device showed on
    /// every cold start.
    func testDeltaReadFailuresClassifyAsUnreadableData() {
        let failures: [(String, DeltaReadError)] = [
            ("outOfOrderPage", .outOfOrderPage),
            ("cursorDidNotAdvance", .cursorDidNotAdvance),
            ("pageBudgetExhausted", .pageBudgetExhausted(pageLimit: 64))
        ]
        for (name, error) in failures {
            XCTAssertEqual(
                UserFacingError.classification(for: error),
                .dataUnreadable,
                name
            )
            XCTAssertEqual(
                UserFacingError.classification(forLoadFailure: error),
                .dataUnreadable,
                name
            )
            XCTAssertEqual(
                UserFacingError.message(for: error),
                UserFacingError.message(for: .dataUnreadable),
                name
            )
            XCTAssertNotEqual(
                UserFacingError.message(for: error),
                UserFacingError.message(for: .unknown),
                "\(name) must not read as the generic fallback"
            )
        }
    }

    /// A cache that could not be prepared at launch is the cache family, not
    /// an unexplained failure — the reason's diagnostics detail never reaches
    /// copy.
    func testCachePreparationFailuresClassifyAsCacheUnavailable() {
        for reason in [
            CacheUnavailableReason.noSupportDirectory,
            CacheUnavailableReason.openFailed("disk I/O error")
        ] {
            XCTAssertEqual(
                UserFacingError.classification(for: reason),
                .cacheUnavailable
            )
            XCTAssertEqual(
                UserFacingError.message(for: reason),
                UserFacingError.message(for: .cacheUnavailable)
            )
        }
    }

    /// The load funnel walks the launch chain's failure surface. Every family
    /// the account-data load can throw has a NAMED class, and the ones this
    /// build cannot attribute get `.loadFailed` — the empty `.unknown` copy is
    /// unreachable from this path (that is the owner's banner, and it must
    /// never be the outcome of a first-launch data-load failure).
    func testLaunchPathLoadFailuresNeverClassifyAsUnknown() {
        let opaqueRaw = RawSampleError(raw: "The operation could not be completed.")
        let unexplainedHealthKit = NSError(domain: "com.apple.healthkit", code: 7)
        let cases: [(String, Error, FriendlyErrorClass)] = [
            ("offline", URLError(.notConnectedToInternet), .offline),
            ("timeout", URLError(.timedOut), .timeout),
            // A URLError code the taxonomy does not name (bad server response,
            // cancelled, cannot-parse, …) still arrives here on a real load.
            ("unmapped URLError code", URLError(.badServerResponse), .loadFailed),
            ("decode", DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "not in the correct format")
            ), .dataUnreadable),
            ("delta order", DeltaReadError.outOfOrderPage, .dataUnreadable),
            ("delta cursor", DeltaReadError.cursorDidNotAdvance, .dataUnreadable),
            ("delta budget", DeltaReadError.pageBudgetExhausted(pageLimit: 64), .dataUnreadable),
            ("cache open", DatabaseError(
                resultCode: .SQLITE_CANTOPEN,
                message: "unable to open database file"
            ), .cacheUnavailable),
            ("cache payload", LocalCacheError.invalidPayload, .dataUnreadable),
            ("cache write", LocalCacheError.invalidJSON, .cacheUnavailable),
            ("cache prepare", CacheUnavailableReason.openFailed("disk I/O error"), .cacheUnavailable),
            ("queue directory", DurableQueueError.invalidDirectory, .cacheUnavailable),
            ("keychain", NSError(domain: NSOSStatusErrorDomain, code: -25300), .secureStorageUnavailable),
            ("health permission", NSError(domain: "com.apple.healthkit", code: 4), .healthPermissionDenied),
            ("health unexplained code", unexplainedHealthKit, .loadFailed),
            ("opaque error", opaqueRaw, .loadFailed)
        ]
        for (name, error, expected) in cases {
            let classification = UserFacingError.classification(forLoadFailure: error)
            XCTAssertEqual(classification, expected, name)
            XCTAssertNotEqual(classification, .unknown, name)
            let message = UserFacingError.message(forLoadFailure: error)
            XCTAssertNotEqual(message, UserFacingError.message(for: .unknown), name)
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains("NSURLErrorDomain"),
                name
            )
            XCTAssertFalse(message.localizedCaseInsensitiveContains("DeltaReadError"), name)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("SendmeterCore"), name)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("SQLITE"), name)
        }

        // The funnel is a lift, not a re-label: a class the taxonomy CAN name
        // is never replaced, and the raw classifier's `.unknown` is still what
        // non-load callers see for an unattributable error.
        XCTAssertEqual(
            UserFacingError.classification(for: opaqueRaw),
            .unknown,
            "the raw classifier's fallback is unchanged for non-load callers"
        )
        XCTAssertEqual(
            UserFacingError.classification(forLoadFailure: URLError(.badServerResponse)),
            .loadFailed
        )
        XCTAssertEqual(
            UserFacingError.message(forLoadFailure: opaqueRaw),
            UserFacingError.message(for: .loadFailed)
        )
    }

    /// The named load class must not leak internals either.
    func testLoadFailedCopyIsActionableAndLeakFree() {
        let message = UserFacingError.message(for: .loadFailed)
        XCTAssertEqual(message, "Sendmeter couldn\u{2019}t load your data. Try again.")
        for token in ["Error", "domain", "code", "nil", "unknown", "NSURLError", "GRDB", "SQLite"] {
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains(token),
                "load copy must not carry \\(token)"
            )
        }
    }
}
