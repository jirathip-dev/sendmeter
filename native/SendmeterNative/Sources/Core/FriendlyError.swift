import Foundation
import SendLogWatchCore

/// The fixed classes of user-facing failure the native app is allowed to
/// describe (#758). A class is deliberately broader than an error type: the
/// UI copy must stay stable even when the underlying SDK changes, and callers
/// must never reach for a raw exception description in normal product copy.
public enum FriendlyErrorClass: Equatable, Sendable {
    case offline
    case timeout
    case authExpired
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
        case .unknown:
            return "Something went wrong while completing that. Try again."
        }
    }

    /// Maps a concrete error through typed classification first, then
    /// Foundation/backend keyword classification. Unknown errors always get
    /// the fixed honest generic copy and never the original description.
    public static func message(for error: Error) -> String {
        if let typed = error as? FriendlyErrorClassifying {
            return message(for: typed.friendlyErrorClass)
        }
        if let urlError = error as? URLError {
            if let classification = classification(for: urlError.code) {
                return message(for: classification)
            }
        } else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               let classification = classification(
                   for: URLError.Code(rawValue: nsError.code)
               ) {
                return message(for: classification)
            }
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return message(for: .storageFull)
            }
        }
        return message(for: Self.classification(for: BackendFailureReason(error: error)))
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
        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return message(for: .timeout)
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

    /// The fixed class for a server-side auth error code. Typed app-layer
    /// conformances call this so the code never reaches user copy.
    public static func friendlyErrorClass(forAuthErrorCode code: String) -> FriendlyErrorClass {
        classification(forAuthErrorCode: code)
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

    private static func classification(
        forAuthErrorCode code: String
    ) -> FriendlyErrorClass {
        switch code {
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
    public var friendlyErrorClass: FriendlyErrorClass { .unknown }
}

extension LocalCacheError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass { .unknown }
}
