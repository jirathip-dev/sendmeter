import Foundation

// MARK: - Auth session identity and recovery policy

/// The non-secret identity of a Supabase session used by the launch guard.
/// Never put an access token (or a refresh token) in this value or in its
/// persisted key. `sessionID` is the stable GoTrue session-family claim; the
/// timestamp fallback is only for tokens from older servers without it.
public struct AuthSessionDescriptor: Equatable, Sendable {
    public let userID: String
    public let sessionID: String?
    public let issuedAt: TimeInterval?
    public let expiresAt: TimeInterval?

    public init(
        userID: String,
        sessionID: String? = nil,
        issuedAt: TimeInterval? = nil,
        expiresAt: TimeInterval? = nil
    ) {
        self.userID = userID
        self.sessionID = sessionID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// A stable, non-secret key. Refreshes keep the same `session_id`; the
    /// fallback still changes when a materially different token is carried
    /// over, without persisting the token itself.
    public var stableKey: String {
        if let sessionID, !sessionID.isEmpty {
            return userID + "|session:" + sessionID
        }
        let issued = issuedAt.map { String(describing: $0) } ?? "-"
        let expires = expiresAt.map { String(describing: $0) } ?? "-"
        return userID + "|issued:" + issued + "|expires:" + expires
    }
}

public enum NativeAuthEvent: Equatable, Sendable {
    case initialSession
    case signedIn
    case tokenRefreshed
    case userUpdated
    case passwordRecovery
}

public enum AuthSessionGuardDecision: Equatable, Sendable {
    case accept
    case dropStaleInstall
    case dropPreviouslyRejected
}

/// Pure launch/session policy. A restored SDK session is presentable only if
/// this install has already accepted the same non-secret session identity.
/// Explicit sign-in and refresh events are trusted boundaries and establish a
/// new accepted identity.
public enum AuthSessionGuardPolicy {
    public static func decision(
        event: NativeAuthEvent,
        descriptor: AuthSessionDescriptor,
        hasInstallationMarker: Bool,
        acceptedSessionKey: String?,
        rejectedSessionKeys: Set<String>
    ) -> AuthSessionGuardDecision {
        if event == .initialSession {
            if rejectedSessionKeys.contains(descriptor.stableKey) {
                return .dropPreviouslyRejected
            }
            guard hasInstallationMarker,
                  acceptedSessionKey == descriptor.stableKey else {
                return .dropStaleInstall
            }
        }
        return .accept
    }
}

public struct AuthLaunchState: Equatable, Sendable {
    public let hadInstallationMarker: Bool
    public let hadStoredSession: Bool

    public var restoredSessionNeedsFreshSignIn: Bool {
        hadStoredSession && !hadInstallationMarker
    }
}

/// Small durable guard beside the SDK's Keychain session. It deliberately
/// stores only a marker and session identities. This catches an SDK session
/// that survived a partial app update/data reset while the app's own auth
/// state did not, and records a rejection before the first async sign-out so
/// the same poison cannot be retried forever on the next launch.
public final class AuthSessionGuardStore: @unchecked Sendable {
    private static let markerSuffix = ".installation-marker"
    private static let acceptedSuffix = ".accepted-session"
    private static let rejectedSuffix = ".rejected-sessions"
    private static let rejectedLimit = 4

    private let defaults: UserDefaults
    private let prefix: String
    private let lock = NSLock()
    private var launchState = AuthLaunchState(
        hadInstallationMarker: false,
        hadStoredSession: false
    )

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "sendmeter.native.auth.session-guard"
    ) {
        self.defaults = defaults
        self.prefix = keyPrefix
    }

    public func beginLaunch(hasStoredSession: Bool) -> AuthLaunchState {
        lock.lock()
        defer { lock.unlock() }
        let markerKey = prefix + Self.markerSuffix
        let hadMarker = defaults.string(forKey: markerKey) != nil
        if !hadMarker {
            defaults.set(UUID().uuidString, forKey: markerKey)
        }
        launchState = AuthLaunchState(
            hadInstallationMarker: hadMarker,
            hadStoredSession: hasStoredSession
        )
        return launchState
    }

    public func launchStateSnapshot() -> AuthLaunchState {
        lock.lock()
        defer { lock.unlock() }
        return launchState
    }

    public func acceptedSessionKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults.string(forKey: prefix + Self.acceptedSuffix)
    }

    public func rejectedSessionKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(defaults.stringArray(forKey: prefix + Self.rejectedSuffix) ?? [])
    }

    /// Marks a key before an async local sign-out. Returns false when this
    /// exact key was already rejected, which is the durable retry-loop guard.
    @discardableResult
    public func markRejected(_ descriptor: AuthSessionDescriptor) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = descriptor.stableKey
        var rejected = defaults.stringArray(forKey: prefix + Self.rejectedSuffix) ?? []
        guard !rejected.contains(key) else { return false }
        rejected.append(key)
        if rejected.count > Self.rejectedLimit {
            rejected.removeFirst(rejected.count - Self.rejectedLimit)
        }
        defaults.set(rejected, forKey: prefix + Self.rejectedSuffix)
        return true
    }

    /// A successful explicit sign-in or refresh establishes the new accepted
    /// identity and removes only that identity from the rejection list.
    public func accept(_ descriptor: AuthSessionDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        let key = descriptor.stableKey
        defaults.set(key, forKey: prefix + Self.acceptedSuffix)
        var rejected = defaults.stringArray(forKey: prefix + Self.rejectedSuffix) ?? []
        rejected.removeAll { $0 == key }
        defaults.set(rejected, forKey: prefix + Self.rejectedSuffix)
    }
}

// MARK: - Server-time evidence and clock skew

public enum AuthClockSkewAssessment: Equatable, Sendable {
    case insufficientEvidence
    case healthy
    case deviceClockAhead
    case tokenIssuedInFuture
}

public enum AuthClockSkewPolicy {
    /// A few minutes of tolerance covers ordinary HTTP latency, clock drift,
    /// and the fact that an HTTP Date header has one-second precision.
    public static let defaultDeviceAheadTolerance: TimeInterval = 5 * 60
    public static let defaultTokenFutureTolerance: TimeInterval = 2 * 60

    public static func evaluate(
        deviceDate: Date,
        trustedServerDate: Date?,
        tokenIssuedAt: TimeInterval?,
        deviceAheadTolerance: TimeInterval = defaultDeviceAheadTolerance,
        tokenFutureTolerance: TimeInterval = defaultTokenFutureTolerance
    ) -> AuthClockSkewAssessment {
        guard let trustedServerDate else { return .insufficientEvidence }
        if deviceDate.timeIntervalSince(trustedServerDate) > deviceAheadTolerance {
            return .deviceClockAhead
        }
        if let tokenIssuedAt,
           tokenIssuedAt - trustedServerDate.timeIntervalSince1970 > tokenFutureTolerance {
            return .tokenIssuedInFuture
        }
        return .healthy
    }
}

/// Stores only a successful server timestamp. The monotonic observation time
/// is persisted for diagnostics, but a timestamp is extrapolated only during
/// the same process boot. A reboot therefore cannot make a stale local wall
/// clock authoritative; the next successful HTTP response refreshes evidence.
public final class ServerClockStore: @unchecked Sendable {
    private static let serverDateSuffix = ".server-date"
    private static let uptimeSuffix = ".server-uptime"
    private static let bootSuffix = ".server-boot"

    private let defaults: UserDefaults
    private let prefix: String
    private let bootID = UUID().uuidString
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "sendmeter.native.auth.clock"
    ) {
        self.defaults = defaults
        self.prefix = keyPrefix
    }

    public func record(serverDate: Date, observedAtUptime: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(serverDate.timeIntervalSince1970, forKey: prefix + Self.serverDateSuffix)
        defaults.set(observedAtUptime, forKey: prefix + Self.uptimeSuffix)
        defaults.set(bootID, forKey: prefix + Self.bootSuffix)
    }

    public func recordHTTPDateHeader(_ value: String, observedAtUptime: TimeInterval) {
        guard let date = Self.date(fromHTTPDate: value) else { return }
        record(serverDate: date, observedAtUptime: observedAtUptime)
    }

    public func trustedServerDate(nowUptime: TimeInterval) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.string(forKey: prefix + Self.bootSuffix) == bootID,
              let seconds = defaults.object(forKey: prefix + Self.serverDateSuffix) as? Double,
              let observedUptime = defaults.object(forKey: prefix + Self.uptimeSuffix) as? Double,
              nowUptime >= observedUptime else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds + (nowUptime - observedUptime))
    }

    public func assessment(
        deviceDate: Date = Date(),
        tokenIssuedAt: TimeInterval?,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> AuthClockSkewAssessment {
        AuthClockSkewPolicy.evaluate(
            deviceDate: deviceDate,
            trustedServerDate: trustedServerDate(nowUptime: nowUptime),
            tokenIssuedAt: tokenIssuedAt
        )
    }

    /// RFC 7231's IMF-fixdate plus the two legacy HTTP-date spellings.
    public static func date(fromHTTPDate value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

// MARK: - Recovery decision

public enum AuthRecoveryAction: Equatable, Sendable {
    case none
    case clearPoisonedSession
}

public struct AuthRecoveryDecision: Equatable, Sendable {
    public let action: AuthRecoveryAction
    public let friendlyErrorClass: FriendlyErrorClass

    public init(action: AuthRecoveryAction, friendlyErrorClass: FriendlyErrorClass) {
        self.action = action
        self.friendlyErrorClass = friendlyErrorClass
    }
}

public struct AuthRecoveryError: Error, Equatable, Sendable, FriendlyErrorClassifying {
    public let friendlyErrorClass: FriendlyErrorClass

    public init(friendlyErrorClass: FriendlyErrorClass) {
        self.friendlyErrorClass = friendlyErrorClass
    }
}

public enum AuthRecoveryPolicy {
    public static func decision(
        errorCode: String?,
        message: String?,
        clockAssessment: AuthClockSkewAssessment = .insufficientEvidence,
        staleInstall: Bool = false
    ) -> AuthRecoveryDecision {
        if staleInstall {
            return AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: .authExpired
            )
        }
        if clockAssessment == .deviceClockAhead {
            return AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: .authClockSkew
            )
        }
        if clockAssessment == .tokenIssuedInFuture {
            return AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: .authExpired
            )
        }
        let classification = UserFacingError.friendlyErrorClass(
            forAuthErrorCode: errorCode ?? "",
            message: message
        )
        let shouldClear = classification == .authExpired || classification == .authClockSkew
        return AuthRecoveryDecision(
            action: shouldClear ? .clearPoisonedSession : .none,
            friendlyErrorClass: classification
        )
    }
}
