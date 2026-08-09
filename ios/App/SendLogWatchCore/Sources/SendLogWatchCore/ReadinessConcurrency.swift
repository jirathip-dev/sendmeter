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
}
