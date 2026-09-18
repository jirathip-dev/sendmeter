import Foundation

/// A persisted delta checkpoint: the `(updated_at, entity id)` pair a paged
/// delta read last completed at (#914).
///
/// Cursor format
/// -------------
/// - Composite (current): `<timestamp>|<entity-id>`, e.g.
///   `2026-09-19T10:00:00.123456Z|8f3e...`. `<timestamp>` is exactly
///   `LocalCacheStore.syncCursorString(from:)` — fixed-width UTC microseconds,
///   so text ordering equals chronological ordering — and `<entity-id>` is the
///   stable cache entity id of the last row the read consumed.
/// - Legacy (pre-#914): a bare `<timestamp>` with no separator. It carries no
///   tie-break, so the next read re-fetches the whole tie group at that
///   timestamp (`updated_at >= cursor`) instead of skipping the rest of it.
///   Re-reading is safe: a delta upsert is keyed by entity id, so a row read
///   twice still reconciles once.
///
/// A string that is neither form parses to `nil`, which the reader treats as
/// "no cursor" — a full re-read, never a partial one.
public struct DeltaCursor: Equatable, Sendable {
    /// Microseconds since the epoch: the precision Postgres timestamps and the
    /// persisted cursor both carry, so ordering never depends on Double
    /// round-tripping.
    public let microseconds: Int64
    /// The exact fixed-width timestamp text used in queries and persistence.
    public let stamp: String
    /// `nil` for a legacy timestamp-only cursor.
    public let entityID: String?

    public init(microseconds: Int64, stamp: String, entityID: String?) {
        self.microseconds = microseconds
        self.stamp = stamp
        self.entityID = entityID
    }

    public init(updatedAt: Date, entityID: String?) {
        self.init(
            microseconds: Self.microseconds(of: updatedAt),
            stamp: LocalCacheStore.syncCursorString(from: updatedAt),
            entityID: entityID
        )
    }

    /// The persisted form: `stamp` alone for a legacy cursor, `stamp|id` once
    /// a composite checkpoint exists.
    public var persisted: String {
        guard let entityID else { return stamp }
        return "\(stamp)|\(entityID)"
    }

    /// Ordering key of the server's `(updated_at, id)` ordering. A legacy
    /// cursor has no id, so it sorts before every real id at the same stamp.
    var orderingKey: (microseconds: Int64, entityID: String) {
        (microseconds, entityID ?? "")
    }

    public static func microseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// Parses a persisted cursor. Timestamp-only strings keep their raw text as
    /// `stamp` so a re-issued query is byte-identical to the stored value.
    public static func parse(_ raw: String) -> DeltaCursor? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let separator = trimmed.firstIndex(of: "|") else {
            guard let microseconds = microseconds(fromStamp: trimmed) else { return nil }
            return DeltaCursor(microseconds: microseconds, stamp: trimmed, entityID: nil)
        }
        let stamp = String(trimmed[..<separator])
        let entityID = String(trimmed[trimmed.index(after: separator)...])
        guard !stamp.isEmpty, !entityID.isEmpty,
              let microseconds = microseconds(fromStamp: stamp)
        else { return nil }
        return DeltaCursor(microseconds: microseconds, stamp: stamp, entityID: entityID)
    }

    private static func microseconds(fromStamp stamp: String) -> Int64? {
        if let date = fixedWidthFormatter.date(from: stamp) {
            return microseconds(of: date)
        }
        guard let date = LocalDateSupport.iso8601Date(from: stamp) else { return nil }
        return microseconds(of: date)
    }

    private static let fixedWidthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return formatter
    }()
}

/// The PostgREST query for one page of a `(<timestamp>, <tie-break>)`-ordered
/// read.
///
/// Delta tables order by `updated_at`; a collection that carries its own
/// ordering timestamp (the workout attempt collection, `started_at`) passes
/// `timestampColumn` so the same reader pages both shapes without a second
/// cursor scheme (#915).
public enum DeltaPageQuery {
    /// Fixed `select`, deterministic composite ordering, one bounded `limit`,
    /// and the cursor filter:
    ///
    /// - no cursor: no filter (first sync).
    /// - composite cursor: `or=(<timestamp>.gt.<stamp>,and(<timestamp>.eq.<stamp>,<tie-break>.gt.<id>))`
    ///   — strictly greater on the pair, so a page boundary can fall inside a
    ///   timestamp tie group without skipping the rest of it.
    /// - legacy cursor: `<timestamp>=gte.<stamp>` — includes the whole tie
    ///   group at the stamp so nothing the old cursor could not tie-break is
    ///   skipped.
    public static func queryItems(
        select: String,
        tieBreakColumn: String,
        cursor: DeltaCursor?,
        pageSize: Int,
        timestampColumn: String = "updated_at"
    ) -> [URLQueryItem] {
        var queryItems = [
            URLQueryItem(name: "select", value: select),
            URLQueryItem(name: "order", value: "\(timestampColumn).asc,\(tieBreakColumn).asc"),
            URLQueryItem(name: "limit", value: String(max(1, pageSize)))
        ]
        guard let cursor else { return queryItems }
        if let entityID = cursor.entityID {
            queryItems.append(URLQueryItem(
                name: "or",
                value: "(\(timestampColumn).gt.\(cursor.stamp),and(\(timestampColumn).eq.\(cursor.stamp),\(tieBreakColumn).gt.\(entityID)))"
            ))
        } else {
            queryItems.append(URLQueryItem(name: timestampColumn, value: "gte.\(cursor.stamp)"))
        }
        return queryItems
    }
}

/// One page request handed to the transport seam.
public struct DeltaPageRequest: Equatable, Sendable {
    public let queryItems: [URLQueryItem]
    public let pageSize: Int
}

/// One transport page: rows in the requested order plus the server's reported
/// total when it sent one (`Content-Range`).
public struct DeltaPageResponse<Row> {
    public let rows: [Row]
    /// Rows matching the filter as reported by the server. `nil` means the
    /// server did not say; the reader then treats a page shorter than
    /// `pageSize` as the final page.
    public let totalCount: Int?

    public init(rows: [Row], totalCount: Int?) {
        self.rows = rows
        self.totalCount = totalCount
    }
}

public enum DeltaReadError: Error, Equatable {
    /// The per-run page budget ran out before the read reached its end. The
    /// caller keeps its previous checkpoint and retries later; a truncated
    /// read is never reported as complete.
    case pageBudgetExhausted(pageLimit: Int)
    /// A page was not in the requested `(updated_at, id)` order.
    case outOfOrderPage
    /// A page did not move the composite cursor forward, so paging could not
    /// terminate without skipping rows.
    case cursorDidNotAdvance
}

/// One reusable bounded delta reader (#914).
///
/// It consumes every page of a `(<timestamp>, <tie-break>)`-ordered PostgREST
/// response through an injected page fetch, so the same reader serves any
/// entity — and, since #915, any ordered collection whose ordering timestamp
/// is not `updated_at` (`timestampColumn`) and whose page tie-break is not the
/// row's cache identity (`tieBreakID`) — and is unit-testable without a live
/// transport.
///
/// Contract:
/// - **Order**: the server must return rows in `(<timestamp>, <tie-break>)`
///   order; the reader fails closed (`outOfOrderPage`) instead of advancing a
///   cursor it cannot trust.
/// - **Pages**: it keeps requesting while the page came back full
///   (`rows.count == pageSize`) or the server's reported total for that page
///   exceeds what it delivered (`rows.count < totalCount`), so a server row cap
///   below the requested page size cannot silently end a read.
/// - **Exactly once logically**: rows are merged by entity id, last write
///   wins, so a duplicate retry (a row re-served after an update) reconciles
///   once.
/// - **Failure**: any page error propagates and no delta is returned, so a
///   partial read can never be reconciled as an authoritative snapshot or
///   advance a durable checkpoint.
/// - **Bounds**: one request is capped at `pageSize` rows and one run at
///   `pageLimit` pages; exhausting the budget throws rather than truncating.
public struct DeltaPageReader<Row: Sendable, Value: Sendable>: Sendable {
    public static var defaultPageSize: Int { 500 }
    public static var defaultPageLimit: Int { 64 }

    public let select: String
    public let tieBreakColumn: String
    /// The column carrying the ordering timestamp: `updated_at` for every
    /// delta table, `started_at` for the workout attempt collection.
    public let timestampColumn: String
    public let pageSize: Int
    public let pageLimit: Int
    public let entityID: @Sendable (Row) -> String
    /// The row's value in `tieBreakColumn`. It is `entityID` unless an entity's
    /// cache identity is not its database tie-break (`user_settings` is cached
    /// under one constant id while its row tie-break is `user_id`).
    public let tieBreakID: @Sendable (Row) -> String
    public let value: @Sendable (Row) -> Value
    public let isDeleted: @Sendable (Row) -> Bool
    public let updatedAt: @Sendable (Row) -> Date

    public init(
        select: String,
        tieBreakColumn: String = "id",
        timestampColumn: String = "updated_at",
        pageSize: Int = DeltaPageReader.defaultPageSize,
        pageLimit: Int = DeltaPageReader.defaultPageLimit,
        entityID: @escaping @Sendable (Row) -> String,
        tieBreakID: (@Sendable (Row) -> String)? = nil,
        value: @escaping @Sendable (Row) -> Value,
        isDeleted: @escaping @Sendable (Row) -> Bool,
        updatedAt: @escaping @Sendable (Row) -> Date
    ) {
        self.select = select
        self.tieBreakColumn = tieBreakColumn
        self.timestampColumn = timestampColumn
        self.pageSize = max(1, pageSize)
        self.pageLimit = max(1, pageLimit)
        self.entityID = entityID
        self.tieBreakID = tieBreakID ?? entityID
        self.value = value
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }

    public func read(
        since persistedCursor: String?,
        fetch: (DeltaPageRequest) async throws -> DeltaPageResponse<Row>
    ) async throws -> RemoteEntityDelta<Value> {
        var cursor = persistedCursor.flatMap(DeltaCursor.parse)
        var changes: [RemoteEntityChange<Value>] = []
        var positions: [String: Int] = [:]
        var pages = 0

        while true {
            guard pages < pageLimit else {
                throw DeltaReadError.pageBudgetExhausted(pageLimit: pageLimit)
            }
            pages += 1
            let page = try await fetch(DeltaPageRequest(
                queryItems: DeltaPageQuery.queryItems(
                    select: select,
                    tieBreakColumn: tieBreakColumn,
                    cursor: cursor,
                    pageSize: pageSize,
                    timestampColumn: timestampColumn
                ),
                pageSize: pageSize
            ))
            let rows = page.rows
            guard !rows.isEmpty else { break }
            try validateOrder(rows, after: cursor)
            for row in rows {
                let id = entityID(row)
                let change = RemoteEntityChange(
                    entityID: id,
                    value: isDeleted(row) ? nil : value(row),
                    updatedAt: updatedAt(row)
                )
                if let position = positions[id] {
                    changes[position] = change
                } else {
                    positions[id] = changes.count
                    changes.append(change)
                }
            }
            cursor = try advance(from: cursor, over: rows)
            let moreByTotal = page.totalCount.map { rows.count < $0 } ?? false
            if !moreByTotal && rows.count < pageSize { break }
        }

        return RemoteEntityDelta(
            changes: changes,
            activeValues: changes.compactMap { $0.value },
            cursor: cursor?.persisted
        )
    }

    /// Rows must never go backwards relative to the cursor that requested them,
    /// nor within their own page.
    private func validateOrder(_ rows: [Row], after cursor: DeltaCursor?) throws {
        var previous = cursor?.orderingKey
        for row in rows {
            let current = (DeltaCursor.microseconds(of: updatedAt(row)), tieBreakID(row))
            if let previous {
                if current.0 < previous.microseconds { throw DeltaReadError.outOfOrderPage }
                if current.0 == previous.microseconds, current.1 < previous.entityID {
                    throw DeltaReadError.outOfOrderPage
                }
            }
            previous = current
        }
    }

    /// The new checkpoint is the last row of the page — the only row the
    /// `> (<timestamp>, <tie-break>)` filter is guaranteed to have passed. A
    /// page whose rows all carry an unusable stamp (the delta tables declare
    /// `updated_at` NOT NULL, so this is a broken server) fails closed.
    private func advance(from cursor: DeltaCursor?, over rows: [Row]) throws -> DeltaCursor? {
        guard let last = rows.last(where: { updatedAt($0) > .distantPast }) else {
            throw DeltaReadError.cursorDidNotAdvance
        }
        let next = DeltaCursor(updatedAt: updatedAt(last), entityID: tieBreakID(last))
        if let cursor, next.orderingKey <= cursor.orderingKey {
            throw DeltaReadError.cursorDidNotAdvance
        }
        return next
    }
}
