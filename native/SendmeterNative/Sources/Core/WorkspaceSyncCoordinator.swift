import Foundation

// MARK: - Workspace refresh and reconciliation ownership (#934)

/// #934: the storage seam the workspace-sync coordinator reconciles through.
///
/// Production has exactly one conformance — `CachedWorkspace`, the
/// account-scoped facade over the app's ONE local cache — so the coordinator
/// cannot grow a second cache or a second cursor store behind the app's back.
/// A test substitutes a fake to observe a rule without a database.
///
/// Pending-write precedence is deliberately NOT re-stated by this protocol:
/// it stays where it already lives (the store's own `reconcileDelta` /
/// `reconcileServerDelta` guards, which refuse to overwrite a pending row, and
/// the caller's durable `restorePendingWrites`). The coordinator passes a delta
/// through it; it never writes a cache row itself and never synthesizes one for
/// a pending entity.
public protocol WorkspaceSyncStoring: Sendable {
    /// The entity's persisted fetch cursor. `nil` means "fetch the full
    /// first-sync page and reconcile it as a full snapshot".
    func syncCursor(accountUserID: UUID, entityType: LocalCacheEntityType) throws -> String?

    /// The paired purge decision for the hard-delete-backed entities.
    func syncNeedsPurgeReconcile(
        accountUserID: UUID,
        remoteGeneration: Int64?
    ) throws -> Bool

    /// Reconciles one cursor-bounded delta (an ordinary incremental refresh).
    func applyDeltaReconcile<Value: Encodable & Sendable>(
        _ delta: RemoteEntityDelta<Value>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws

    /// Reconciles one delta as a full authoritative snapshot (first sync, or a
    /// forced full reconcile after a purge-generation mismatch).
    func applyFullReconcile<Value: Encodable & Sendable>(
        _ delta: RemoteEntityDelta<Value>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        purgeGeneration: Int64?
    ) throws

    /// One coherent point-in-time read of the account's cache.
    func syncCoherentRead(accountUserID: UUID) throws -> LocalCacheSnapshotRead
}

extension CachedWorkspace: WorkspaceSyncStoring {
    public func syncCursor(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> String? {
        try cursor(accountUserID: accountUserID, entityType: entityType)
    }

    public func syncNeedsPurgeReconcile(
        accountUserID: UUID,
        remoteGeneration: Int64?
    ) throws -> Bool {
        try needsPurgeReconcile(
            accountUserID: accountUserID,
            remoteGeneration: remoteGeneration
        )
    }

    public func applyDeltaReconcile<Value: Encodable & Sendable>(
        _ delta: RemoteEntityDelta<Value>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws {
        try reconcileDelta(delta, accountUserID: accountUserID, entityType: entityType)
    }

    public func applyFullReconcile<Value: Encodable & Sendable>(
        _ delta: RemoteEntityDelta<Value>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        purgeGeneration: Int64?
    ) throws {
        try reconcileServerDelta(
            delta,
            accountUserID: accountUserID,
            entityType: entityType,
            purgeGeneration: purgeGeneration
        )
    }

    public func syncCoherentRead(accountUserID: UUID) throws -> LocalCacheSnapshotRead {
        try coherentSnapshot(accountUserID: accountUserID)
    }
}

// MARK: - The fetch plan of one authoritative pass

/// #934: which entity is fetched with which cursor, and which two entities a
/// purge-generation mismatch forces through a full authoritative reconcile.
///
/// The plan is built from THIS pass's hydration revision, so the delta a pass
/// fetches is planned against exactly the rows it hydrated (#922). A nil cursor
/// is the first-sync / forced-full case: the caller fetches the whole page and
/// reconciles it as a full snapshot.
public struct WorkspaceRefreshPlan: Equatable, Sendable {
    private let cursors: [LocalCacheEntityType: String]

    /// True when the account's purge generation does not agree with the cache:
    /// both hard-delete-backed entities (sessions, recordings) must then be
    /// fully reconciled, because a hard purge leaves no row for a
    /// `updated_at > cursor` delta to return.
    public let forceFullReconcile: Bool

    public init(hydrated: LocalCacheSnapshotRead?, forceFullReconcile: Bool) {
        self.cursors = hydrated?.cursors ?? [:]
        self.forceFullReconcile = forceFullReconcile
    }

    /// The cursor to fetch with, or `nil` for the full first-sync page.
    ///
    /// Only `PurgeConvergencePolicy.affectedEntityTypes` honour
    /// `forceFullReconcile`: every other entity's incremental cursor is
    /// untouched by the purge signal, which is what keeps a purge convergence
    /// from turning into a full-workspace refetch.
    public func cursor(for entityType: LocalCacheEntityType) -> String? {
        if forceFullReconcile,
           PurgeConvergencePolicy.affectedEntityTypes.contains(entityType) {
            return nil
        }
        return cursors[entityType]
    }

    /// The reconcile rule that pairs with `cursor(for:)`: a nil cursor is a
    /// full snapshot, never a delta that happens to start empty.
    public func appliesFullSnapshot(for entityType: LocalCacheEntityType) -> Bool {
        cursor(for: entityType) == nil
    }
}

/// #934: the outcome of the optional purge-generation endpoint.
///
/// The endpoint is an optional rollout dependency: its failure must keep the
/// ordinary refresh alive, and a missing generation must never be read as
/// "generation zero". The resolution carries both facts to the boundary, which
/// decides what to record and surface.
public struct PurgeGenerationResolution {
    public let generation: Int64?
    /// Non-nil when the endpoint itself failed (schema lag, offline, …). The
    /// caller keeps the pass alive and reconciles the two affected entities
    /// authoritatively.
    public let endpointFailure: Error?

    public init(generation: Int64?, endpointFailure: Error?) {
        self.generation = generation
        self.endpointFailure = endpointFailure
    }

    public var isAvailable: Bool { endpointFailure == nil }
}

/// #934: the explicit account boundary of one coordinator operation.
///
/// The identity and lifecycle epoch are captured BEFORE the first await, and
/// re-checked after every await through this type — the coordinator never
/// reads the app's live account and never decides for itself what "current"
/// means. A stale boundary makes the operation publish nothing.
@MainActor
public struct WorkspaceAccountBoundary {
    public let fetch: AccountScopedFetch
    private let isCurrent: @MainActor () -> Bool

    public init(
        fetch: AccountScopedFetch,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.fetch = fetch
        self.isCurrent = isCurrent
    }

    public var accountUserID: UUID { fetch.accountUserID }
    public var accountEpoch: UInt64 { fetch.accountEpoch }

    /// Whether the captured identity still describes the live account.
    public func canApply() -> Bool { isCurrent() }
}

/// #934: the collected outcome of one authoritative refresh pass.
///
/// `failures` deliberately excludes cancelled slices: a cancelled pass is not
/// a verdict, so the caller's failure reporting never sees one (#923 AC5).
public struct WorkspaceRefreshOutcome {
    public let outcomes: RefreshSliceOutcomes
    public let failures: [RefreshSlice: Error]

    public init(outcomes: RefreshSliceOutcomes, failures: [RefreshSlice: Error]) {
        self.outcomes = outcomes
        self.failures = failures
    }
}

// MARK: - The coordinator

/// #934: the single owner of the workspace refresh and reconciliation rules.
///
/// Foreground (`AppModel.refreshAll`), background (`runBackgroundSync`) and
/// realtime (`refreshReconcileSlices`) all route their SHARED rules through
/// this one type:
///
/// - the fetch plan (`WorkspaceRefreshPlan`): which cursor each entity is
///   fetched with, and which two entities a purge mismatch forces through a
///   full authoritative reconcile;
/// - the optional purge-generation endpoint and its fallback rule;
/// - one entity's reconcile: a full snapshot on a nil cursor, a bounded delta
///   otherwise, both through the SAME store handle;
/// - one targeted slice (realtime, background): cursor → fetch → account
///   boundary re-check → reconcile → post-reconcile snapshot, degrading to a
///   full network fetch when the cache cannot be read;
/// - the per-slice outcome collection that decides which consistency groups
///   may publish.
///
/// Everything below stays at the BOUNDARY and is never inferred inside:
///
/// - account identity/epoch — passed in and re-checked via
///   `WorkspaceAccountBoundary`;
/// - completion ownership — the caller's `AccountScopedCompletion` (this type
///   never owns a spinner, a freshness stamp or a published collection);
/// - pending-write precedence — the store's own guard, plus the caller's
///   durable-queue restore (this type writes no row itself);
/// - the purge generation value — passed in and forwarded explicitly;
/// - cancellation — an explicit `Task.isCancelled` input, never inferred from
///   a swallowed error;
/// - cache-failure reporting — injected per call, so the app's diagnostics
///   ownership stays with the caller.
@MainActor
public struct WorkspaceSyncCoordinator {
    /// #922: the storage side of a point-in-time snapshot read. Production is
    /// `.live`; a probe holds it to prove the main actor stayed responsive.
    public let seams: CacheStorageSeams

    public init(seams: CacheStorageSeams = .live) {
        self.seams = seams
    }

    // MARK: Pure rules

    /// #934: the fetch plan of one pass, from this pass's hydration revision.
    public func plan(
        hydrated: LocalCacheSnapshotRead?,
        forceFullReconcile: Bool
    ) -> WorkspaceRefreshPlan {
        WorkspaceRefreshPlan(
            hydrated: hydrated,
            forceFullReconcile: forceFullReconcile
        )
    }

    /// #934: the one collection rule for a pass's per-slice results.
    ///
    /// A slice that failed keeps its last-good rows off the failure list only
    /// when the whole pass was cancelled: `isCancelled` is an explicit input
    /// (the caller's own cancellation state), so a cancelled pass publishes
    /// nothing, advances no cursor and reports no failure.
    public func collectOutcomes(
        _ results: [(slice: RefreshSlice, error: Error?)],
        isCancelled: Bool
    ) -> WorkspaceRefreshOutcome {
        var outcomes = RefreshSliceOutcomes()
        var failures: [RefreshSlice: Error] = [:]
        for (slice, error) in results {
            guard let error else {
                outcomes.record(slice: slice, failed: false)
                continue
            }
            if isCancelled || error is CancellationError {
                outcomes.markCancelled()
                continue
            }
            outcomes.record(slice: slice, failed: true)
            failures[slice] = error
        }
        return WorkspaceRefreshOutcome(outcomes: outcomes, failures: failures)
    }

    /// #934: the optional purge-generation endpoint, as data.
    ///
    /// A failure is returned rather than thrown: the pass keeps going and the
    /// caller decides whether that failure deserves the diagnostics ring or a
    /// banner (the public foreground refresh does; the silent ones do not).
    public func resolvePurgeGeneration(
        fetch: () async throws -> Int64?
    ) async -> PurgeGenerationResolution {
        do {
            return PurgeGenerationResolution(generation: try await fetch(), endpointFailure: nil)
        } catch {
            return PurgeGenerationResolution(generation: nil, endpointFailure: error)
        }
    }

    // MARK: Store reads

    /// #934: the entity's fetch cursor, read on the storage side.
    public func cursor<Store: WorkspaceSyncStoring>(
        in store: Store,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        onFailure: @MainActor (String, Error) -> Void = { _, _ in }
    ) async -> String? {
        do {
            return try await CacheOffload.run {
                try store.syncCursor(
                    accountUserID: accountUserID,
                    entityType: entityType
                )
            }
        } catch {
            onFailure("cache cursor read", error)
            return nil
        }
    }

    /// #934: the paired purge decision. A missing/corrupt marker is not
    /// permission to keep using a cursor that may have crossed a hard purge,
    /// so an unreadable marker fails closed to `true`.
    public func needsPurgeReconcile<Store: WorkspaceSyncStoring>(
        in store: Store,
        accountUserID: UUID,
        remoteGeneration: Int64?,
        onFailure: @MainActor (String, Error) -> Void = { _, _ in }
    ) async -> Bool {
        do {
            return try await CacheOffload.run {
                try store.syncNeedsPurgeReconcile(
                    accountUserID: accountUserID,
                    remoteGeneration: remoteGeneration
                )
            }
        } catch {
            onFailure("cache purge-generation read", error)
            return true
        }
    }

    /// #922/#934: one coherent read of the account's cache, on the storage
    /// side. Every bulk cache read in the app goes through here, so the read
    /// count stays one observable number and the main actor never performs the
    /// decode/sort work.
    public func readCoherentCache<Store: WorkspaceSyncStoring>(
        in store: Store,
        accountUserID: UUID,
        onFailure: @MainActor (String, Error) -> Void = { _, _ in }
    ) async -> LocalCacheSnapshotRead? {
        let seams = self.seams
        do {
            return try await CacheOffload.run {
                await seams.beforeSnapshotRead()
                return try store.syncCoherentRead(accountUserID: accountUserID)
            }
        } catch {
            onFailure("cache read", error)
            return nil
        }
    }

    // MARK: Entity reconcile

    /// #934: applies one entity refresh to the cache — a full snapshot on the
    /// first sync or after a cursor reset, a cursor-bounded delta otherwise.
    ///
    /// #922: the write runs on the storage side — one hop for the whole entity,
    /// never one task per row. The caller re-checks its account/epoch capture
    /// after this await. A cache error is reported and non-fatal, matching the
    /// cold-start read policy.
    public func reconcileEntity<Store: WorkspaceSyncStoring, Value: Encodable & Sendable>(
        in store: Store,
        _ delta: RemoteEntityDelta<Value>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        fullSnapshot: CachedWorkspaceSnapshot?,
        purgeGeneration: Int64? = nil,
        onFailure: @MainActor (String, Error) -> Void = { _, _ in }
    ) async {
        do {
            try await CacheOffload.run {
                if fullSnapshot != nil {
                    try store.applyFullReconcile(
                        delta,
                        accountUserID: accountUserID,
                        entityType: entityType,
                        purgeGeneration: purgeGeneration
                    )
                } else {
                    try store.applyDeltaReconcile(
                        delta,
                        accountUserID: accountUserID,
                        entityType: entityType
                    )
                }
            }
        } catch {
            onFailure("cache entity reconcile", error)
        }
    }

    // MARK: One targeted slice

    /// #934: fetches one targeted (realtime / background) slice as a
    /// cursor-bounded delta, reconciles it into the account cache, and returns
    /// the post-reconcile snapshot the caller publishes.
    ///
    /// The account boundary is re-checked in the gap between the network fetch
    /// and the cache write, so a slice that outlives a sign-out never mutates
    /// the wrong account's rows. A nil cursor triggers the same full first-sync
    /// adopt/tombstone behavior as the authoritative pass. `store` is optional
    /// because a process with no cache still publishes the fetched page (the
    /// network-only path).
    public func reconcileSlice<Store: WorkspaceSyncStoring, Value: Encodable & Sendable>(
        in store: Store?,
        boundary: WorkspaceAccountBoundary,
        entityType: LocalCacheEntityType,
        purgeGeneration: Int64? = nil,
        fetch: (String?) async throws -> RemoteEntityDelta<Value>,
        fullSnapshot: (RemoteEntityDelta<Value>) -> CachedWorkspaceSnapshot,
        onFailure: @MainActor (String, Error) -> Void = { _, _ in }
    ) async throws -> CachedWorkspaceSnapshot? {
        let accountUserID = boundary.accountUserID
        var cursor: String?
        if let store {
            cursor = await self.cursor(
                in: store,
                accountUserID: accountUserID,
                entityType: entityType,
                onFailure: onFailure
            )
        }
        let delta = try await fetch(cursor)
        guard boundary.canApply() else { return nil }
        if let store {
            await reconcileEntity(
                in: store,
                delta,
                accountUserID: accountUserID,
                entityType: entityType,
                fullSnapshot: cursor == nil ? fullSnapshot(delta) : nil,
                purgeGeneration: purgeGeneration,
                onFailure: onFailure
            )
        }
        guard boundary.canApply() else { return nil }
        guard let store else { return fullSnapshot(delta) }
        do {
            // #922: the publication read runs on the storage side, and it is
            // still exactly ONE full-workspace read for this slice — the
            // cursor above is a single-row query, not a second load.
            let seams = self.seams
            return try await CacheOffload.run {
                await seams.beforeSnapshotRead()
                return try store.syncCoherentRead(accountUserID: accountUserID).snapshot
            }
        } catch {
            onFailure("cache realtime publish", error)
            // A cursor-bounded delta is not a complete snapshot. If the cache
            // cannot be read, degrade to the same full network fallback a
            // cache-open failure uses rather than publishing only the changed
            // rows and dropping the rest of the in-memory list.
            guard cursor != nil else { return fullSnapshot(delta) }
            let fullDelta = try await fetch(nil)
            guard boundary.canApply() else { return nil }
            return fullSnapshot(fullDelta)
        }
    }

    // MARK: Background entity operation

    /// #934: one background-sync entity, built from the same shared rule as
    /// `reconcileSlice`: read the cursor (unless the purge mismatch forced a
    /// full reconcile), fetch, then apply exactly one reconcile hop.
    ///
    /// `BackgroundSyncEngine` still owns the per-operation account and
    /// cancellation guards between `prepare` and `apply`; a cancel or a stale
    /// scope before `apply` leaves the entity's cursor untouched.
    public func backgroundOperation<Store: WorkspaceSyncStoring, Value: Encodable & Sendable>(
        in store: Store,
        entityType: LocalCacheEntityType,
        accountUserID: UUID,
        forceFullReconcile: Bool = false,
        purgeGeneration: Int64? = nil,
        fetch: @escaping @MainActor @Sendable (String?) async throws -> RemoteEntityDelta<Value>,
        fullSnapshot: @escaping @MainActor @Sendable (RemoteEntityDelta<Value>) -> CachedWorkspaceSnapshot
    ) -> BackgroundSyncOperation {
        BackgroundSyncOperation(entityType: entityType) {
            let cursor: String?
            if forceFullReconcile {
                cursor = nil
            } else {
                // #922: the cursor read is blocking store work, so it runs on
                // the storage side too.
                cursor = try await CacheOffload.run {
                    try store.syncCursor(
                        accountUserID: accountUserID,
                        entityType: entityType
                    )
                }
            }
            let delta = try await fetch(cursor)
            let firstSnapshot = cursor == nil ? fullSnapshot(delta) : nil
            return BackgroundSyncPreparedOperation {
                // #922: the reconcile is one hop for the whole entity, with the
                // engine's account/epoch guard re-checked after it.
                try await CacheOffload.run {
                    if firstSnapshot != nil {
                        try store.applyFullReconcile(
                            delta,
                            accountUserID: accountUserID,
                            entityType: entityType,
                            purgeGeneration: purgeGeneration
                        )
                    } else {
                        try store.applyDeltaReconcile(
                            delta,
                            accountUserID: accountUserID,
                            entityType: entityType
                        )
                    }
                }
            }
        }
    }
}
