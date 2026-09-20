import Foundation

// MARK: - Coherent cache reads (#922)

/// #922: the content identity of one coherent cache read.
///
/// It is computed from the SAME single read that produced the rows, so two
/// reads with no intervening write agree exactly, and any write that changes
/// the account's cache — a changed row, a new row, a tombstone, a cursor
/// advance, a boundary, a purge generation — changes it. Nothing in it comes
/// from `Date()` or an uptime counter, so a recorded revision stays comparable
/// across processes and across a relaunch.
public struct LocalCacheRevision: Hashable, Sendable, CustomStringConvertible {
    /// Rows visible to reads (`deleted_at IS NULL`).
    public let liveRowCount: Int
    /// Tombstones, which are equally part of the local truth precedence.
    public let tombstoneCount: Int
    /// SHA-256 over the ordered row/cursor/boundary tuples of the read.
    public let digest: String

    public init(liveRowCount: Int, tombstoneCount: Int, digest: String) {
        self.liveRowCount = liveRowCount
        self.tombstoneCount = tombstoneCount
        self.digest = digest
    }

    public var description: String {
        "\(digest.prefix(16)) live=\(liveRowCount) tombstones=\(tombstoneCount)"
    }
}

/// One pending cache row, as observed by a coherent read.
public struct LocalCachePendingRow: Hashable, Sendable {
    public let entityType: LocalCacheEntityType
    public let entityID: String
    public let isDeleted: Bool

    public init(entityType: LocalCacheEntityType, entityID: String, isDeleted: Bool) {
        self.entityType = entityType
        self.entityID = entityID
        self.isDeleted = isDeleted
    }
}

/// #922: one point-in-time view of an account's local cache.
///
/// Every value here comes from ONE read transaction — the nine entity
/// collections, the pending rows, the sync cursors, the completed-sync
/// boundaries and the purge generations. That is what makes a publication
/// coherent: the delta a refresh fetches from the cursor in this read is
/// reconciled against exactly the rows this read observed, and the snapshot a
/// surface publishes cannot mix two different revisions.
public struct LocalCacheSnapshotRead: Sendable {
    public let snapshot: CachedWorkspaceSnapshot
    public let revision: LocalCacheRevision
    public let cursors: [LocalCacheEntityType: String]
    public let completedEntityTypes: Set<LocalCacheEntityType>
    public let purgeGenerations: [LocalCacheEntityType: Int64]
    public let pendingRows: [LocalCachePendingRow]

    public init(
        snapshot: CachedWorkspaceSnapshot,
        revision: LocalCacheRevision,
        cursors: [LocalCacheEntityType: String],
        completedEntityTypes: Set<LocalCacheEntityType>,
        purgeGenerations: [LocalCacheEntityType: Int64],
        pendingRows: [LocalCachePendingRow]
    ) {
        self.snapshot = snapshot
        self.revision = revision
        self.cursors = cursors
        self.completedEntityTypes = completedEntityTypes
        self.purgeGenerations = purgeGenerations
        self.pendingRows = pendingRows
    }

    public func cursor(for entityType: LocalCacheEntityType) -> String? {
        cursors[entityType]
    }

    /// Whether this account/entity has crossed an authoritative sync boundary,
    /// with the same precedence the store applies (a persisted cursor counts
    /// too, for caches created before the explicit empty-result marker).
    public func hasCompletedSync(_ entityType: LocalCacheEntityType) -> Bool {
        completedEntityTypes.contains(entityType)
    }

    /// The purge decision, derived from THIS read's boundaries instead of a
    /// second query — see `PurgeConvergencePolicy`.
    public func needsPurgeReconcile(remoteGeneration: Int64?) -> Bool {
        for entityType in PurgeConvergencePolicy.affectedEntityTypes {
            let requiresFull = PurgeConvergencePolicy.requiresFullReconcile(
                localGeneration: purgeGenerations[entityType],
                hasCompletedSync: completedEntityTypes.contains(entityType),
                remoteGeneration: remoteGeneration
            )
            if requiresFull { return true }
        }
        return false
    }

    /// Pending entity ids, in the store's own `entity_id` order.
    public func pendingEntityIDs(
        _ entityType: LocalCacheEntityType,
        includingDeleted: Bool = false
    ) -> [String] {
        pendingRows
            .filter { $0.entityType == entityType && (includingDeleted || !$0.isDeleted) }
            .map(\.entityID)
    }

    /// Unconfirmed direct-write rows (including hidden deletes) — the rows that
    /// have no durable replay and are reported to the UI as unsynced.
    public var pendingDirectWriteCount: Int {
        pendingRows.filter { CachedWorkspace.directWriteEntityTypes.contains($0.entityType) }.count
    }
}

/// #922: the one off-main-actor hop for local-cache work.
///
/// The unit of work is one BULK operation — a whole hydration, one entity's
/// reconcile, one publication read — never a row, so this deliberately has no
/// per-row fan-out variant. A detached task is used rather than a
/// `nonisolated` async function because its executor is unambiguous: the
/// work cannot be scheduled back onto the caller's actor, which is exactly
/// the property `LocalCacheStore`'s read instrumentation asserts.
public enum CacheOffload {
    public static func run<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
