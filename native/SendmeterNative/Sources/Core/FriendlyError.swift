import Foundation
@_implementationOnly import GRDB
import SendLogWatchCore

/// The fixed classes of user-facing failure the native app is allowed to
/// describe (#758). A class is deliberately broader than an error type: the
/// UI copy must stay stable even when the underlying SDK changes, and callers
/// must never reach for a raw exception description in normal product copy.
public enum FriendlyErrorClass: Equatable, Sendable {
    case offline
    case timeout
    case authExpired
    case authClockSkew
    case authRejected
    case authEmailNotConfirmed
    case accountAlreadyExists
    case weakPassword
    case rateLimited
    case authFailed
    case passkeyAlreadyExists
    case passkeyLimitReached
    case accessDenied
    case serverRejected
    case saveFailed
    case missingAttempt
    case previousRecordingUnfinished
    case progressorNotConnected
    case progressorUnavailable
    case progressorConnectFailed
    case progressorDisconnected
    case progressorUnsupported
    case progressorUnrecognized
    case healthPermissionDenied
    case healthUnavailable
    case storageFull
    /// #964: the local account cache (GRDB-backed) could not be opened, read
    /// or written on this device.
    case cacheUnavailable
    /// #964: a payload the app stored or received is not in a shape this
    /// build can decode.
    case dataUnreadable
    /// #964: the Keychain-backed session store could not be reached.
    case secureStorageUnavailable
    /// #964 round 2: the account-data load — the launch/foreground refresh
    /// funnel — failed and this build cannot attribute the cause to a more
    /// specific family. Deliberately NOT `.unknown`: the copy names the
    /// operation and the retry re-runs the failed step, so a first-launch
    /// data-load failure can never render the empty generic fallback the
    /// owner saw on every cold start.
    case loadFailed
    case unknown
}

/// A typed error can declare which fixed class it belongs to. Conformances
/// live next to their error types (platform/Data layers) or in this file for
/// Core-owned errors, so classification is explicit rather than guessed from
/// a string wherever the app has a concrete type.
public protocol FriendlyErrorClassifying {
    var friendlyErrorClass: FriendlyErrorClass { get }
}

/// The single source of user-facing error copy (#758). Every normal-path
/// surface should route through `message(for:)`; raw diagnostics may continue
/// to be persisted and shown behind the support/diagnostics surfaces.
public enum UserFacingError {
    public static func message(for classification: FriendlyErrorClass) -> String {
        switch classification {
        case .offline:
            return "Couldn\u{2019}t reach Sendmeter. Check your Internet connection and try again."
        case .timeout:
            return "Sendmeter took too long to respond. Check your connection and try again."
        case .authExpired:
            return "Your session has expired. Sign in again, then try again."
        case .authClockSkew:
            return "Your iPhone’s date and time may be wrong. Turn on Set Automatically in Settings → General → Date & Time, then try again."
        case .authRejected:
            return "That email and password combination wasn\u{2019}t recognised. Try again, or use a magic link."
        case .authEmailNotConfirmed:
            return "Check your email to confirm your account, then try again."
        case .accountAlreadyExists:
            return "An account already exists for that email. Try signing in instead."
        case .weakPassword:
            return "That password isn\u{2019}t strong enough. Try a longer password with a mix of letters and numbers."
        case .rateLimited:
            return "Too many attempts. Wait a moment, then try again."
        case .authFailed:
            return "Sign-in couldn\u{2019}t complete. Check your details and try again."
        case .passkeyAlreadyExists:
            return "That passkey is already registered. Try signing in with it."
        case .passkeyLimitReached:
            return "You\u{2019}ve reached the passkey limit. Remove one in Settings, then try again."
        case .accessDenied:
            return "Sendmeter couldn\u{2019}t save this for your account. Sign in again, then try again."
        case .serverRejected:
            return "Sendmeter couldn\u{2019}t save this. Retry it, or discard it if you don\u{2019}t need it."
        case .saveFailed:
            return "Couldn\u{2019}t save this. Try again."
        case .missingAttempt:
            return "Record at least one attempt before finishing the workout."
        case .previousRecordingUnfinished:
            return "Save or discard the previous pull before starting another."
        case .progressorNotConnected:
            return "Connect the Progressor before starting."
        case .progressorUnavailable:
            return "Bluetooth is unavailable. Turn it on and try connecting again."
        case .progressorConnectFailed:
            return "Couldn\u{2019}t connect to the Progressor. Make sure it\u{2019}s on and nearby, then try again."
        case .progressorDisconnected:
            return "The Progressor disconnected. Reconnect it and try again."
        case .progressorUnsupported:
            return "This device can\u{2019}t connect to a Progressor over Bluetooth."
        case .progressorUnrecognized:
            return "The Progressor wasn\u{2019}t recognised. Turn it off and on, then try connecting again."
        case .healthPermissionDenied:
            return "Sendmeter can\u{2019}t read Apple Health. Allow Health access in Settings, then try again."
        case .healthUnavailable:
            return "Apple Health isn\u{2019}t available on this device."
        case .storageFull:
            return "This iPhone doesn\u{2019}t have enough free storage. Free up space and try again."
        case .cacheUnavailable:
            return "Sendmeter couldn\u{2019}t read its saved data on this iPhone. Reopen the app, then try again."
        case .dataUnreadable:
            return "Sendmeter couldn\u{2019}t read some of its data. Update Sendmeter, then try again."
        case .secureStorageUnavailable:
            return "Sendmeter couldn\u{2019}t reach its saved sign-in on this iPhone. Reopen the app, then try again."
        case .loadFailed:
            return "Sendmeter couldn\u{2019}t load your data. Try again."
        case .unknown:
            return "Something went wrong while completing that. Try again."
        }
    }

    /// Maps a concrete error through typed classification first, then
    /// Foundation/backend keyword classification. Unknown errors always get
    /// the fixed honest generic copy and never the original description.
    public static func message(for error: Error) -> String {
        message(for: classification(for: error))
    }

    /// Returns the fixed class used by every normal user-facing surface. Raw
    /// detail may be retained for the opt-in support ring, but it never needs
    /// to be converted to copy by callers that are deciding whether an error
    /// is auth-related or merely offline.
    public static func classification(for error: Error) -> FriendlyErrorClass {
        if let typed = error as? FriendlyErrorClassifying {
            return typed.friendlyErrorClass
        }
        // #964: the launch-path failure families that used to collapse into
        // `.unknown`. A payload (stored or received) that this build cannot
        // decode is its own class, not an unexplained failure.
        if error is DecodingError {
            return .dataUnreadable
        }
        // GRDB's own DatabaseError carries an SQLite result code; `SQLITE_FULL`
        // is the "free up space" case the copy already covers.
        if let databaseError = error as? DatabaseError {
            return databaseError.resultCode == .SQLITE_FULL
                ? .storageFull
                : .cacheUnavailable
        }
        if let urlError = error as? URLError {
            if let classification = classification(for: urlError.code) {
                return classification
            }
        } else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               let classification = classification(
                   for: URLError.Code(rawValue: nsError.code)
               ) {
                return classification
            }
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return .storageFull
            }
            if let classification = classification(
                forDomain: nsError.domain,
                code: nsError.code
            ) {
                return classification
            }
        }
        return Self.classification(for: BackendFailureReason(error: error))
    }

    /// #964 round 2: the account-data load funnel's classifier.
    ///
    /// The launch/foreground data load is the one path where the empty
    /// `.unknown` fallback is never acceptable — the owner's device banner
    /// ("Something went wrong while completing that.") was that fallback with
    /// nothing actionable behind it, on every cold start. Every error the
    /// taxonomy can name keeps its specific class; an error it cannot
    /// attribute keeps the honest named `.loadFailed` instead of the empty
    /// generic one. Callers that are NOT loading account data keep using
    /// `classification(for:)`, where an internal-invariant breach may still
    /// honestly read as `.unknown`.
    public static func classification(forLoadFailure error: Error) -> FriendlyErrorClass {
        let classification = classification(for: error)
        return classification == .unknown ? .loadFailed : classification
    }

    /// The load funnel's copy, paired with its classifier so a caller cannot
    /// mix the two (the banner and the Dashboard's retained class must always
    /// agree).
    public static func message(forLoadFailure error: Error) -> String {
        message(for: classification(forLoadFailure: error))
    }

    /// Maps a quarantined rejection using its immutable classification, so
    /// Settings never renders the server's raw code or detail inline.
    public static func message(for rejection: QueueRejection) -> String {
        message(for: classification(for: rejection.kind))
    }

    /// Active queue failures are diagnostic state, not terminal rejections.
    /// Keep their normal copy on the same stable taxonomy used everywhere
    /// else, while the technical Settings surface may still show the stored
    /// class/detail for support.
    public static func message(for rejectionClass: RejectionClass) -> String {
        message(for: classification(for: rejectionClass))
    }

    /// Stable plain-language labels for active queue diagnostics. The raw
    /// enum identifiers remain available only in the opt-in technical view.
    public static func label(for rejectionClass: RejectionClass) -> String {
        switch rejectionClass {
        case .retryable: return "temporary issue"
        case .auth: return "sign-in required"
        case .parked: return "permission issue"
        case .permanent: return "server rejection"
        }
    }

    public static func message(for failure: QueueFailure) -> String {
        message(for: failure.kind)
    }

    /// Maps an internal queue breadcrumb label to plain recovery copy. The
    /// persisted label is an implementation identifier; Settings must not
    /// show it to the user (#758).
    public static func message(forQueueBreadcrumbReason reason: String) -> String {
        switch reason {
        case "uploaded": return "Uploaded"
        case "recording-deleted": return "Recording deleted"
        case "recording-restored": return "Recording restored"
        case "replaced-by-delete": return "Pending upload deleted"
        case "quarantine-discarded": return "Rejected upload discarded"
        case "account-deleted", "account-cleared": return "Account cleared"
        default: return "Resolved"
        }
    }

    /// Maps an already-captured diagnostic string for displays that only have
    /// the text. Unknown/technical details never leak through.
    public static func message(forDiagnosticDetail detail: String) -> String {
        let lowercased = detail.lowercased()
        if lowercased.hasPrefix("auth ") {
            let payload = lowercased.dropFirst("auth ".count)
            let fields = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let code = fields.first.map(String.init) ?? ""
            let detailMessage = fields.count > 1 ? String(fields[1]).trimmingCharacters(in: .whitespaces) : nil
            return Self.message(
                for: friendlyErrorClass(
                    forAuthErrorCode: code,
                    message: detailMessage
                )
            )
        }
        if lowercased.contains("postgrest status=401") {
            return Self.message(for: .authExpired)
        }
        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return message(for: .timeout)
        }
        if lowercased.contains("jwt issued at future")
            || (lowercased.contains("future") && lowercased.contains("iat")) {
            return message(for: .authExpired)
        }
        let authCodeMarkers = [
            "invalid_claim", "bad_jwt", "invalid_jwt", "refresh_token_already_used",
            "refresh_token_not_found", "session_expired", "session_not_found"
        ]
        if authCodeMarkers.contains(where: lowercased.contains)
            || lowercased.contains("jwt expired")
            || lowercased.contains("unauthorized") {
            return message(for: .authExpired)
        }
        return message(
            for: classification(for: BackendFailureReason(errorDescription: detail))
        )
    }

    /// Maps a server-side auth error code to fixed copy. The code is an
    /// internal identifier and never rendered; this is only the classifier.
    public static func message(forAuthErrorCode code: String) -> String {
        message(for: friendlyErrorClass(forAuthErrorCode: code))
    }

    /// Auth diagnostics may be rendered in the opt-in support surface, but a
    /// GoTrue code/message is still not useful product copy. Keep the raw
    /// value available to classifiers only and return the same fixed class
    /// used by the normal auth banner.
    public static func message(
        forAuthDiagnosticCode code: String?,
        detail: String?
    ) -> String {
        let classification = friendlyErrorClass(
            forAuthErrorCode: code ?? "",
            message: detail
        )
        return message(for: classification == .authFailed ? .authExpired : classification)
    }

    /// The fixed class for a server-side auth error code. Typed app-layer
    /// conformances call this so the code never reaches user copy.
    public static func friendlyErrorClass(
        forAuthErrorCode code: String,
        message: String? = nil
    ) -> FriendlyErrorClass {
        classification(forAuthErrorCode: code, message: message)
    }

    private static func classification(
        for urlCode: URLError.Code
    ) -> FriendlyErrorClass? {
        switch urlCode {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return .offline
        default:
            return nil
        }
    }

    /// HealthKit's `NSError` domain (`HKErrorDomain`). HealthKit itself is not
    /// importable in this cross-platform Core target, so the domain string and
    /// the two code families the app can explain are pinned by
    /// `FriendlyErrorTests` against the SDK's real raw values (#964).
    private static let healthKitErrorDomain = "com.apple.healthkit"
    /// `HKError.Code.errorAuthorizationDenied` / `errorAuthorizationNotDetermined`
    /// / `errorRequiredAuthorizationDenied`.
    private static let healthKitPermissionCodes: Set<Int> = [4, 5, 10]
    /// `errorHealthDataUnavailable` / `errorHealthDataRestricted` /
    /// `errorDatabaseInaccessible` / `errorNoData`.
    private static let healthKitUnavailableCodes: Set<Int> = [1, 2, 6, 11]

    /// #964: framework error domains the launch path can surface, which the
    /// typed conformances cannot reach (GRDB bridges to its own domain, the
    /// Security framework reports OSStatus values, HealthKit reports
    /// `HKError`s, and the Supabase Auth SDK's Keychain errors are internal
    /// Swift structs that bridge to `<Module>.KeychainError`).
    private static func classification(
        forDomain domain: String,
        code: Int
    ) -> FriendlyErrorClass? {
        switch domain {
        case "GRDB.DatabaseError":
            return .cacheUnavailable
        case healthKitErrorDomain:
            if healthKitPermissionCodes.contains(code) {
                return .healthPermissionDenied
            }
            if healthKitUnavailableCodes.contains(code) {
                return .healthUnavailable
            }
            return nil
        case NSOSStatusErrorDomain:
            return .secureStorageUnavailable
        default:
            return domain.hasSuffix("KeychainError") ? .secureStorageUnavailable : nil
        }
    }

    private static func classification(
        forAuthErrorCode code: String,
        message: String? = nil
    ) -> FriendlyErrorClass {
        let normalizedCode = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let normalizedMessage = (message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let futureJWT = normalizedMessage.contains("jwt issued at future")
            || (normalizedMessage.contains("future")
                && (normalizedMessage.contains("iat")
                    || (normalizedMessage.contains("jwt")
                        && (normalizedMessage.contains("issued")
                            || normalizedMessage.contains("claim")))))
        if futureJWT {
            // The message is a server validation diagnosis, not a clock
            // measurement. Only the trusted server-clock policy may upgrade
            // it to the Date & Time nudge; otherwise ask for a fresh sign-in.
            return .authExpired
        }
        if normalizedMessage.contains("jwt expired")
            || normalizedMessage.contains("session expired")
            || normalizedMessage.contains("refresh token") {
            return .authExpired
        }
        switch normalizedCode {
        case "invalid_credentials", "email_address_not_authorized", "user_banned", "captcha_failed":
            return .authRejected
        case "email_not_confirmed", "provider_email_needs_verification":
            return .authEmailNotConfirmed
        case "email_exists", "user_already_exists", "phone_exists", "identity_already_exists":
            return .accountAlreadyExists
        case "weak_password":
            return .weakPassword
        case "over_request_rate_limit", "over_email_send_rate_limit", "over_sms_send_rate_limit":
            return .rateLimited
        case "request_timeout", "hook_timeout", "hook_timeout_after_retry":
            return .timeout
        case "session_expired", "session_not_found", "refresh_token_not_found",
             "refresh_token_already_used", "bad_jwt", "invalid_jwt",
             "invalid_claim", "future_iat", "jwt_issued_at_future",
             "reauthentication_not_valid", "otp_expired", "flow_state_expired",
             "webauthn_challenge_not_found", "webauthn_challenge_expired":
            return .authExpired
        case "webauthn_credential_exists":
            return .passkeyAlreadyExists
        case "too_many_passkeys":
            return .passkeyLimitReached
        default:
            return .authFailed
        }
    }

    private static func classification(
        for reason: BackendFailureReason
    ) -> FriendlyErrorClass {
        switch reason {
        case .authExpired: return .authExpired
        case .unreachable: return .offline
        case .unknown: return .unknown
        }
    }

    private static func classification(
        for kind: RejectionClass
    ) -> FriendlyErrorClass {
        switch kind {
        case .permanent: return .serverRejected
        case .auth: return .authExpired
        case .parked: return .accessDenied
        case .retryable: return .offline
        }
    }
}

extension WorkoutEngineError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .emptyWorkout: return .missingAttempt
        case .workoutAlreadyFinished,
             .attemptAlreadyRunning,
             .noAttemptRunning,
             .invalidEndTime:
            return .unknown
        }
    }
}

extension DurableQueueError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .invalidDirectory:
            // #964: the queue's durable file/directory could not be used —
            // the same local-storage family as the cache.
            return .cacheUnavailable
        case .accountMismatch, .itemNotFound, .alreadyQuarantined:
            // Internal invariants, not a user-recoverable storage failure.
            return .unknown
        }
    }
}

extension LocalCacheError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .invalidJSON:
            // A value could not be written to the cache.
            return .cacheUnavailable
        case .invalidPayload:
            // A stored payload could not be decoded back into the type this
            // build asks for — the decode family, not an unexplained failure.
            return .dataUnreadable
        }
    }
}

extension DeltaReadError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        // #964 round 2: the delta reader fails closed — a page that is not in
        // the `(updated_at, tie-break)` order this build asked for, a cursor
        // that cannot advance, or a page budget that runs out. Either way the
        // account's data could not be read on this pass, which is the decode
        // family rather than an unexplained failure.
        .dataUnreadable
    }
}

extension CacheUnavailableReason: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        // #964 round 2: the local cache could not be prepared at launch. The
        // reason's `detail` is diagnostics-ring data; it never reaches copy.
        .cacheUnavailable
    }
}
