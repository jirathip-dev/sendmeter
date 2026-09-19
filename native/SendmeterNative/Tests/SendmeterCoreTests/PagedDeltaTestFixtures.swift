import Foundation
@testable import SendmeterCore

/// One row of a deterministic capped-response fixture (#914/#915).
///
/// The fixture is column-agnostic: `fixtureKey` is the row's value in the
/// pager's tie-break column (a UUID string for the delta tables, a `date` or a
/// tag `name` for an entity whose identity is not a uuid) and
/// `fixtureStamp`/`fixtureOrderingInstant` are its ordering timestamp
/// (`updated_at` for every delta table, `started_at` for the workout attempt
/// collection).
protocol CappedDeltaFixtureRow: Sendable {
    /// The row's value in the server's tie-break column.
    var fixtureKey: String { get }
    /// The fixed-width ordering stamp the cursor persists.
    var fixtureStamp: String { get }
    /// The ordering timestamp itself.
    var fixtureOrderingInstant: Date { get }
    /// Whether the row is an explicit tombstone.
    var fixtureDeleted: Bool { get }
}

/// One row of the deterministic capped-response fixture (#914).
struct StubDeltaRow: Sendable, Equatable, CappedDeltaFixtureRow {
    let uuid: UUID
    let updatedAt: Date
    let deleted: Bool
    let note: String

    var id: String { uuid.uuidString }
    var stamp: String { LocalCacheStore.syncCursorString(from: updatedAt) }

    var fixtureKey: String { id }
    var fixtureStamp: String { stamp }
    var fixtureOrderingInstant: Date { updatedAt }
    var fixtureDeleted: Bool { deleted }
}

/// Stable fixture identities: `...0001`, `...0002`, ... so id ordering and the
/// order the reader reads them in agree.
func stubUUID(_ n: Int) -> UUID {
    var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    bytes.15 = UInt8(n)
    return UUID(uuid: bytes)
}

/// The fixture's time base. Whole seconds keep the fixture independent of any
/// timestamp formatter's fractional-second behavior.
let stubEpoch = Date(timeIntervalSince1970: 1_760_000_000)

func stubDate(_ seconds: Double) -> Date {
    stubEpoch.addingTimeInterval(seconds)
}

/// A deterministic PostgREST-shaped pager for the paged delta reader.
///
/// It honours exactly the query the reader sends — `order`, `limit`, and the
/// cursor filter (`or=(<timestamp>.gt.<stamp>,and(<timestamp>.eq.<stamp>,<tie-break>.gt.<id>))`
/// for a composite cursor, `<timestamp>=gte.<stamp>` for a legacy one) — and
/// caps every response at `cap` rows, mirroring a deployed response cap.
/// `timestampColumn`/`tieBreakColumn` are the columns the reader was
/// configured with, so one fixture serves every entity shape (#915).
/// `totalCount` mirrors the `Content-Range` total the transport reports under
/// `Prefer: count=exact`. A malformed query throws rather than answering, so a
/// broken query contract fails the test instead of passing silently — except
/// `<timestamp>=gt.<stamp>`, which PostgREST accepts (and which the pre-#915
/// timestamp-only reader sent) and which the fixture therefore models as the
/// real thing: the rest of the checkpoint's tie group is skipped.
final class CappedDeltaServer<Row: CappedDeltaFixtureRow> {
    enum Filter: Equatable {
        case none
        case legacy(stamp: String)
        case timestampOnly(stamp: String)
        case composite(stamp: String, entityID: String)

        func includes(_ row: Row) -> Bool {
            switch self {
            case .none:
                return true
            case .legacy(let stamp):
                return row.fixtureStamp >= stamp
            case .timestampOnly(let stamp):
                return row.fixtureStamp > stamp
            case .composite(let stamp, let entityID):
                return row.fixtureStamp > stamp
                    || (row.fixtureStamp == stamp && row.fixtureKey > entityID)
            }
        }
    }

    struct Request: Equatable {
        let order: String
        let limit: String
        let filter: Filter
    }

    enum FixtureError: Error, Equatable {
        case malformedFilter(String)
    }

    private(set) var rows: [Row]
    private(set) var requests: [Request] = []
    private(set) var servedPages = 0
    /// Every row key the fixture has served, in order (a duplicate appears
    /// twice), so a test can prove a retry really was re-served.
    private(set) var servedIDs: [String] = []

    let cap: Int
    /// The column the reader asked the server to order by (`updated_at` unless
    /// the entity's ordering timestamp is something else).
    let timestampColumn: String
    /// The column whose per-row value is the page tie-break (`id`, `user_id`,
    /// `date`, `name`).
    let tieBreakColumn: String
    /// Throws on the Nth page request (1-based): the mid-page failure.
    var failOnPage: Int?
    /// Reverses the Nth page's rows: the out-of-order server.
    var misorderOnPage: Int?
    /// Applies `mutate` after the Nth page is served: a duplicate retry (the
    /// row is updated again while the client pages, so it is served twice).
    var mutateAfterPage: Int?
    var mutate: ((inout [Row]) -> Void)?

    init(
        rows: [Row],
        cap: Int,
        timestampColumn: String = "updated_at",
        tieBreakColumn: String = "id"
    ) {
        self.rows = rows
        self.cap = cap
        self.timestampColumn = timestampColumn
        self.tieBreakColumn = tieBreakColumn
    }

    func page(for request: DeltaPageRequest) throws -> DeltaPageResponse<Row> {
        let parsed = try parse(request)
        requests.append(parsed)
        servedPages += 1
        if failOnPage == servedPages {
            throw URLError(.networkConnectionLost)
        }
        let matching = rows
            .filter { parsed.filter.includes($0) }
            .sorted { ($0.fixtureStamp, $0.fixtureKey) < ($1.fixtureStamp, $1.fixtureKey) }
        let limit = max(1, Int(parsed.limit) ?? cap)
        var window = Array(matching.prefix(min(cap, limit)))
        if misorderOnPage == servedPages {
            window.reverse()
        }
        if mutateAfterPage == servedPages {
            mutate?(&rows)
        }
        servedIDs.append(contentsOf: window.map(\.fixtureKey))
        return DeltaPageResponse(rows: window, totalCount: matching.count)
    }

    private func parse(_ request: DeltaPageRequest) throws -> Request {
        let items = request.queryItems
        let order = items.first { $0.name == "order" }?.value ?? ""
        let limit = items.first { $0.name == "limit" }?.value ?? ""
        let filter: Filter
        if let composite = items.first(where: { $0.name == "or" })?.value {
            filter = try parseComposite(composite)
        } else if let legacy = items.first(where: { $0.name == timestampColumn })?.value {
            if legacy.hasPrefix("gte.") {
                filter = .legacy(stamp: try Self.value(of: legacy, dropping: "gte."))
            } else {
                filter = .timestampOnly(stamp: try Self.value(of: legacy, dropping: "gt."))
            }
        } else {
            filter = .none
        }
        return Request(order: order, limit: limit, filter: filter)
    }

    private func parseComposite(_ raw: String) throws -> Filter {
        guard raw.hasPrefix("("), raw.hasSuffix(")") else {
            throw FixtureError.malformedFilter(raw)
        }
        let inner = String(raw.dropFirst().dropLast())
        guard let andRange = inner.range(of: ",and(") else {
            throw FixtureError.malformedFilter(raw)
        }
        let greater = String(inner[..<andRange.lowerBound])
        var nested = String(inner[andRange.upperBound...])
        guard nested.hasSuffix(")") else { throw FixtureError.malformedFilter(raw) }
        nested = String(nested.dropLast())
        let parts = nested.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { throw FixtureError.malformedFilter(raw) }
        let stamp = try Self.value(of: greater, dropping: "\(timestampColumn).gt.")
        guard String(parts[0]) == "\(timestampColumn).eq.\(stamp)" else {
            throw FixtureError.malformedFilter(raw)
        }
        return .composite(
            stamp: stamp,
            entityID: try Self.value(of: String(parts[1]), dropping: "\(tieBreakColumn).gt.")
        )
    }

    private static func value(of item: String, dropping prefix: String) throws -> String {
        guard item.hasPrefix(prefix) else { throw FixtureError.malformedFilter(item) }
        return String(item.dropFirst(prefix.count))
    }
}

/// Drives the production reader over the fixture pager with the sessions
/// entity's shape (entity id = row `id`, tombstone = `deleted`).
enum PagedSessionReader {
    static func read(
        server: CappedDeltaServer<StubDeltaRow>,
        accountUserID: UUID,
        since cursor: String?,
        pageSize: Int = 2,
        pageLimit: Int = DeltaPageReader<StubDeltaRow, Session>.defaultPageLimit
    ) async throws -> RemoteEntityDelta<Session> {
        let reader = DeltaPageReader<StubDeltaRow, Session>(
            select: "id,date,type,updated_at,deleted_at",
            pageSize: pageSize,
            pageLimit: pageLimit,
            entityID: { $0.id },
            value: { row in
                Session(
                    id: row.uuid,
                    date: row.note,
                    type: "hangboard",
                    typeLabel: "Hangboard",
                    durationMinutes: 30,
                    rpe: 7,
                    phase: .strength,
                    accountUserID: accountUserID
                )
            },
            isDeleted: { $0.deleted },
            updatedAt: { $0.updatedAt }
        )
        return try await reader.read(since: cursor) { request in
            try server.page(for: request)
        }
    }
}
