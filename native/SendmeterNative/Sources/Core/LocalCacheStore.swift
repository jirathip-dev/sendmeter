import Foundation
// Keep GRDB out of SendmeterCore's public module interface. A direct exposure
// to the app target previously made the app-wide type checker time out in
// ActivityMixBar.swift; `@_implementationOnly` is intentional here even though
// Swift currently warns about it in non-library-evolution builds.
@_implementationOnly import GRDB

/// The nine read entities the native rewrite mirrors from Supabase. Each case
/// is the value stored in `cache_rows.entity_type`, so every read/write/delete
/// agrees on the same identity and no string literal can drift.
///
/// `workoutsAndAttempts` deliberately groups a workout with its attempts: the
/// cache payload is opaque Codable JSON chosen by the app layer (slice 2), and
/// the store only reasons about the row identity, so the grouping is a cache
/// bucket rather than a concrete model constraint.
public enum LocalCacheEntityType: String, Codable, CaseIterable, Hashable, Sendable {
    case sessions
    case settings
    case phasePeriods
    case healthMetrics
    case recordings
    case presets
    case routinePresets
    case workoutsAndAttempts
    case tagMetadata
}

/// Where a cache row's last write originated.
///
/// Local writes are optimistic and always replace the cached row. Server
/// writes are authoritative: they replace a non-pending local-origin row
/// regardless of wall-clock timestamps, and only replace an older server-origin
/// row. The two domains never compare timestamps against each other, so a
/// device clock ahead of Supabase cannot make cache reconcile permanently
/// lose.
public enum LocalCacheWriteOrigin: String, Codable, Sendable {
    case local
    case server
}

/// Errors surfaced by `LocalCacheStore` beyond GRDB's own `DatabaseError`.
public enum LocalCacheError: Error, Equatable, Sendable {
    /// A Codable value could not be encoded to a UTF-8 JSON payload.
    case invalidJSON
    /// A stored payload could not be decoded back into the requested type.
    case invalidPayload
}

/// A cache read that preserves successful values and reports rows that could
/// not be decoded, so callers can distinguish "empty cache" from "cache had
/// rows that are now invalid under the requested type".
public struct CacheLoadResult<T> {
    public let values: [T]
    public let invalidEntityIDs: [String]

    public init(values: [T], invalidEntityIDs: [String]) {
        self.values = values
        self.invalidEntityIDs = invalidEntityIDs
    }
}

/// A single-row cache read that distinguishes "row not cached", "row cached
/// but could not be decoded" and "row cached and decoded". `loadOne` collapses
/// the first two to `nil`; use `loadOneResult` when the caller must not silently
/// drop corrupt rows the way `loadAll` skips them.
public struct CacheLoadOneResult<T> {
    public let value: T?
    /// `true` when a non-deleted row exists for the entity but its payload is
    /// invalid under the requested type.
    public let invalid: Bool

    public init(value: T?, invalid: Bool) {
        self.value = value
        self.invalid = invalid
    }
}

/// GRDB deliberately does not declare `DatabaseQueue` as `Sendable`, but its
/// documented contract is that every access is serialized by the queue. Keep
/// that non-Sendable implementation detail behind one immutable holder so the
/// public cache handle can safely cross actors without exposing GRDB or
/// requiring every caller to carry an unchecked conformance.
private final class LocalCacheDatabase: @unchecked Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }
}

/// An account-scoped, SQLite-backed read cache (issue #747 slice 1).
///
/// Every row and cursor is scoped to `account_user_id`: reads and writes are
/// parameterized by the account, so an account can never observe another
/// account's rows even though they share one database file.
///
/// Rows are stored as opaque Codable JSON in `cache_rows`. The store only
/// cares about a row's identity (entity type + entity id) and the account it
/// belongs to; it never interprets the payload. A soft delete writes a
/// `deleted_at` tombstone that hides the row from reads, while a later upsert
/// clears the tombstone so a refreshed server row becomes visible again.
///
/// Every row records its `write_origin`, `pending`, and `local_revision`
/// state. Local writes are optimistic and always replace a cached row, marking
/// it pending and bumping `local_revision` until the server confirms. A
/// server-origin pending row is a durable remote-device placeholder (for
/// example, a watch completion): it is protected from an absent-row refresh
/// but is replaced by the first authoritative row for the same identity.
/// `local_revision` is strictly monotonic over a row's lifetime: every local
/// write/delete increments it, and neither a **confirmation** nor a refresh
/// **adoption** ever resets it, so a stale confirmation from an earlier cycle
/// can never numerically match a newer pending edit. A server-origin
/// placeholder intentionally keeps revision `0` because it is not a phone
/// mutation. A server **refresh**
/// (`upsertServer`/`markDeletedServer`) never reverts a pending local action —
/// it only replaces non-pending local-origin rows and otherwise uses
/// last-writer-wins on a microsecond-precision `updated_at`. A server-origin
/// pending placeholder is adoptable when its authoritative row arrives. A server
/// **confirmation** (`confirmServerUpsert`/`confirmServerDelete`) applies the
/// server's post-upload state and clears pending only when the row's stored
/// `local_revision` still equals the revision that was uploaded; slice 2+
/// calls this after the DurableQueue successfully uploads. Server deletes are
/// remembered as tombstones even for keys that have never been cached.
///
/// The schema also has per-account `sync_cursors` and `sync_boundaries` tables.
/// A cursor is optional when a successful server response contains no rows, so
/// the boundary table separately records that an entity has completed at least
/// one authoritative sync. `deleteAccount` purges both tables for the account.
///
/// The cache is a shared reference: all copies of the handle use the same
/// GRDB queue, and GRDB serializes every access to that queue. The only
/// unchecked boundary is `LocalCacheDatabase`, whose sole stored reference is
/// to that queue; no raw GRDB connection or mutable cache state escapes it.
public final class LocalCacheStore: Sendable {
    private let database: LocalCacheDatabase

    /// Internal test seam for migration and schema assertions. Production
    /// callers use the typed cache methods and never receive the GRDB queue.
    var dbQueue: DatabaseQueue {
        database.queue
    }

    /// Which server write semantics to apply for a payload or tombstone.
    ///
    /// - `.local`: an optimistic local write/delete. It unconditionally
    ///   replaces any cached row and marks it `pending` (unconfirmed).
    /// - `.serverRefresh`: a poll/realtime refresh. It must never revert a
    ///   pending local action; it replaces a non-pending local-origin row and
    ///   otherwise uses server LWW.
    /// - `.serverConfirm`: the server's ack for a successfully uploaded local
    ///   write/delete. It applies the post-upload server state and clears
    ///   `pending` only while the cached row's `local_revision` still equals
    ///   the revision that was uploaded, and preserves the row's monotonic
    ///   `local_revision`. Only slice 2+ calls this after `DurableQueue`
    ///   upload.
    private enum CacheWriteMode {
        case local
        case serverRefresh
        case serverConfirm
    }

    init(dbQueue: DatabaseQueue) throws {
        let database = LocalCacheDatabase(queue: dbQueue)
        self.database = database
        try Self.migrate(dbQueue)
    }

    /// File-backed store at `databaseURL`.
    public init(databaseURL: URL) throws {
        let database = LocalCacheDatabase(queue: try DatabaseQueue(path: databaseURL.path))
        self.database = database
        try Self.migrate(database.queue)
    }

    /// In-memory store for tests and one-off scratch databases.
    public init() throws {
        let database = LocalCacheDatabase(queue: try DatabaseQueue())
        self.database = database
        try Self.migrate(database.queue)
    }

    /// Creates `cache_rows` and `sync_cursors` (and the `grdb_migrations`
    /// ledger) on the queue. Safe to call any number of times: the migrator
    /// records applied migrations and skips them on subsequent runs.
    ///
    /// `createLocalCacheTables` is intentionally frozen: the column-adding
    /// migrations below are the only way `cache_rows` gains `write_origin` and
    /// `pending`. Do NOT fold those columns into the CREATE TABLE — each
    /// column-add is guarded by a `PRAGMA table_info` check so a database that
    /// already has the column (for example one created by a future dev who
    /// "completed" the CREATE TABLE) still migrates without a duplicate-column
    /// error.
    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createLocalCacheTables") { db in
            // Frozen DDL: never add columns here. Use the dedicated
            // column-adding migrations below.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cache_rows (
                    account_user_id TEXT NOT NULL,
                    entity_type     TEXT NOT NULL,
                    entity_id       TEXT NOT NULL,
                    payload         TEXT NOT NULL,
                    deleted_at      TEXT,
                    updated_at      TEXT NOT NULL,
                    PRIMARY KEY (account_user_id, entity_type, entity_id)
                );
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_cursors (
                    account_user_id TEXT NOT NULL,
                    entity_type     TEXT NOT NULL,
                    cursor          TEXT NOT NULL,
                    updated_at      TEXT NOT NULL,
                    PRIMARY KEY (account_user_id, entity_type)
                );
                """)
        }
        migrator.registerMigration("addWriteOriginToCacheRows") { db in
            // Kept as a separate migration so databases created by the first
            // release of this schema (which had no origin column) upgrade
            // without rebuilding. Existing rows are deliberately local: they
            // predate server reconcile and must not be discarded.
            let hasOrigin = try Self.hasColumn("write_origin", in: "cache_rows", db: db)
            if !hasOrigin {
                try db.execute(sql: """
                    ALTER TABLE cache_rows
                    ADD COLUMN write_origin TEXT NOT NULL DEFAULT 'local'
                    """)
            }
        }
        migrator.registerMigration("addPendingToCacheRows") { db in
            // Local optimistic writes/deletes are unconfirmed until the
            // DurableQueue uploads them; a server refresh must not revert an
            // unconfirmed local action. `pending` is 0 for confirmed/clean rows
            // (server-origin, or a pre-existing cache row backfilled as clean)
            // and 1 for local writes awaiting server confirmation.
            let hasPending = try Self.hasColumn("pending", in: "cache_rows", db: db)
            if !hasPending {
                try db.execute(sql: """
                    ALTER TABLE cache_rows
                    ADD COLUMN pending INTEGER NOT NULL DEFAULT 0
                    """)
            }
        }
        migrator.registerMigration("addLocalRevisionToCacheRows") { db in
            // Every local optimistic write/delete bumps a per-row revision so a
            // server **confirmation** for an uploaded change can tell whether
            // the pending row it is about to clear still belongs to that same
            // upload. `local_revision` is 0 only for a brand-new row (or a
            // backfilled pre-revision row); each local write increments it,
            // and it is never reused after a confirmation or refresh adoption.
            let hasRevision = try Self.hasColumn("local_revision", in: "cache_rows", db: db)
            if !hasRevision {
                try db.execute(sql: """
                    ALTER TABLE cache_rows
                    ADD COLUMN local_revision INTEGER NOT NULL DEFAULT 0
                    """)
            }
        }
        migrator.registerMigration("addSyncBoundaries") { db in
            // An empty successful fetch has no updated_at cursor to persist.
            // Keep that authoritative-empty fact separate from sync_cursors so
            // a readable SQLite file can never masquerade as a first sync.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_boundaries (
                    account_user_id TEXT NOT NULL,
                    entity_type     TEXT NOT NULL,
                    synced_at       TEXT NOT NULL,
                    PRIMARY KEY (account_user_id, entity_type)
                );
                """)
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Reads

    /// Loads every non-deleted payload for one account + entity type,
    /// decoded as `T`.
    public func loadAllResult<T: Decodable>(
        _ type: T.Type,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> CacheLoadResult<T> {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT entity_id, payload FROM cache_rows
                    WHERE account_user_id = ? AND entity_type = ? AND deleted_at IS NULL
                    ORDER BY entity_id
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue]
            )
        }

        var values: [T] = []
        var invalidEntityIDs: [String] = []
        for row in rows {
            let entityID = row["entity_id"] as String
            let payload = row["payload"] as String
            do {
                values.append(try decode(payload: payload, as: T.self))
            } catch {
                invalidEntityIDs.append(entityID)
            }
        }
        return CacheLoadResult(values: values, invalidEntityIDs: invalidEntityIDs)
    }

    /// Loads every non-deleted payload for one account + entity type,
    /// decoded as `T`. Invalid rows are skipped; use `loadAllResult` when the
    /// caller needs to know which entity IDs were skipped.
    public func loadAll<T: Decodable>(
        _ type: T.Type,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> [T] {
        try loadAllResult(type, accountUserID: accountUserID, entityType: entityType).values
    }

    /// Loads one non-deleted payload for one account + entity, decoded as `T`,
    /// and reports whether the row was present but corrupt.
    ///
    /// `invalid` is `true` when a non-deleted row exists but its payload could
    /// not be decoded as `T` (the same rows `loadAllResult` reports in
    /// `invalidEntityIDs`), so `loadOneResult` lets a detail surface distinguish
    /// "not cached" from "cached but currently unusable".
    public func loadOneResult<T: Decodable>(
        _ type: T.Type,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> CacheLoadOneResult<T> {
        let payload: String? = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT payload FROM cache_rows
                    WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                      AND deleted_at IS NULL
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue, entityID]
            )
        }
        guard let payload else {
            return CacheLoadOneResult(value: nil, invalid: false)
        }
        do {
            return CacheLoadOneResult(value: try decode(payload: payload, as: T.self), invalid: false)
        } catch {
            return CacheLoadOneResult(value: nil, invalid: true)
        }
    }

    /// Loads one non-deleted payload for one account + entity, decoded as `T`.
    ///
    /// Returns `nil` both when the row is absent and when the row's payload is
    /// corrupt under `T` (matching `loadAll`, which skips invalid rows). Use
    /// `loadOneResult` to distinguish those two states.
    public func loadOne<T: Decodable>(
        _ type: T.Type,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> T? {
        try loadOneResult(type, accountUserID: accountUserID, entityType: entityType, entityID: entityID).value
    }

    /// Returns every non-deleted entity id for one account + entity type.
    ///
    /// Used by full-replace reconcile to discover rows that the authoritative
    /// remote snapshot no longer contains. Like every other read here, the
    /// lookup is account-scoped so one account's reconcile can never tombstone
    /// another account's rows.
    public func activeEntityIDs(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> [String] {
        return try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT entity_id FROM cache_rows
                    WHERE account_user_id = ? AND entity_type = ? AND deleted_at IS NULL
                    ORDER BY entity_id
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue]
            )
        }
    }

    /// Returns every non-deleted, still-pending entity id for one account +
    /// entity type.
    ///
    /// The cache owns the durable pending marker; this lets the app restore its
    /// in-memory optimistic overlays on cold start even before the durable
    /// queue has been read. Tombstoned rows are intentionally omitted by
    /// default: a pending delete should not reappear as an editable row. Pass
    /// `includingDeleted` when the caller needs the full pending set (for
    /// diagnostics/unsynced-write counting), including hidden deletes.
    public func pendingEntityIDs(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        includingDeleted: Bool = false
    ) throws -> [String] {
        let deletedClause = includingDeleted ? "" : " AND deleted_at IS NULL"
        return try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT entity_id FROM cache_rows
                    WHERE account_user_id = ? AND entity_type = ?
                      AND pending = 1\(deletedClause)
                    ORDER BY entity_id
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue]
            )
        }
    }

    /// Retires stale remote-device placeholders during an authoritative full
    /// reconcile. A placeholder is evidence that another device completed a
    /// session, but after the bounded window an absent server row must not
    /// remain a permanent History/ACWR phantom. This only touches
    /// `pending + write_origin=server`; phone-owned pending writes are never
    /// expired here. The tombstone preserves the no-resurrection rule for
    /// stale server upserts, while a later authoritative delta can still
    /// replace it.
    public func expirePendingServerPlaceholders(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        olderThan: Date,
        at: Date = Date()
    ) throws {
        let cutoff = Self.timestamp(olderThan)
        let expiredAt = Self.timestamp(at)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE cache_rows SET
                        payload = '{}',
                        deleted_at = ?,
                        updated_at = ?,
                        write_origin = 'server',
                        pending = 0
                    WHERE account_user_id = ? AND entity_type = ?
                      AND deleted_at IS NULL
                      AND pending = 1
                      AND write_origin = 'server'
                      AND updated_at < ?
                    """,
                arguments: [
                    expiredAt,
                    expiredAt,
                    Self.accountIDString(accountUserID),
                    entityType.rawValue,
                    cutoff
                ]
            )
        }
    }

    /// Reads the monotonic local revision for one account + entity, if any.
    ///
    /// After a relaunch the caller cannot rely on the revision returned by the
    /// in-memory `upsertLocal`/`markDeletedLocal` call, so the upload
    /// confirmation must re-read the current revision before applying the
    /// server ack. Tombstoned rows retain their revision, so this also works
    /// for a pending delete that has been hidden from `loadAll`.
    public func localRevision(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> Int? {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT local_revision FROM cache_rows
                    WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue, entityID]
            )
        }
    }

    // MARK: - Writes

    /// Optimistically upserts one locally-produced payload for an account +
    /// entity. Local writes always replace any cached row, mark it `pending`,
    /// and bump its `local_revision`: a later server **refresh**
    /// (`upsertServer`) will not revert the unconfirmed edit, and
    /// `confirmServerUpsert` is what clears the pending flag after the
    /// DurableQueue upload succeeds.
    ///
    /// - Returns: the `local_revision` assigned to this optimistic write. Pass
    ///   the same value to `confirmServerUpsert` so the server ack applies only
    ///   if no newer local edit has replaced it.
    @discardableResult
    public func upsertLocal<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> Int {
        try writePayload(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            mode: .local,
            updatedAt: Date()
        )
    }

    /// Applies one server-confirmed payload and clears the pending flag.
    ///
    /// This is the **confirmation** path, not the refresh path. Call it only
    /// after the DurableQueue successfully uploads a local change, and pass the
    /// entity's post-upload server `updated_at` plus the `local_revision`
    /// returned by the matching `upsertLocal`. It replaces the cached row with
    /// the server state and clears `pending` **only** while that revision still
    /// matches; if a newer local edit bumped the revision while the upload was
    /// in flight, the confirmation is a no-op so the newer edit survives with
    /// its `pending` flag intact. It is also a no-op when the row no longer
    /// exists (for example after `deleteAccount` purges it), so a late ack can
    /// never recreate cache state for a purged account.
    public func confirmServerUpsert<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date,
        confirmingLocalRevision: Int
    ) throws {
        _ = try writePayload(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            mode: .serverConfirm,
            updatedAt: updatedAt,
            confirmingLocalRevision: confirmingLocalRevision
        )
    }

    /// Upserts one server payload from a refresh (poll or realtime).
    ///
    /// A refresh must **not** revert an unconfirmed local action: if the cached
    /// row is a local-origin `pending` row, the incoming payload is dropped and
    /// its `local_revision` is preserved. A server-origin pending row is a
    /// remote-device placeholder, so an incoming row with the same identity
    /// adopts it even when its server timestamp is older than the phone's
    /// receive time. Otherwise a server write replaces a non-pending
    /// local-origin row regardless of clock and replaces a server-origin row
    /// only when `updatedAt` is strictly newer; in both adoption cases the
    /// row's monotonic `local_revision` is preserved rather than reused. The
    /// writer must pass the entity's server `updated_at`; timestamps are
    /// microsecond-precision and compared within the server domain only. Use
    /// `confirmServerUpsert` for the post-upload ack instead.
    public func upsertServer<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date
    ) throws {
        _ = try writePayload(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            mode: .serverRefresh,
            updatedAt: updatedAt
        )
    }

    /// Persists a remote-device placeholder without pretending that the phone
    /// has an upload queued. It is idempotent by account/entity identity and
    /// never overwrites an existing row. The normal server refresh and delta
    /// paths treat `pending + write_origin=server` as adoptable once the
    /// authoritative row arrives. `insertedAt` is injectable so the
    /// full-reconcile TTL can be tested without waiting on wall-clock time.
    public func upsertPendingServer<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        insertedAt: Date = Date()
    ) throws {
        let json = try JSONEncoder().encode(value)
        guard let payload = String(data: json, encoding: .utf8) else {
            throw LocalCacheError.invalidJSON
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                    VALUES (?, ?, ?, ?, NULL, ?, 'server', 1, 0)
                    ON CONFLICT(account_user_id, entity_type, entity_id) DO NOTHING
                    """,
                arguments: [
                    Self.accountIDString(accountUserID),
                    entityType.rawValue,
                    entityID,
                    payload,
                    Self.timestamp(insertedAt)
                ]
            )
        }
    }

    private func writePayload<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        mode: CacheWriteMode,
        updatedAt: Date,
        confirmingLocalRevision: Int? = nil
    ) throws -> Int {
        let json = try JSONEncoder().encode(value)
        guard let payload = String(data: json, encoding: .utf8) else {
            throw LocalCacheError.invalidJSON
        }
        let incoming = Self.timestamp(updatedAt)
        return try dbQueue.write { db -> Int in
            switch mode {
            case .local:
                let current = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT local_revision FROM cache_rows
                        WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID
                    ]
                ) ?? 0
                let next = current + 1
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                        VALUES (?, ?, ?, ?, NULL, ?, 'local', 1, ?)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = excluded.payload,
                            deleted_at = NULL,
                            updated_at = excluded.updated_at,
                            write_origin = 'local',
                            pending = 1,
                            local_revision = ?
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        payload,
                        incoming,
                        next,
                        next
                    ]
                )
                return next
            case .serverRefresh:
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                        VALUES (?, ?, ?, ?, NULL, ?, 'server', 0, 0)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.payload
                                WHEN cache_rows.write_origin = 'local' THEN excluded.payload
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN excluded.payload
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.deleted_at
                                WHEN cache_rows.write_origin = 'local' THEN NULL
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN NULL
                                WHEN cache_rows.updated_at < excluded.updated_at THEN NULL
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.updated_at
                                WHEN cache_rows.write_origin = 'local' THEN excluded.updated_at
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN excluded.updated_at
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.write_origin
                                WHEN cache_rows.write_origin = 'local' THEN 'server'
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN 'server'
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 'server'
                                ELSE cache_rows.write_origin
                            END,
                            pending = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN 1
                                WHEN cache_rows.write_origin = 'local' THEN 0
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN 0
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 0
                                ELSE cache_rows.pending
                            END,
                            local_revision = cache_rows.local_revision
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        payload,
                        incoming
                    ]
                )
                return 0
            case .serverConfirm:
                let confirming = confirmingLocalRevision ?? 0
                try db.execute(
                    sql: """
                        UPDATE cache_rows SET
                            payload = ?,
                            deleted_at = NULL,
                            updated_at = ?,
                            write_origin = 'server',
                            pending = 0
                        WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                          AND pending = 1 AND write_origin = 'local' AND local_revision = ?
                        """,
                    arguments: [
                        payload,
                        incoming,
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        confirming
                    ]
                )
                return 0
            }
        }
    }

    /// Optimistically soft-deletes one locally-produced entity for an account
    /// (hidden from reads), marking it pending and bumping its
    /// `local_revision`. The tombstone is created even when the key was never
    /// cached, so a later server **refresh** cannot resurrect it;
    /// `confirmServerDelete` is what clears the pending flag after the
    /// DurableQueue uploads the delete.
    ///
    /// - Returns: the `local_revision` assigned to this optimistic delete. Pass
    ///   the same value to `confirmServerDelete` so the server ack applies only
    ///   if no newer local edit has replaced it.
    @discardableResult
    public func markDeletedLocal(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> Int {
        try writeTombstone(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            mode: .local,
            updatedAt: Date()
        )
    }

    /// Applies one server-confirmed soft delete and clears the pending flag.
    ///
    /// This is the **confirmation** path, not the refresh path. Call it only
    /// after the DurableQueue successfully uploads a local delete, and pass the
    /// server's post-delete `updated_at` plus the `local_revision` returned by
    /// the matching `markDeletedLocal`. It writes the tombstone and clears
    /// `pending` **only** while that revision still matches; if a newer local
    /// edit bumped the revision while the upload was in flight, the
    /// confirmation is a no-op so the newer edit survives with its `pending`
    /// flag intact. It is also a no-op when the row no longer exists (for
    /// example after `deleteAccount`), so a late delete ack cannot recreate
    /// cache state for a purged account.
    public func confirmServerDelete(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date,
        confirmingLocalRevision: Int
    ) throws {
        _ = try writeTombstone(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            mode: .serverConfirm,
            updatedAt: updatedAt,
            confirmingLocalRevision: confirmingLocalRevision
        )
    }

    /// Soft-deletes one server entity from a refresh (hidden from reads).
    ///
    /// A refresh delete never reverts a pending action: local pending rows and
    /// remote-device placeholders are preserved because absence from this
    /// refresh is not proof that either action has reached the server. It
    /// otherwise inserts a tombstone even when the key was never cached (so
    /// an out-of-order stale upsert cannot resurrect a server-deleted row),
    /// replaces a non-pending local-origin row, and only replaces an older
    /// server-origin row; in both adoption cases the row's monotonic
    /// `local_revision` is preserved rather than reused. The workspace
    /// reconcile filters pending ids before calling this for an absent row;
    /// the pending-server branch remains a defensive store-level invariant for
    /// direct callers. Use `confirmServerDelete` for the post-upload ack
    /// instead.
    public func markDeletedServer(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date
    ) throws {
        _ = try writeTombstone(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            mode: .serverRefresh,
            updatedAt: updatedAt
        )
    }

    /// Upserts one server payload from a cursor-bounded delta.
    ///
    /// A delta fetch is authoritative for every row it returns: the row was
    /// selected because its `updated_at` crossed the persisted cursor, so it
    /// must replace the cached server state even if an earlier local
    /// confirmation or realtime refresh happened to store a later device-side
    /// timestamp. Pending local rows are still protected.
    public func upsertDeltaServer<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date
    ) throws {
        let json = try JSONEncoder().encode(value)
        guard let payload = String(data: json, encoding: .utf8) else {
            throw LocalCacheError.invalidJSON
        }
        let incoming = Self.timestamp(updatedAt)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                    VALUES (?, ?, ?, ?, NULL, ?, 'server', 0, 0)
                    ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                        payload = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.payload
                            ELSE excluded.payload
                        END,
                        deleted_at = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.deleted_at
                            ELSE excluded.deleted_at
                        END,
                        updated_at = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.updated_at
                            ELSE excluded.updated_at
                        END,
                        write_origin = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.write_origin
                            ELSE 'server'
                        END,
                        pending = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN 1
                            ELSE 0
                        END,
                        local_revision = cache_rows.local_revision
                    """,
                arguments: [
                    Self.accountIDString(accountUserID),
                    entityType.rawValue,
                    entityID,
                    payload,
                    incoming
                ]
            )
        }
    }

    /// Soft-deletes one server entity from a cursor-bounded delta.
    ///
    /// Same authoritative semantics as `upsertDeltaServer`: the row is in the
    /// delta because the server explicitly tombstoned it after the cursor, so
    /// a locally-confirmed timestamp must not keep a stale active row alive.
    /// Unlike an absent-row refresh, this explicit tombstone also replaces a
    /// remote-device placeholder: the server has now authoritatively said
    /// that identity is deleted.
    public func markDeletedDeltaServer(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date
    ) throws {
        let incoming = Self.timestamp(updatedAt)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                    VALUES (?, ?, ?, '{}', ?, ?, 'server', 0, 0)
                    ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                        payload = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.payload
                            ELSE excluded.payload
                        END,
                        deleted_at = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.deleted_at
                            ELSE excluded.deleted_at
                        END,
                        updated_at = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.updated_at
                            ELSE excluded.updated_at
                        END,
                        write_origin = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.write_origin
                            ELSE 'server'
                        END,
                        pending = CASE
                            WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN 1
                            ELSE 0
                        END,
                        local_revision = cache_rows.local_revision
                    """,
                arguments: [
                    Self.accountIDString(accountUserID),
                    entityType.rawValue,
                    entityID,
                    incoming,
                    incoming
                ]
            )
        }
    }

    private func writeTombstone(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        mode: CacheWriteMode,
        updatedAt: Date,
        confirmingLocalRevision: Int? = nil
    ) throws -> Int {
        let incoming = Self.timestamp(updatedAt)
        return try dbQueue.write { db -> Int in
            switch mode {
            case .local:
                let current = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT local_revision FROM cache_rows
                        WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID
                    ]
                ) ?? 0
                let next = current + 1
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                        VALUES (?, ?, ?, '{}', ?, ?, 'local', 1, ?)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = excluded.payload,
                            deleted_at = excluded.deleted_at,
                            updated_at = excluded.updated_at,
                            write_origin = 'local',
                            pending = 1,
                            local_revision = ?
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        incoming,
                        incoming,
                        next,
                        next
                    ]
                )
                return next
            case .serverRefresh:
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                        VALUES (?, ?, ?, '{}', ?, ?, 'server', 0, 0)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.payload
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN cache_rows.payload
                                WHEN cache_rows.write_origin = 'local' THEN excluded.payload
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.deleted_at
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN cache_rows.deleted_at
                                WHEN cache_rows.write_origin = 'local' THEN excluded.deleted_at
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.deleted_at
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.updated_at
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN cache_rows.updated_at
                                WHEN cache_rows.write_origin = 'local' THEN excluded.updated_at
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN cache_rows.write_origin
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN cache_rows.write_origin
                                WHEN cache_rows.write_origin = 'local' THEN 'server'
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 'server'
                                ELSE cache_rows.write_origin
                            END,
                            pending = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'local' THEN 1
                                WHEN cache_rows.pending = 1 AND cache_rows.write_origin = 'server' THEN 1
                                WHEN cache_rows.write_origin = 'local' THEN 0
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 0
                                ELSE cache_rows.pending
                            END,
                            local_revision = cache_rows.local_revision
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        incoming,
                        incoming
                    ]
                )
                return 0
            case .serverConfirm:
                let confirming = confirmingLocalRevision ?? 0
                try db.execute(
                    sql: """
                        UPDATE cache_rows SET
                            payload = '{}',
                            deleted_at = ?,
                            updated_at = ?,
                            write_origin = 'server',
                            pending = 0
                        WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                          AND pending = 1 AND write_origin = 'local' AND local_revision = ?
                        """,
                    arguments: [
                        incoming,
                        incoming,
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        confirming
                    ]
                )
                return 0
            }
        }
    }

    /// Purges every row and cursor for one account. The account argument is
    /// mandatory so a caller can never widen the delete to the whole store.
    public func deleteAccount(_ accountUserID: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM cache_rows WHERE account_user_id = ?",
                arguments: [Self.accountIDString(accountUserID)]
            )
            try db.execute(
                sql: "DELETE FROM sync_cursors WHERE account_user_id = ?",
                arguments: [Self.accountIDString(accountUserID)]
            )
            try db.execute(
                sql: "DELETE FROM sync_boundaries WHERE account_user_id = ?",
                arguments: [Self.accountIDString(accountUserID)]
            )
        }
    }

    // MARK: - Sync cursors

    /// Upserts the sync cursor for one account + entity type.
    public func setCursor(
        _ cursor: String,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws {
        let now = Self.timestamp()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sync_cursors
                        (account_user_id, entity_type, cursor, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_user_id, entity_type) DO UPDATE SET
                        cursor = excluded.cursor,
                        updated_at = excluded.updated_at
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue, cursor, now]
            )
        }
    }

    /// Reads the sync cursor for one account + entity type, if one exists.
    public func cursor(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT cursor FROM sync_cursors
                    WHERE account_user_id = ? AND entity_type = ?
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue]
            )
        }
    }

    /// Deletes the sync cursor for one account + entity type.
    ///
    /// Used when an entity has a hard-delete path that deltas cannot observe
    /// (for example the rename-tag registry) and the next refresh must be a
    /// full reconcile instead of continuing from the previous cursor.
    public func deleteCursor(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM sync_cursors
                    WHERE account_user_id = ? AND entity_type = ?
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue]
            )
            try db.execute(
                sql: """
                    DELETE FROM sync_boundaries
                    WHERE account_user_id = ? AND entity_type = ?
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue]
            )
        }
    }

    /// Records that one account/entity completed an authoritative server sync.
    /// This is intentionally independent from `sync_cursors`: an empty server
    /// response has no updated row timestamp and therefore no cursor.
    public func markSyncComplete(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws {
        let now = Self.timestamp()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sync_boundaries
                        (account_user_id, entity_type, synced_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_user_id, entity_type) DO UPDATE SET
                        synced_at = excluded.synced_at
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue, now]
            )
        }
    }

    /// Returns whether an account/entity has crossed an authoritative sync
    /// boundary. A persisted cursor counts too for caches created before the
    /// explicit empty-result marker was introduced.
    public func hasCompletedSync(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> Bool {
        try dbQueue.read { db in
            let account = Self.accountIDString(accountUserID)
            let boundary = try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM sync_boundaries
                    WHERE account_user_id = ? AND entity_type = ?
                    LIMIT 1
                    """,
                arguments: [account, entityType.rawValue]
            )
            if boundary != nil { return true }
            let cursor = try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM sync_cursors
                    WHERE account_user_id = ? AND entity_type = ?
                    LIMIT 1
                    """,
                arguments: [account, entityType.rawValue]
            )
            return cursor != nil
        }
    }

    // MARK: - Helpers

    /// Returns whether `table` has a column named `name`. Used to make the
    /// column-adding migrations idempotent: a database whose `cache_rows`
    /// already contains the column (for example one created with the final
    /// schema folded into the CREATE TABLE) is left untouched instead of
    /// failing with a duplicate-column error.
    private static func hasColumn(_ name: String, in table: String, db: Database) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return rows.contains { ($0["name"] as String) == name }
    }

    private static func accountIDString(_ id: UUID) -> String { id.uuidString }

    /// Formats a server timestamp exactly as the store's fixed-width UTC
    /// microsecond cursor strings. Repository delta fetches use the same
    /// formatter so a cursor written by the cache round-trips through
    /// PostgREST without precision drift.
    public static func syncCursorString(from date: Date) -> String {
        timestamp(date)
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        // Postgres timestamptz carries microseconds. The store never parses
        // these values; it only compares them, so a fixed-width UTC
        // microsecond formatter keeps string ordering equal to chronological
        // ordering while preserving the full PostgreSQL precision.
        let totalMicroseconds = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let wholeSeconds = totalMicroseconds / 1_000_000
        let microseconds = totalMicroseconds % 1_000_000
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let whole = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))
        return "\(whole).\(String(format: "%06lld", microseconds))Z"
    }

    private func decode<T: Decodable>(payload: String, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(payload.utf8))
        } catch {
            throw LocalCacheError.invalidPayload
        }
    }
}
