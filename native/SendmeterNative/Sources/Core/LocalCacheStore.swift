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
/// writes are authoritative: they replace a local-origin row regardless of
/// wall-clock timestamps, and only replace an older server-origin row. The two
/// domains never compare timestamps against each other, so a device clock
/// ahead of Supabase cannot make cache reconcile permanently lose.
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
/// Every row records its `write_origin`. Local writes are optimistic and
/// always replace a cached row; server writes replace a local-origin row even
/// if the server timestamp is older than the device clock, and otherwise use
/// last-writer-wins on a microsecond-precision `updated_at`. Server deletes
/// are remembered as tombstones even for keys that have never been cached.
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
    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createLocalCacheTables") { db in
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
            try db.execute(sql: """
                ALTER TABLE cache_rows
                ADD COLUMN write_origin TEXT NOT NULL DEFAULT 'local'
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

    /// Loads one non-deleted payload for one account + entity, decoded as `T`.
    public func loadOne<T: Decodable>(
        _ type: T.Type,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws -> T? {
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
        return try payload.map { try decode(payload: $0, as: T.self) }
    }

    // MARK: - Writes

    /// Optimistically upserts one locally-produced payload for an account +
    /// entity. Local writes always replace the cached row and are marked
    /// `local`; a later server-confirmed write is authoritative and replaces
    /// them regardless of the device clock.
    public func upsertLocal<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws {
        try writePayload(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            origin: .local,
            updatedAt: Date()
        )
    }

    /// Upserts one server-confirmed payload for an account + entity.
    ///
    /// A server write replaces a local-origin row unconditionally (the server
    /// confirms the optimistic write), and replaces a server-origin row only
    /// when `updatedAt` is strictly newer. The writer must pass the entity's
    /// server `updated_at`; timestamps are microsecond-precision and compared
    /// within the server domain only.
    public func upsertServer<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date
    ) throws {
        try writePayload(
            value,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            origin: .server,
            updatedAt: updatedAt
        )
    }

    private func writePayload<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        origin: LocalCacheWriteOrigin,
        updatedAt: Date
    ) throws {
        let json = try JSONEncoder().encode(value)
        guard let payload = String(data: json, encoding: .utf8) else {
            throw LocalCacheError.invalidJSON
        }
        let incoming = Self.timestamp(updatedAt)
        try dbQueue.write { db in
            if origin == .local {
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin)
                        VALUES (?, ?, ?, ?, NULL, ?, ?)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = excluded.payload,
                            deleted_at = NULL,
                            updated_at = excluded.updated_at,
                            write_origin = excluded.write_origin
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        payload,
                        incoming,
                        origin.rawValue
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin)
                        VALUES (?, ?, ?, ?, NULL, ?, ?)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN NULL
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN excluded.write_origin
                                ELSE cache_rows.write_origin
                            END
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        payload,
                        incoming,
                        origin.rawValue
                    ]
                )
            }
        }
    }

    /// Optimistically soft-deletes one locally-produced entity for an account
    /// (hidden from reads). The tombstone is created even when the key was
    /// never cached, so a later server event must explicitly confirm a newer
    /// change before it becomes visible again.
    public func markDeletedLocal(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws {
        try writeTombstone(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            origin: .local,
            updatedAt: Date()
        )
    }

    /// Soft-deletes one server-confirmed entity for an account (hidden from
    /// reads). The tombstone is inserted when the key was never cached, so an
    /// out-of-order stale upsert cannot resurrect a server-deleted row. A
    /// server delete replaces a local-origin row and only replaces an older
    /// server-origin row.
    public func markDeletedServer(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date
    ) throws {
        try writeTombstone(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: entityID,
            origin: .server,
            updatedAt: updatedAt
        )
    }

    private func writeTombstone(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        origin: LocalCacheWriteOrigin,
        updatedAt: Date
    ) throws {
        let incoming = Self.timestamp(updatedAt)
        try dbQueue.write { db in
            if origin == .local {
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin)
                        VALUES (?, ?, ?, '{}', ?, ?, ?)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = excluded.payload,
                            deleted_at = excluded.deleted_at,
                            updated_at = excluded.updated_at,
                            write_origin = excluded.write_origin
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        incoming,
                        incoming,
                        origin.rawValue
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO cache_rows
                            (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin)
                        VALUES (?, ?, ?, '{}', ?, ?, ?)
                        ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                            payload = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN excluded.payload
                                ELSE cache_rows.payload
                            END,
                            deleted_at = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN excluded.deleted_at
                                ELSE cache_rows.deleted_at
                            END,
                            updated_at = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN excluded.updated_at
                                ELSE cache_rows.updated_at
                            END,
                            write_origin = CASE
                                WHEN cache_rows.write_origin = 'local'
                                  OR cache_rows.updated_at < excluded.updated_at
                                THEN excluded.write_origin
                                ELSE cache_rows.write_origin
                            END
                        """,
                    arguments: [
                        Self.accountIDString(accountUserID),
                        entityType.rawValue,
                        entityID,
                        incoming,
                        incoming,
                        origin.rawValue
                    ]
                )
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
