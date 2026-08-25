import Foundation

/// The reason an upload is being attempted. Sign-out and same-account auth
/// recovery deliberately bypass ordinary backoff while retaining the
/// automatic quarantine budget; an explicit manual retry is the only mode
/// that does not spend that budget.
public enum QueueUploadMode: Equatable, Sendable {
    case automatic
    case manual
    /// A newly valid access token is an explicit recovery boundary for the
    /// owning account. It bypasses ordinary backoff, but still excludes
    /// quarantined entries so an auth refresh can never silently re-arm a
    /// payload the server permanently rejected.
    case authRecovery
    case signOut

    /// The due-date filter used when a captured queue item is revalidated.
    /// `nil` means "active, regardless of backoff"; the durable queue still
    /// excludes quarantined entries in every mode.
    public func revalidationDueAt(now: Date) -> Date? {
        switch self {
        case .automatic:
            return now
        case .manual, .authRecovery, .signOut:
            return nil
        }
    }

    /// Manual retry is an explicit user remediation and must not spend the
    /// bounded automatic quarantine budget. Sign-out remains automatic work.
    public var countsTowardQuarantine: Bool {
        self != .manual
    }
}

/// The small state machine around an explicit queue Retry action. Network
/// work itself belongs to AppModel; these decisions are pure so a retry can
/// be tested without compiling the SwiftUI app target.
public enum QueueRetryStep: Equatable, Sendable {
    case waitForOwner
    case upload
    case stop
}

public enum QueueRetryPolicy {
    /// Decide what to do after the durable item has been re-read. A queued
    /// item is still eligible for a manual attempt when it is backed off; only
    /// quarantine is terminal for this path.
    public static func beforeUpload(
        isClaimed: Bool,
        hasItem: Bool,
        isQuarantined: Bool
    ) -> QueueRetryStep {
        if isClaimed { return .waitForOwner }
        guard hasItem, !isQuarantined else { return .stop }
        return .upload
    }

    /// A successful upload or a recorded failure ends this Retry invocation.
    /// A nil result with a newly observed owner means another producer won the
    /// race, so the caller waits and re-reads the durable item once it settles.
    public static func afterUpload(
        uploaded: Bool,
        recordedFailure: Bool,
        ownerIsClaimed: Bool
    ) -> QueueRetryStep {
        if uploaded || recordedFailure { return .stop }
        return ownerIsClaimed ? .waitForOwner : .stop
    }
}

/// Stable account/item identity for a single-flight upload claim.
public struct QueueUploadKey: Hashable, Sendable {
    public let itemID: UUID
    public let accountUserID: UUID

    public init(itemID: UUID, accountUserID: UUID) {
        self.itemID = itemID
        self.accountUserID = accountUserID
    }
}

/// An ownership-bearing claim returned to the task that won a queue upload.
/// The token is intentionally opaque: only the coordinator can release it.
public struct QueueUploadClaim: Equatable, Sendable {
    fileprivate let key: QueueUploadKey
    fileprivate let token: UUID

    fileprivate init(key: QueueUploadKey, token: UUID) {
        self.key = key
        self.token = token
    }
}

/// Synchronous single-flight coordination for queue uploads.
///
/// Claims are scoped to an account/item key and remain live across clear/load
/// transitions. A task may stay suspended while another account is loaded;
/// the other account can claim its distinct key, but the original claim stays
/// in force until its owning task releases it. Each claim also carries an
/// ownership token so a stale release can never remove a later claim.
public struct QueueUploadClaimCoordinator: Sendable {
    private var ownerTokens: [QueueUploadKey: UUID] = [:]

    public init() {}

    /// Establish ownership before the caller's first await.
    @discardableResult
    public mutating func claim(_ key: QueueUploadKey) -> QueueUploadClaim? {
        guard ownerTokens[key] == nil else { return nil }
        let token = UUID()
        ownerTokens[key] = token
        return QueueUploadClaim(key: key, token: token)
    }

    /// Release only the exact ownership token that was returned to the task.
    /// A stale release can never remove a later claim for the same key.
    public mutating func release(_ claim: QueueUploadClaim) {
        guard ownerTokens[claim.key] == claim.token else { return }
        ownerTokens.removeValue(forKey: claim.key)
    }

    public func isClaimed(_ key: QueueUploadKey) -> Bool {
        ownerTokens[key] != nil
    }
}
