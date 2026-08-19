import Foundation

/// The reason an upload is being attempted. Sign-out deliberately bypasses
/// ordinary backoff while retaining the automatic quarantine budget; an
/// explicit manual retry is the only mode that does not spend that budget.
public enum QueueUploadMode: Equatable, Sendable {
    case automatic
    case manual
    case signOut

    /// The due-date filter used when a captured queue item is revalidated.
    /// `nil` means "active, regardless of backoff"; the durable queue still
    /// excludes quarantined entries in every mode.
    public func revalidationDueAt(now: Date) -> Date? {
        switch self {
        case .automatic:
            return now
        case .manual, .signOut:
            return nil
        }
    }

    /// Manual retry is an explicit user remediation and must not spend the
    /// bounded automatic quarantine budget. Sign-out remains automatic work.
    public var countsTowardQuarantine: Bool {
        self != .manual
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
/// A clear/load transition may invalidate all current claims while an older
/// task is suspended. Each claim therefore carries an ownership token: a late
/// `release` from that older task can never remove a newer task's replacement
/// claim for the same account/item.
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
    /// A reset or replacement claim makes a stale release a no-op.
    public mutating func release(_ claim: QueueUploadClaim) {
        guard ownerTokens[claim.key] == claim.token else { return }
        ownerTokens.removeValue(forKey: claim.key)
    }

    public func isClaimed(_ key: QueueUploadKey) -> Bool {
        ownerTokens[key] != nil
    }

    /// Invalidate claims for loaded data being discarded. Existing tasks still
    /// release their own tokens later, but cannot release a future claim.
    public mutating func reset() {
        ownerTokens.removeAll()
    }
}
