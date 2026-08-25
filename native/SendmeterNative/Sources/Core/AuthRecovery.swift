import Foundation

/// A sleep-counting monotonic clock. `ContinuousClock` is deliberately used
/// instead of `ProcessInfo.systemUptime`: the latter stops while an iPhone is
/// suspended, so an overnight return to the app would extrapolate server time
/// from an awake-only clock and manufacture a clock-skew diagnosis.
public protocol AuthMonotonicClock: Sendable {
    var now: TimeInterval { get }
}

public struct ContinuousMonotonicClock: AuthMonotonicClock, Sendable {
    private static let clock = ContinuousClock()
    private static let origin = Self.clock.now

    public init() {}

    public var now: TimeInterval {
        let components = Self.origin.duration(to: Self.clock.now).components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Auth session identity and recovery policy

/// The non-secret identity of a Supabase session used by the launch guard.
/// Never put an access token (or a refresh token) in this value or in its
/// persisted key. `sessionID` is the stable GoTrue session-family claim; the
/// timestamp fallback is only for tokens from older servers without it.
public struct AuthSessionDescriptor: Codable, Equatable, Sendable {
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

    /// Builds the non-secret identity used by the guard from a bearer JWT.
    /// The token is parsed transiently and is never retained by the
    /// descriptor or its stable key.
    public init(userID: String, accessToken: String, expiresAt: TimeInterval? = nil) {
        let claims = Self.claims(from: accessToken)
        self.init(
            userID: userID,
            sessionID: claims.sessionID,
            issuedAt: claims.issuedAt,
            expiresAt: expiresAt
        )
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

    private struct JWTClaims {
        let sessionID: String?
        let issuedAt: TimeInterval?
    }

    private static func claims(from token: String) -> JWTClaims {
        let pieces = token.split(separator: ".")
        guard pieces.count >= 2 else {
            return JWTClaims(sessionID: nil, issuedAt: nil)
        }
        var encoded = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any] else {
            return JWTClaims(sessionID: nil, issuedAt: nil)
        }
        return JWTClaims(
            sessionID: claims["session_id"] as? String,
            issuedAt: (claims["iat"] as? NSNumber)?.doubleValue
        )
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
        rejectedSessionKeys: Set<String>,
        grandfatheredSessionKey: String? = nil
    ) -> AuthSessionGuardDecision {
        if event == .initialSession {
            if rejectedSessionKeys.contains(descriptor.stableKey) {
                return .dropPreviouslyRejected
            }
            if grandfatheredSessionKey == descriptor.stableKey {
                return .accept
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
    /// A one-time compatibility allowance for a session that was already in
    /// the SDK Keychain when this guard first shipped. It preserves valid
    /// existing installs without making future unmarked sessions trusted.
    public let grandfatheredSessionKey: String?

    public var restoredSessionNeedsFreshSignIn: Bool {
        hadStoredSession && !hadInstallationMarker && grandfatheredSessionKey == nil
    }
}

/// Small durable guard beside the SDK's Keychain session. It deliberately
/// stores only a marker and session identities. This catches an SDK session
/// that survives after the app has already established its accepted identity,
/// and records a rejection before the first async sign-out so the same poison
/// cannot be retried forever on the next launch. The marker is deferred until
/// an identity is actually readable, because a locked-device/background launch
/// can observe neither the Keychain session nor its descriptor.
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
        hadStoredSession: false,
        grandfatheredSessionKey: nil
    )

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "sendmeter.native.auth.session-guard"
    ) {
        self.defaults = defaults
        self.prefix = keyPrefix
    }

    public func beginLaunch(
        hasStoredSession: Bool,
        storedSessionDescriptor: AuthSessionDescriptor? = nil
    ) -> AuthLaunchState {
        lock.lock()
        defer { lock.unlock() }
        let markerKey = prefix + Self.markerSuffix
        let hadMarker = defaults.string(forKey: markerKey) != nil
        let grandfatheredKey: String?
        if !hadMarker, hasStoredSession, let storedSessionDescriptor {
            defaults.set(UUID().uuidString, forKey: markerKey)
            let key = storedSessionDescriptor.stableKey
            defaults.set(key, forKey: prefix + Self.acceptedSuffix)
            grandfatheredKey = key
        } else {
            grandfatheredKey = nil
        }
        launchState = AuthLaunchState(
            hadInstallationMarker: hadMarker,
            hadStoredSession: hasStoredSession,
            grandfatheredSessionKey: grandfatheredKey
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

    /// Resolves the first initial-session identity after a launch that could
    /// not read the SDK session. The rejected-key check deliberately happens
    /// before this method is called by AuthService, so a known poison can never
    /// consume the first-identity acceptance window.
    @discardableResult
    public func acceptInitialSessionIfUnresolved(
        _ descriptor: AuthSessionDescriptor
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let markerKey = prefix + Self.markerSuffix
        guard defaults.string(forKey: markerKey) == nil else { return false }
        let key = descriptor.stableKey
        let rejected = Set(defaults.stringArray(forKey: prefix + Self.rejectedSuffix) ?? [])
        guard !rejected.contains(key) else { return false }
        defaults.set(UUID().uuidString, forKey: markerKey)
        defaults.set(key, forKey: prefix + Self.acceptedSuffix)
        launchState = AuthLaunchState(
            hadInstallationMarker: true,
            hadStoredSession: true,
            grandfatheredSessionKey: nil
        )
        return true
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
        let markerKey = prefix + Self.markerSuffix
        if defaults.string(forKey: markerKey) == nil {
            defaults.set(UUID().uuidString, forKey: markerKey)
        }
        defaults.set(key, forKey: prefix + Self.acceptedSuffix)
        var rejected = defaults.stringArray(forKey: prefix + Self.rejectedSuffix) ?? []
        rejected.removeAll { $0 == key }
        defaults.set(rejected, forKey: prefix + Self.rejectedSuffix)
        launchState = AuthLaunchState(
            hadInstallationMarker: true,
            hadStoredSession: true,
            grandfatheredSessionKey: nil
        )
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
    /// A server Date anchor is useful for a short background gap, but after
    /// this bound it is too old to diagnose the device clock honestly. A stale
    /// anchor must become inconclusive rather than signing out a correct-clock
    /// user after a long suspension.
    public static let defaultEvidenceMaxAge: TimeInterval = 15 * 60

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
    private static let processBootID = UUID().uuidString
    private let bootID: String
    private let clock: any AuthMonotonicClock
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "sendmeter.native.auth.clock",
        clock: any AuthMonotonicClock = ContinuousMonotonicClock()
    ) {
        self.defaults = defaults
        self.prefix = keyPrefix
        self.bootID = Self.processBootID
        self.clock = clock
    }

    public func record(serverDate: Date, observedAtContinuousTime: TimeInterval? = nil) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(serverDate.timeIntervalSince1970, forKey: prefix + Self.serverDateSuffix)
        defaults.set(
            observedAtContinuousTime ?? clock.now,
            forKey: prefix + Self.uptimeSuffix
        )
        defaults.set(bootID, forKey: prefix + Self.bootSuffix)
    }

    public func recordHTTPDateHeader(
        _ value: String,
        observedAtContinuousTime: TimeInterval? = nil
    ) {
        guard let date = Self.date(fromHTTPDate: value) else { return }
        record(serverDate: date, observedAtContinuousTime: observedAtContinuousTime)
    }

    public func trustedServerDate(
        nowContinuousTime: TimeInterval? = nil,
        maxAge: TimeInterval = AuthClockSkewPolicy.defaultEvidenceMaxAge
    ) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let currentContinuousTime = nowContinuousTime ?? clock.now
        guard defaults.string(forKey: prefix + Self.bootSuffix) == bootID,
              let seconds = defaults.object(forKey: prefix + Self.serverDateSuffix) as? Double,
              let observedUptime = defaults.object(forKey: prefix + Self.uptimeSuffix) as? Double,
              currentContinuousTime >= observedUptime,
              currentContinuousTime - observedUptime <= maxAge else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds + (currentContinuousTime - observedUptime))
    }

    public func assessment(
        deviceDate: Date = Date(),
        tokenIssuedAt: TimeInterval?,
        nowContinuousTime: TimeInterval? = nil,
        maxEvidenceAge: TimeInterval = AuthClockSkewPolicy.defaultEvidenceMaxAge
    ) -> AuthClockSkewAssessment {
        AuthClockSkewPolicy.evaluate(
            deviceDate: deviceDate,
            trustedServerDate: trustedServerDate(
                nowContinuousTime: nowContinuousTime,
                maxAge: maxEvidenceAge
            ),
            tokenIssuedAt: tokenIssuedAt
        )
    }

    /// RFC 7231's IMF-fixdate plus the two legacy HTTP-date spellings.
    public static func date(fromHTTPDate value: String) -> Date? {
        httpDateFormatterLock.lock()
        defer { httpDateFormatterLock.unlock() }
        for formatter in httpDateFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static let httpDateFormatterLock = NSLock()
    private static let httpDateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
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

/// The transport/recovery boundary must only remove the session that actually
/// issued the failing request. A newer session is never an eligible target.
public enum AuthSessionRecoveryPolicy {
    public static func shouldAttemptLocalRemoval(
        expected: AuthSessionDescriptor,
        current: AuthSessionDescriptor?
    ) -> Bool {
        guard let current, current.stableKey == expected.stableKey else {
            return false
        }
        guard let expectedIssuedAt = expected.issuedAt,
              let currentIssuedAt = current.issuedAt else {
            // Legacy descriptors may not carry an `iat`; the stable session
            // family key remains the only identity available in that case.
            return true
        }
        return expectedIssuedAt == currentIssuedAt
    }
}

/// A small pure gate shared by AppModel's explicit recovery path and its
/// auth-event tests. It makes the “one auth failure, one epoch” invariant
/// explicit even when local sign-out emits a buffered `.signedOut` event.
public enum AuthRecoveryEpochPolicy {
    public static func shouldBegin(
        hasActiveSession: Bool,
        recoveryInProgress: Bool
    ) -> Bool {
        hasActiveSession && !recoveryInProgress
    }

    /// A delayed `.signedOut` event is a no-op after an earlier recovery path
    /// has already made the model signed out. The caller must compute this
    /// from the live pre-clear state, not from a value captured after it sets
    /// `authSession` to nil.
    public static func shouldResetForSignedOut(hasActiveSession: Bool) -> Bool {
        hasActiveSession
    }

    /// A delayed `.signedOut` callback must not create a second boundary
    /// diagnostic after recovery already cleared the model. Account deletion
    /// remains observable even when the visible model is already empty.
    public static func shouldRecordBoundaryDiagnostic(
        isAccountDeletion: Bool,
        hasActiveSession: Bool
    ) -> Bool {
        isAccountDeletion || hasActiveSession
    }
}

public enum AuthRecoveryPolicy {
    public static func decision(
        errorCode: String?,
        message: String?,
        clockAssessment: AuthClockSkewAssessment = .insufficientEvidence,
        statusCode: Int? = nil
    ) -> AuthRecoveryDecision {
        if clockAssessment == .tokenIssuedInFuture {
            return AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: .authExpired
            )
        }
        if statusCode == 401 ||
            errorCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unauthorized" ||
            message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unauthorized" {
            return AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: .authExpired
            )
        }
        if clockAssessment == .deviceClockAhead {
            return AuthRecoveryDecision(
                action: .none,
                friendlyErrorClass: .authClockSkew
            )
        }
        let classification = UserFacingError.friendlyErrorClass(
            forAuthErrorCode: errorCode ?? "",
            message: message
        )
        let shouldClear = classification == .authExpired
        return AuthRecoveryDecision(
            action: shouldClear ? .clearPoisonedSession : .none,
            friendlyErrorClass: classification
        )
    }
}
