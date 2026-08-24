import Foundation

/// One observable change returned by a cursor-based repository fetch.
///
/// `value` is non-nil for an active or restored server row and nil for an
/// explicit tombstone. The caller never infers a delete from an absent row;
/// only the server's `deleted_at` row is authoritative for delta reconcile.
public struct RemoteEntityChange<Value: Sendable>: Sendable {
    public let entityID: String
    public let value: Value?
    public let updatedAt: Date

    public init(entityID: String, value: Value?, updatedAt: Date) {
        self.entityID = entityID
        self.value = value
        self.updatedAt = updatedAt
    }

    public var deleted: Bool { value == nil }
}

/// The cursor-bounded result of one repository entity fetch.
///
/// `activeValues` is the convenience full list for a first sync; `cursor` is
/// the greatest server `updated_at` observed in the response, formatted as a
/// cache cursor string. A nil cursor means no server rows were observed and
/// the caller must leave the existing cursor untouched until a later fetch.
public struct RemoteEntityDelta<Value: Sendable>: Sendable {
    public let changes: [RemoteEntityChange<Value>]
    public let activeValues: [Value]
    public let cursor: String?

    public init(
        changes: [RemoteEntityChange<Value>],
        activeValues: [Value],
        cursor: String?
    ) {
        self.changes = changes
        self.activeValues = activeValues
        self.cursor = cursor
    }
}

/// The full read snapshot held by `AppModel`'s observed collections.
///
/// This is the cache's typed boundary: the app target loads one of these
/// before the first network call, and a remote refresh reconciles another one
/// through the same entity IDs used by `LocalCacheStore`.
public struct CachedWorkspaceSnapshot: Equatable, Sendable {
    public var sessions: [Session] = []
    public var settings: UserSettings?
    public var phasePeriods: [PhasePeriod] = []
    public var healthMetrics: [HealthMetric] = []
    public var recordings: [TindeqRecording] = []
    public var presets: [TindeqPreset] = []
    public var routines: [RoutinePreset] = []
    public var workouts: [WorkoutListItem] = []
    public var tagMetadata: [TagMetadata] = []

    public init(
        sessions: [Session] = [],
        settings: UserSettings? = nil,
        phasePeriods: [PhasePeriod] = [],
        healthMetrics: [HealthMetric] = [],
        recordings: [TindeqRecording] = [],
        presets: [TindeqPreset] = [],
        routines: [RoutinePreset] = [],
        workouts: [WorkoutListItem] = [],
        tagMetadata: [TagMetadata] = []
    ) {
        self.sessions = sessions
        self.settings = settings
        self.phasePeriods = phasePeriods
        self.healthMetrics = healthMetrics
        self.recordings = recordings
        self.presets = presets
        self.routines = routines
        self.workouts = workouts
        self.tagMetadata = tagMetadata
    }
}

/// A thin hydration seam so `AppModel`'s cache-open/read failure policy can be
/// tested without instantiating the app target.
///
/// Returns `nil` when no cache is available (open failed), and throws when a
/// configured cache cannot be read. `AppModel` treats both the same way: it
/// continues with the existing network-only path and records a diagnostic.
public enum CacheHydrator {
    public static func load(
        workspace: CachedWorkspace?,
        accountUserID: UUID
    ) throws -> CachedWorkspaceSnapshot? {
        try workspace?.load(accountUserID: accountUserID)
    }
}

/// Stable cache row identities for the nine read entities.
///
/// These must agree with the entity ids already used by
/// `LocalCacheStoreTests` and with the rows produced by `CachedWorkspace`.
public enum CacheEntityID {
    public static let settings = "settings"

    public static func session(_ session: Session) -> String {
        session.id.uuidString
    }

    public static func phasePeriod(_ period: PhasePeriod) -> String {
        period.id.uuidString
    }

    public static func healthMetric(_ metric: HealthMetric) -> String {
        metric.date
    }

    public static func recording(_ recording: TindeqRecording) -> String {
        recording.id.uuidString
    }

    public static func preset(_ preset: TindeqPreset) -> String {
        preset.id.uuidString
    }

    public static func routine(_ routine: RoutinePreset) -> String {
        routine.id.uuidString
    }

    public static func workout(_ workout: WorkoutListItem) -> String {
        workout.id.uuidString
    }

    public static func tagMetadata(_ metadata: TagMetadata) -> String {
        metadata.name
    }
}

/// Typed facade over `LocalCacheStore` for the app read path.
///
/// The store itself remains opaque and account-scoped. This layer adds the
/// nine-entity snapshot shape plus a full-replace server reconciliation that
/// deliberately uses `upsertServer`/`markDeletedServer`, so an unconfirmed
/// local row survives a remote refresh. Full session snapshots also bound the
/// lifetime of absent watch-completion placeholders.
public struct CachedWorkspace: @unchecked Sendable {
    /// A watch completion is immediately useful as a pending History row, but
    /// a server snapshot that still lacks it must eventually stop counting a
    /// never-uploaded placeholder as training load. After this tombstone is
    /// written, the inbox remains durable provenance; only a later
    /// authoritative server delta can restore the identity.
    public static let watchCompletionPlaceholderTTL: TimeInterval = 7 * 24 * 60 * 60

    /// Read tables whose optimistic writes are not replayed by `DurableQueue`
    /// after process death. Their rows must never be silently treated as clean
    /// server state; AppModel surfaces them as unsynced instead.
    public static let directWriteEntityTypes: Set<LocalCacheEntityType> = [
        .settings,
        .phasePeriods,
        .healthMetrics,
        .presets,
        .routinePresets,
        .tagMetadata,
    ]

    public let store: LocalCacheStore

    public init(store: LocalCacheStore) {
        self.store = store
    }

    public func load(accountUserID: UUID) throws -> CachedWorkspaceSnapshot {
        CachedWorkspaceSnapshot(
            sessions: try store.loadAll(
                Session.self,
                accountUserID: accountUserID,
                entityType: .sessions
            ),
            settings: try store.loadOne(
                UserSettings.self,
                accountUserID: accountUserID,
                entityType: .settings,
                entityID: CacheEntityID.settings
            ),
            phasePeriods: try store.loadAll(
                PhasePeriod.self,
                accountUserID: accountUserID,
                entityType: .phasePeriods
            ),
            // `AppModel.readiness` uses the first metric, matching the
            // repository's date.desc fetch order. The generic cache store
            // orders opaque entity IDs ascending, so restore that invariant
            // at the typed health-metrics boundary without changing other
            // entity ordering or Gregorian date values.
            healthMetrics: try store.loadAll(
                HealthMetric.self,
                accountUserID: accountUserID,
                entityType: .healthMetrics
            ).sorted { $0.date > $1.date },
            recordings: try store.loadAll(
                TindeqRecording.self,
                accountUserID: accountUserID,
                entityType: .recordings
            ),
            presets: try store.loadAll(
                TindeqPreset.self,
                accountUserID: accountUserID,
                entityType: .presets
            ),
            routines: try store.loadAll(
                RoutinePreset.self,
                accountUserID: accountUserID,
                entityType: .routinePresets
            ),
            workouts: try store.loadAll(
                WorkoutListItem.self,
                accountUserID: accountUserID,
                entityType: .workoutsAndAttempts
            ),
            tagMetadata: try store.loadAll(
                TagMetadata.self,
                accountUserID: accountUserID,
                entityType: .tagMetadata
            )
        )
    }

    /// Reconciles one authoritative remote snapshot into the account cache.
    ///
    /// Present rows are upserted as server refresh rows. Rows that are no
    /// longer present are tombstoned as server deletes. Both operations
    /// refuse to overwrite a pending local row, so an offline optimistic write
    /// cannot be lost by a foreground refresh.
    public func reconcileServer(
        _ remote: CachedWorkspaceSnapshot,
        accountUserID: UUID,
        updatedAt: Date = Date(),
        now: Date = Date()
    ) throws {
        try reconcile(
            remote.sessions,
            accountUserID: accountUserID,
            entityType: .sessions,
            entityID: CacheEntityID.session,
            updatedAt: updatedAt
        )
        try store.expirePendingServerPlaceholders(
            accountUserID: accountUserID,
            entityType: .sessions,
            olderThan: now.addingTimeInterval(-Self.watchCompletionPlaceholderTTL),
            at: now
        )
        try reconcile(
            remote.settings.map { [$0] } ?? [],
            accountUserID: accountUserID,
            entityType: .settings,
            entityID: { _ in CacheEntityID.settings },
            updatedAt: updatedAt
        )
        try reconcile(
            remote.phasePeriods,
            accountUserID: accountUserID,
            entityType: .phasePeriods,
            entityID: CacheEntityID.phasePeriod,
            updatedAt: updatedAt
        )
        try reconcile(
            remote.healthMetrics,
            accountUserID: accountUserID,
            entityType: .healthMetrics,
            entityID: CacheEntityID.healthMetric,
            updatedAt: updatedAt
        )
        try reconcile(
            remote.recordings,
            accountUserID: accountUserID,
            entityType: .recordings,
            entityID: CacheEntityID.recording,
            updatedAt: updatedAt
        )
        try reconcile(
            remote.presets,
            accountUserID: accountUserID,
            entityType: .presets,
            entityID: CacheEntityID.preset,
            updatedAt: updatedAt
        )
        try reconcile(
            remote.routines,
            accountUserID: accountUserID,
            entityType: .routinePresets,
            entityID: CacheEntityID.routine,
            updatedAt: updatedAt
        )
        try reconcile(
            remote.workouts,
            accountUserID: accountUserID,
            entityType: .workoutsAndAttempts,
            entityID: CacheEntityID.workout,
            updatedAt: updatedAt
        )
        try reconcile(
            remote.tagMetadata,
            accountUserID: accountUserID,
            entityType: .tagMetadata,
            entityID: CacheEntityID.tagMetadata,
            updatedAt: updatedAt
        )
    }

    /// Reconciles only the slices that a realtime event asked to refresh.
    ///
    /// Unlike `reconcileServer`, this never tombstones an unrequested slice:
    /// one event (for example a new recording) may arrive while another
    /// account/device is still mid-refresh on a different table. The store's
    /// pending guard still protects local rows within each reconciled slice.
    public func reconcileSlices(
        _ remote: CachedWorkspaceSnapshot,
        accountUserID: UUID,
        slices: Set<ReconcileSlice>,
        updatedAt: Date = Date()
    ) throws {
        if slices.contains(.sessions) {
            try reconcile(
                remote.sessions,
                accountUserID: accountUserID,
                entityType: .sessions,
                entityID: CacheEntityID.session,
                updatedAt: updatedAt
            )
        }
        if slices.contains(.recordings) {
            try reconcile(
                remote.recordings,
                accountUserID: accountUserID,
                entityType: .recordings,
                entityID: CacheEntityID.recording,
                updatedAt: updatedAt
            )
        }
        if slices.contains(.workouts) {
            try reconcile(
                remote.workouts,
                accountUserID: accountUserID,
                entityType: .workoutsAndAttempts,
                entityID: CacheEntityID.workout,
                updatedAt: updatedAt
            )
        }
        if slices.contains(.health) {
            try reconcile(
                remote.healthMetrics,
                accountUserID: accountUserID,
                entityType: .healthMetrics,
                entityID: CacheEntityID.healthMetric,
                updatedAt: updatedAt
            )
        }
    }

    /// Reconciles one cursor-bounded delta into the account cache.
    ///
    /// Unlike `reconcileServer`, this never treats a row absent from the
    /// response as deleted: delta fetches include tombstones explicitly, so a
    /// hard-delete entity must reset its cursor when full reconciliation is
    /// needed. Pending rows are protected by the same store guards as every
    /// other server refresh. Session deltas also retire stale remote-device
    /// placeholders by `watchCompletionPlaceholderTTL`; the cursor advances
    /// only after every change and expiry in the batch has been applied.
    public func reconcileDelta<T: Encodable>(
        _ delta: RemoteEntityDelta<T>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        now: Date = Date()
    ) throws {
        try applyDeltaChanges(
            delta,
            accountUserID: accountUserID,
            entityType: entityType
        )
        if entityType == .sessions {
            try store.expirePendingServerPlaceholders(
                accountUserID: accountUserID,
                entityType: entityType,
                olderThan: now.addingTimeInterval(-Self.watchCompletionPlaceholderTTL),
                at: now
            )
        }
        if let cursor = delta.cursor {
            try store.setCursor(
                cursor,
                accountUserID: accountUserID,
                entityType: entityType
            )
        }
    }

    /// Reconciles one cursor-bounded delta as a full first-sync snapshot.
    ///
    /// Active delta rows are applied with their server `updated_at`, then
    /// cached rows absent from every active change are tombstoned and the
    /// cursor is persisted. Stale remote-device session placeholders are also
    /// retired by `watchCompletionPlaceholderTTL`; their inbox entries remain
    /// durable provenance for a later authoritative convergence. All writes
    /// happen before the cursor advances, so a failure leaves the cache safely
    /// repairable by another full refresh.
    public func reconcileServerDelta<T: Encodable>(
        _ delta: RemoteEntityDelta<T>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        now: Date = Date()
    ) throws {
        try applyDeltaChanges(
            delta,
            accountUserID: accountUserID,
            entityType: entityType
        )
        if entityType == .sessions {
            try store.expirePendingServerPlaceholders(
                accountUserID: accountUserID,
                entityType: entityType,
                olderThan: now.addingTimeInterval(-Self.watchCompletionPlaceholderTTL),
                at: now
            )
        }
        let remoteIDs = Set(
            delta.changes.compactMap { $0.value == nil ? nil : $0.entityID }
        )
        let cachedIDs = try store.activeEntityIDs(
            accountUserID: accountUserID,
            entityType: entityType
        )
        let pendingIDs = Set(try store.pendingEntityIDs(
            accountUserID: accountUserID,
            entityType: entityType
        ))
        for cachedID in cachedIDs
            where !remoteIDs.contains(cachedID) && !pendingIDs.contains(cachedID) {
            try store.markDeletedDeltaServer(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: cachedID,
                updatedAt: Date()
            )
        }
        if let cursor = delta.cursor {
            try store.setCursor(
                cursor,
                accountUserID: accountUserID,
                entityType: entityType
            )
        }
    }

    private func applyDeltaChanges<T: Encodable>(
        _ delta: RemoteEntityDelta<T>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws {
        for change in delta.changes {
            if let value = change.value {
                try store.upsertDeltaServer(
                    value,
                    accountUserID: accountUserID,
                    entityType: entityType,
                    entityID: change.entityID,
                    updatedAt: change.updatedAt
                )
            } else {
                try store.markDeletedDeltaServer(
                    accountUserID: accountUserID,
                    entityType: entityType,
                    entityID: change.entityID,
                    updatedAt: change.updatedAt
                )
            }
        }
    }

    public func cursor(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> String? {
        try store.cursor(accountUserID: accountUserID, entityType: entityType)
    }

    public func setCursor(
        _ cursor: String,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws {
        try store.setCursor(
            cursor,
            accountUserID: accountUserID,
            entityType: entityType
        )
    }

    public func resetCursor(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws {
        try store.deleteCursor(accountUserID: accountUserID, entityType: entityType)
    }

    @discardableResult
    public func upsertLocal<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> Int {
        try store.upsertLocal(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID
        )
    }

    public func confirmServerUpsert<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date = Date(),
        confirmingLocalRevision: Int
    ) throws {
        try store.confirmServerUpsert(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            updatedAt: updatedAt,
            confirmingLocalRevision: confirmingLocalRevision
        )
    }

    @discardableResult
    public func markDeletedLocal(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> Int {
        try store.markDeletedLocal(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID
        )
    }

    public func confirmServerDelete(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date = Date(),
        confirmingLocalRevision: Int
    ) throws {
        try store.confirmServerDelete(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            updatedAt: updatedAt,
            confirmingLocalRevision: confirmingLocalRevision
        )
    }

    public func upsertServer<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date = Date()
    ) throws {
        try store.upsertServer(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            updatedAt: updatedAt
        )
    }

    /// Persists a remote-origin placeholder that is known to exist durably on
    /// another device but has not reached Supabase yet (currently the watch's
    /// completed-workout summary). It stays visible through a full refresh and
    /// is replaced by the first authoritative server row for the same entity.
    /// Unlike `upsertLocal`, it is not a phone upload and therefore must not be
    /// counted as a direct-write or confirmed through the phone queue.
    public func upsertPendingServer<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        insertedAt: Date = Date()
    ) throws {
        try store.upsertPendingServer(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            insertedAt: insertedAt
        )
    }

    public func localRevision(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> Int? {
        try store.localRevision(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID
        )
    }

    public func pendingEntityIDs(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        includingDeleted: Bool = false
    ) throws -> [String] {
        try store.pendingEntityIDs(
            accountUserID: accountUserID,
            entityType: entityType,
            includingDeleted: includingDeleted
        )
    }

    /// Number of unconfirmed direct-write rows (including hidden deletes) for
    /// an account. These rows are preserved by reconcile but have no durable
    /// replay yet, so AppModel reports them to the UI as unsynced rather than
    /// pretending they were saved.
    public func pendingDirectWriteCount(accountUserID: UUID) throws -> Int {
        var count = 0
        for entityType in Self.directWriteEntityTypes {
            count += try store.pendingEntityIDs(
                accountUserID: accountUserID,
                entityType: entityType,
                includingDeleted: true
            ).count
        }
        return count
    }

    private func reconcile<T: Encodable>(
        _ remoteValues: [T],
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: (T) -> String,
        updatedAt: Date
    ) throws {
        let remoteIDs = Set(remoteValues.map(entityID))
        for value in remoteValues {
            try store.upsertServer(
                value,
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID(value),
                updatedAt: updatedAt
            )
        }
        let cachedIDs = try store.activeEntityIDs(
            accountUserID: accountUserID,
            entityType: entityType
        )
        let pendingIDs = Set(try store.pendingEntityIDs(
            accountUserID: accountUserID,
            entityType: entityType
        ))
        for cachedID in cachedIDs
            where !remoteIDs.contains(cachedID) && !pendingIDs.contains(cachedID) {
            try store.markDeletedServer(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: cachedID,
                updatedAt: updatedAt
            )
        }
    }
}
