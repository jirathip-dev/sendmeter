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
public enum LocalCacheEntityType: String, Codable, CaseIterable, Sendable {
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
/// it pending and bumping `local_revision` until the server confirms. A server
/// **refresh** (`upsertServer`/`markDeletedServer`) never reverts a pending
/// local action — it only replaces non-pending local-origin rows and otherwise
/// uses last-writer-wins on a microsecond-precision `updated_at`. A server
/// **confirmation** (`confirmServerUpsert`/`confirmServerDelete`) applies the
/// server's post-upload state and clears pending only when the row's stored
/// `local_revision` still equals the revision that was uploaded; slice 2+
/// calls this after the DurableQueue successfully uploads. Server deletes are
/// remembered as tombstones even for keys that have never been cached.
///
/// The schema also has a per-account `sync_cursors` table so later slices can
/// implement incremental reconcile per entity type. `deleteAccount` purges
/// both data rows and cursors for the account.
///
/// The store is `@unchecked Sendable` because GRDB's `DatabaseQueue` is
/// documented as thread-safe; callers may share one store across queues or
/// actors.
public struct LocalCacheStore: @unchecked Sendable {
    let dbQueue: DatabaseQueue

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
    ///   the revision that was uploaded. Only slice 2+ calls this after
    ///   `DurableQueue` upload.
    private enum CacheWriteMode {
        case local
        case serverRefresh
        case serverConfirm
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrate(dbQueue)
    }

    /// File-backed store at `databaseURL`.
    public init(databaseURL: URL) throws {
        try self.init(dbQueue: DatabaseQueue(path: databaseURL.path))
    }

    /// In-memory store for tests and one-off scratch databases.
    public init() throws {
        try self.init(dbQueue: DatabaseQueue())
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
            // upload. `local_revision` is 0 for confirmed/clean rows and
            // monotonically increases across a row's unconfirmed local edits.
            let hasRevision = try Self.hasColumn("local_revision", in: "cache_rows", db: db)
            if !hasRevision {
                try db.execute(sql: """
                    ALTER TABLE cache_rows
                    ADD COLUMN local_revision INTEGER NOT NULL DEFAULT 0
                    """)
            }
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
    /// its `pending` flag intact.
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
    /// row is `pending`, the incoming payload is dropped and its
    /// `local_revision` is preserved. Otherwise a server write replaces a
    /// non-pending local-origin row regardless of clock (resetting
    /// `local_revision` to 0) and replaces a server-origin row only when
    /// `updatedAt` is strictly newer (also resetting `local_revision` to 0).
    /// The writer must pass the entity's server `updated_at`; timestamps are
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
                                WHEN cache_rows.pending = 1 THEN cache_rows.payload
                                WHEN cache_rows.write_origin = 'local' THEN excluded.payload
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.deleted_at
                                WHEN cache_rows.write_origin = 'local' THEN NULL
                                WHEN cache_rows.updated_at < excluded.updated_at THEN NULL
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.updated_at
                                WHEN cache_rows.write_origin = 'local' THEN excluded.updated_at
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.write_origin
                                WHEN cache_rows.write_origin = 'local' THEN 'server'
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 'server'
                                ELSE cache_rows.write_origin
                            END,
                            pending = CASE
                                WHEN cache_rows.pending = 1 THEN 1
                                WHEN cache_rows.write_origin = 'local' THEN 0
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 0
                                ELSE cache_rows.pending
                            END,
                            local_revision = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.local_revision
                                WHEN cache_rows.write_origin = 'local' THEN 0
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 0
                                ELSE cache_rows.local_revision
                            END
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
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                        VALUES (?, ?, ?, ?, NULL, ?, 'server', 0, 0)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN NULL
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN 'server'
                                ELSE cache_rows.write_origin
                            END,
                            pending = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN 0
                                ELSE cache_rows.pending
                            END,
                            local_revision = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN 0
                                ELSE cache_rows.local_revision
                            END
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        payload,
                        incoming,
                        confirming,
                        confirming,
                        confirming,
                        confirming,
                        confirming,
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
    /// flag intact.
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
    /// A refresh delete never reverts a pending local action: if the cached row
    /// is `pending`, the incoming tombstone is dropped and its `local_revision`
    /// is preserved. Otherwise it inserts a tombstone even when the key was
    /// never cached (so an out-of-order stale upsert cannot resurrect a
    /// server-deleted row), replaces a non-pending local-origin row (resetting
    /// `local_revision` to 0), and only replaces an older server-origin row
    /// (also resetting `local_revision` to 0). Use `confirmServerDelete` for
    /// the post-upload ack instead.
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
                                WHEN cache_rows.pending = 1 THEN cache_rows.payload
                                WHEN cache_rows.write_origin = 'local' THEN excluded.payload
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.deleted_at
                                WHEN cache_rows.write_origin = 'local' THEN excluded.deleted_at
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.deleted_at
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.updated_at
                                WHEN cache_rows.write_origin = 'local' THEN excluded.updated_at
                                WHEN cache_rows.updated_at < excluded.updated_at THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.write_origin
                                WHEN cache_rows.write_origin = 'local' THEN 'server'
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 'server'
                                ELSE cache_rows.write_origin
                            END,
                            pending = CASE
                                WHEN cache_rows.pending = 1 THEN 1
                                WHEN cache_rows.write_origin = 'local' THEN 0
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 0
                                ELSE cache_rows.pending
                            END,
                            local_revision = CASE
                                WHEN cache_rows.pending = 1 THEN cache_rows.local_revision
                                WHEN cache_rows.write_origin = 'local' THEN 0
                                WHEN cache_rows.updated_at < excluded.updated_at THEN 0
                                ELSE cache_rows.local_revision
                            END
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
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                        VALUES (?, ?, ?, '{}', ?, ?, 'server', 0, 0)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN excluded.deleted_at
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN 'server'
                                ELSE cache_rows.write_origin
                            END,
                            pending = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN 0
                                ELSE cache_rows.pending
                            END,
                            local_revision = CASE
                                WHEN cache_rows.pending = 1 AND cache_rows.local_revision = ? THEN 0
                                ELSE cache_rows.local_revision
                            END
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        incoming,
                        incoming,
                        confirming,
                        confirming,
                        confirming,
                        confirming,
                        confirming,
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
