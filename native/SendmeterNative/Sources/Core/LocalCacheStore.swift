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

/// Errors surfaced by `LocalCacheStore` beyond GRDB's own `DatabaseError`.
public enum LocalCacheError: Error, Equatable, Sendable {
    /// A Codable value could not be encoded to a UTF-8 JSON payload.
    case invalidJSON
    /// A stored payload could not be decoded back into the requested type.
    case invalidPayload
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
        try migrator.migrate(dbQueue)
    }

    // MARK: - Reads

    /// Loads every non-deleted payload for one account + entity type,
    /// decoded as `T`.
    public func loadAll<T: Decodable>(
        _ type: T.Type,
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) throws -> [T] {
        let payloads: [String] = try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT payload FROM cache_rows
                    WHERE account_user_id = ? AND entity_type = ? AND deleted_at IS NULL
                    ORDER BY entity_id
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue]
            )
        }
        // A single malformed/version-mismatched payload must not poison the
        // whole cache read. Successful rows still return; the invalid row is
        // left in place so a later refresh can replace it.
        return payloads.compactMap { try? decode(payload: $0, as: T.self) }
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

    /// Upserts one payload for an account + entity. Replacing an existing row
    /// clears any prior soft-delete tombstone, so a fresh server payload is
    /// visible again.
    ///
    /// `updatedAt` is the optional caller-provided version for last-write-wins.
    /// When omitted, the write is treated as a local optimistic write and
    /// always replaces the row. Remote reconciles must pass the entity's server
    /// `updated_at`; writes older than the row already in the store are then
    /// ignored, so a stale remote event cannot resurrect a newer local
    /// tombstone or overwrite a newer save.
    public func upsert<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date? = nil
    ) throws {
        let json = try JSONEncoder().encode(value)
        guard let payload = String(data: json, encoding: .utf8) else {
            throw LocalCacheError.invalidJSON
        }
        let incoming = updatedAt.map { Self.timestamp($0) }
        let now = Self.timestamp()
        try dbQueue.write { db in
            if let incoming {
                let existing = try String.fetchOne(
                    db,
                    sql: """
                        SELECT updated_at FROM cache_rows
                        WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                        """,
                    arguments: [Self.accountIDString(accountUserID), entityType.rawValue, entityID]
                )
                guard existing == nil || existing! < incoming else { return }
            }
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at)
                    VALUES (?, ?, ?, ?, NULL, ?)
                    ON CONFLICT(account_user_id, entity_type, entity_id) DO UPDATE SET
                        payload = excluded.payload,
                        deleted_at = NULL,
                        updated_at = excluded.updated_at
                    """,
                arguments: [Self.accountIDString(accountUserID), entityType.rawValue, entityID, payload, incoming ?? now]
            )
        }
    }

    /// Soft-deletes one entity for an account (hidden from reads). A later
    /// `upsert` for the same key clears the tombstone; a stale delete is ignored.
    public func markDeleted(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date? = nil
    ) throws {
        let now = Self.timestamp()
        try dbQueue.write { db in
            if let updatedAt {
                let incoming = Self.timestamp(updatedAt)
                try db.execute(
                    sql: """
                        UPDATE cache_rows
                        SET deleted_at = ?, updated_at = ?
                        WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                          AND updated_at < ?
                        """,
                    arguments: [incoming, incoming, Self.accountIDString(accountUserID), entityType.rawValue, entityID, incoming]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE cache_rows
                        SET deleted_at = ?, updated_at = ?
                        WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                        """,
                    arguments: [now, now, Self.accountIDString(accountUserID), entityType.rawValue, entityID]
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func decode<T: Decodable>(payload: String, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(payload.utf8))
        } catch {
            throw LocalCacheError.invalidPayload
        }
    }
}
