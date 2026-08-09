import Foundation

/// Identity for an asynchronous owner. A new owner invalidates every older
/// token, so a cancelled flight cannot clear or complete a replacement flight
/// that started before the old task observed cancellation.
public struct ReadinessTaskGate: Equatable, Sendable {
    public typealias Token = UInt64

    private var nextToken: Token = 0
    private var activeToken: Token?

    public init() {}

    @discardableResult
    public mutating func begin() -> Token {
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    public mutating func invalidate() {
        activeToken = nil
    }

    public func isCurrent(_ token: Token) -> Bool {
        activeToken == token
    }
}

/// Identity of one native session binding. The bearer itself deliberately does
/// not cross into this core package or onto WatchConnectivity; native callers
/// keep that value in their private request binding. `tokenGeneration` lets a
/// same-user access-token rotation invalidate work that captured the previous
/// bearer without pretending that the user changed accounts.
public struct ReadinessSessionIdentity: Equatable, Sendable {
    public let accountEpoch: UInt64
    public let tokenGeneration: UInt64
    public let userId: UUID?

    public init(
        accountEpoch: UInt64,
        tokenGeneration: UInt64,
        userId: UUID?
    ) {
        self.accountEpoch = accountEpoch
        self.tokenGeneration = tokenGeneration
        self.userId = userId
    }
}

/// Account identity epoch for native consumers that receive access-token-only
/// relays. A token rotation for the same JWT subject keeps the epoch stable;
/// a different subject or explicit clear advances it. Results captured under
/// an old account epoch therefore cannot be published to a new account.
public struct ReadinessAccountEpoch: Equatable, Sendable {
    public enum SessionChange: Equatable, Sendable {
        case sameAccount
        case accountChanged
    }

    private var epoch: UInt64 = 0
    private var userId: UUID?
    private var hasSession = false

    public init() {}

    public var currentEpoch: UInt64 { epoch }
    public var isSignedOut: Bool { !hasSession }
    public var currentUserId: UUID? { userId }

    /// The identity a native request may capture. A token generation is kept
    /// separate from the account epoch: rotating a bearer for the same JWT
    /// subject does not discard account-scoped state, but it must not let a
    /// newly-created request join work bound to the old bearer.
    public func identity(tokenGeneration: UInt64) -> ReadinessSessionIdentity? {
        guard hasSession else { return nil }
        return ReadinessSessionIdentity(
            accountEpoch: epoch,
            tokenGeneration: tokenGeneration,
            userId: userId
        )
    }

    /// `nil` user IDs are treated as unknown identities. Repeated malformed
    /// tokens must not be mistaken for a same-user refresh and allowed to
    /// retain an old account's result cache.
    @discardableResult
    public mutating func setSession(userId: UUID?) -> SessionChange {
        if hasSession, let userId, self.userId == userId {
            return .sameAccount
        }
        epoch &+= 1
        hasSession = true
        self.userId = userId
        return .accountChanged
    }

    /// Restore the account epoch from the persisted native access-token
    /// subject during a cold launch. This is intentionally the same transition
    /// rule as a live relay, so a restored account cannot share an epoch with a
    /// stale pre-restart signed-out state.
    @discardableResult
    public mutating func restoreSession(userId: UUID?) -> SessionChange {
        setSession(userId: userId)
    }

    /// Clearing always advances the epoch, even if already signed out, so a
    /// completion that crossed the clear call cannot become publishable later.
    public mutating func clearSession() {
        epoch &+= 1
        hasSession = false
        userId = nil
    }

    public func owns(_ capturedEpoch: UInt64) -> Bool {
        !isSignedOut && capturedEpoch == epoch
    }
}

/// Common final publication gate for direct replies and application-context
/// result notifications. It is intentionally pure so sign-out/account-switch
/// interleavings can be forced in tests without WatchConnectivity.
public enum ReadinessRefreshDeliveryGate {
    public static func allows(
        capturedEpoch: UInt64,
        currentEpoch: UInt64,
        isSignedOut: Bool
    ) -> Bool {
        !isSignedOut && capturedEpoch == currentEpoch
    }

    public static func allows(
        captured: ReadinessSessionIdentity,
        current: ReadinessSessionIdentity?,
        isSignedOut: Bool
    ) -> Bool {
        !isSignedOut && current == captured
    }
}
