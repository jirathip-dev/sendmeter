import Foundation
@_implementationOnly import GRDB

/// #1004: one row whose raw payload was set aside because this build could not
/// decode it. `payload` is the stored bytes verbatim — the quarantine's whole
/// point is that a later build (or a support export) can still recover them.
public struct QuarantinedCacheRow: Equatable, Sendable {
    public let entityType: LocalCacheEntityType
    public let entityID: String
    public let payload: String
    public let reason: String
    public let quarantinedAt: String

    public init(
        entityType: LocalCacheEntityType,
        entityID: String,
        payload: String,
        reason: String,
        quarantinedAt: String
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.payload = payload
        self.reason = reason
        self.quarantinedAt = quarantinedAt
    }
}

/// #1004: what one repair pass did. Deliberately separates the two data-safety
/// answers a caller must be able to state out loud:
///
/// * `quarantined` — rows whose authoritative copy is on the server: the local
///   row was set aside (payload preserved) and its entity's cursor reset, so
///   the next refresh rebuilds it. Nothing was lost; the account owns the data.
/// * `preservedPending` — rows that are NOT on the server yet. These are left
///   exactly where they are. Quarantining one would destroy the only copy of a
///   real recording, which is worse than any banner.
public struct LocalCacheRepairReport: Equatable, Sendable {
    public let quarantined: [QuarantinedCacheRow]
    public let preservedPending: [LocalCacheInvalidRow]
    /// Entity types whose cursor was reset so the next refresh is a full
    /// authoritative reconcile (the heal half of quarantine).
    public let healedEntityTypes: [LocalCacheEntityType]

    public init(
        quarantined: [QuarantinedCacheRow],
        preservedPending: [LocalCacheInvalidRow],
        healedEntityTypes: [LocalCacheEntityType]
    ) {
        self.quarantined = quarantined
        self.preservedPending = preservedPending
        self.healedEntityTypes = healedEntityTypes
    }

    public static let empty = LocalCacheRepairReport(
        quarantined: [],
        preservedPending: [],
        healedEntityTypes: []
    )

    public var didQuarantine: Bool { !quarantined.isEmpty }
    public var quarantinedCount: Int { quarantined.count }
    public var preservedPendingCount: Int { preservedPending.count }
    public var didRepairAnything: Bool { didQuarantine || preservedPendingCount > 0 }

    /// The entity types one line of the launch-failure log can name.
    public var entityTypesLabel: String {
        let names = quarantined.map(\.entityType.rawValue)
        var seen: [String] = []
        for name in names where !seen.contains(name) {
            seen.append(name)
        }
        return seen.joined(separator: ",")
    }

    /// The non-blocking surface's copy. A silent no-op is exactly what this
    /// issue forbids, so the notice states both what happened to the server's
    /// copy and what happened to unsynced data.
    public var message: String {
        var parts: [String] = []
        if didQuarantine {
            let noun = quarantinedCount == 1 ? "1 saved item" : "\(quarantinedCount) saved items"
            parts.append(
                "\(noun) couldn\u{2019}t be read and \(quarantinedCount == 1 ? "was" : "were") set aside. Sendmeter is rebuilding \(quarantinedCount == 1 ? "it" : "them") from your account."
            )
        }
        if preservedPendingCount > 0 {
            let noun = preservedPendingCount == 1 ? "1 unsynced item" : "\(preservedPendingCount) unsynced items"
            parts.append("\(noun) that hasn\u{2019}t reached your account was left untouched.")
        }
        return parts.joined(separator: " ")
    }
}

extension LocalCacheStore {
    /// #1004: the quarantine reason written for an undecodable payload. A
    /// stable literal so a support export can be grouped without parsing prose.
    public static let undecodablePayloadReason = "undecodable-payload"

    /// Sets aside every given row whose payload this build could not decode.
    ///
    /// Per row, inside ONE write transaction: read the raw payload, copy it
    /// verbatim into `cache_quarantine`, then remove the row from `cache_rows`.
    /// A **pending** row is skipped entirely — never copied, never removed —
    /// because its only copy is local (a real un-uploaded recording). After a
    /// non-empty quarantine, the entity's cursor (and sync boundary) is
    /// deleted so the next refresh is a full authoritative reconcile: that is
    /// the heal.
    @discardableResult
    public func quarantineInvalidRows(
        _ rows: [LocalCacheInvalidRow],
        accountUserID: UUID,
        now: Date = Date()
    ) throws -> LocalCacheRepairReport {
        guard !rows.isEmpty else { return .empty }
        let account = Self.accountIDString(accountUserID)
        let quarantinedAt = Self.timestamp(now)
        var quarantined: [QuarantinedCacheRow] = []
        var preservedPending: [LocalCacheInvalidRow] = []
        var healed: [LocalCacheEntityType] = []
        // Stable order so a report (and a test) does not depend on dictionary
        // or set iteration.
        let entityTypes = LocalCacheEntityType.allCases.filter { entityType in
            rows.contains { $0.entityType == entityType }
        }
        for entityType in entityTypes {
            let ids = rows
                .filter { $0.entityType == entityType }
                .map(\.entityID)
            var quarantinedThisEntity = false
            try dbQueue.write { db in
                for entityID in ids {
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT payload, pending FROM cache_rows
                            WHERE account_user_id = ? AND entity_type = ?
                              AND entity_id = ? AND deleted_at IS NULL
                            """,
                        arguments: [account, entityType.rawValue, entityID]
                    )
                    guard let row else { continue }
                    let payload = row["payload"] as String
                    let isPending = (row["pending"] as Int) == 1
                    if isPending {
                        preservedPending.append(
                            LocalCacheInvalidRow(
                                entityType: entityType,
                                entityID: entityID,
                                isPending: true
                            )
                        )
                        continue
                    }
                    try db.execute(
                        sql: """
                            INSERT INTO cache_quarantine
                                (account_user_id, entity_type, entity_id, payload,
                                 reason, quarantined_at)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            account,
                            entityType.rawValue,
                            entityID,
                            payload,
                            Self.undecodablePayloadReason,
                            quarantinedAt
                        ]
                    )
                    try db.execute(
                        sql: """
                            DELETE FROM cache_rows
                            WHERE account_user_id = ? AND entity_type = ? AND entity_id = ?
                            """,
                        arguments: [account, entityType.rawValue, entityID]
                    )
                    quarantined.append(
                        QuarantinedCacheRow(
                            entityType: entityType,
                            entityID: entityID,
                            payload: payload,
                            reason: Self.undecodablePayloadReason,
                            quarantinedAt: quarantinedAt
                        )
                    )
                    quarantinedThisEntity = true
                }
            }
            if quarantinedThisEntity {
                // The heal: a nil cursor makes the next fetch a full snapshot
                // for this entity, so the rows just removed come back from the
                // server instead of waiting for an update that never comes.
                try deleteCursor(accountUserID: accountUserID, entityType: entityType)
                healed.append(entityType)
            }
        }
        return LocalCacheRepairReport(
            quarantined: quarantined,
            preservedPending: preservedPending,
            healedEntityTypes: healed
        )
    }

    /// The quarantined payloads for one account, newest last. Evidence and a
    /// future build's recovery path both read here; nothing else writes or
    /// deletes quarantine rows.
    public func quarantinedRows(accountUserID: UUID) throws -> [QuarantinedCacheRow] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT entity_type, entity_id, payload, reason, quarantined_at
                    FROM cache_quarantine
                    WHERE account_user_id = ?
                    ORDER BY quarantined_at, entity_type, entity_id
                    """,
                arguments: [Self.accountIDString(accountUserID)]
            ).compactMap { row in
                guard
                    let entityType = LocalCacheEntityType(rawValue: row["entity_type"] as String)
                else { return nil }
                return QuarantinedCacheRow(
                    entityType: entityType,
                    entityID: row["entity_id"] as String,
                    payload: row["payload"] as String,
                    reason: row["reason"] as String,
                    quarantinedAt: row["quarantined_at"] as String
                )
            }
        }
    }
}
