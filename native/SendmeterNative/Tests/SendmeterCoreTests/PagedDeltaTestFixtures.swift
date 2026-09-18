import Foundation
@testable import SendmeterCore

/// One row of the deterministic capped-response fixture (#914).
struct StubDeltaRow: Sendable, Equatable {
    let uuid: UUID
    let updatedAt: Date
    let deleted: Bool
    let note: String

    var id: String { uuid.uuidString }
    var stamp: String { LocalCacheStore.syncCursorString(from: updatedAt) }
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
/// cursor filter (`or=(updated_at.gt.<stamp>,and(updated_at.eq.<stamp>,id.gt.<id>))`
/// for a composite cursor, `updated_at=gte.<stamp>` for a legacy one) — and
/// caps every response at `cap` rows, mirroring a deployed response cap.
/// `totalCount` mirrors the `Content-Range` total the transport reports under
/// `Prefer: count=exact`. A malformed query throws rather than answering, so a
/// broken query contract fails the test instead of passing silently.
final class CappedDeltaServer {
    enum Filter: Equatable {
        case none
        case legacy(stamp: String)
        case composite(stamp: String, entityID: String)

        func includes(_ row: StubDeltaRow) -> Bool {
            switch self {
            case .none:
                return true
            case .legacy(let stamp):
                return row.stamp >= stamp
            case .composite(let stamp, let entityID):
                return row.stamp > stamp || (row.stamp == stamp && row.id > entityID)
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

    private(set) var rows: [StubDeltaRow]
    private(set) var requests: [Request] = []
    private(set) var servedPages = 0
    /// Every row id the fixture has served, in order (a duplicate appears
    /// twice), so a test can prove a retry really was re-served.
    private(set) var servedIDs: [String] = []

    let cap: Int
    /// Throws on the Nth page request (1-based): the mid-page failure.
    var failOnPage: Int?
    /// Reverses the Nth page's rows: the out-of-order server.
    var misorderOnPage: Int?
    /// Applies `mutate` after the Nth page is served: a duplicate retry (the
    /// row is updated again while the client pages, so it is served twice).
    var mutateAfterPage: Int?
    var mutate: ((inout [StubDeltaRow]) -> Void)?

    init(rows: [StubDeltaRow], cap: Int) {
        self.rows = rows
        self.cap = cap
    }

    func page(for request: DeltaPageRequest) throws -> DeltaPageResponse<StubDeltaRow> {
        let parsed = try Self.parse(request)
        requests.append(parsed)
        servedPages += 1
        if failOnPage == servedPages {
            throw URLError(.networkConnectionLost)
        }
        let matching = rows
            .filter { parsed.filter.includes($0) }
            .sorted { ($0.stamp, $0.id) < ($1.stamp, $1.id) }
        let limit = max(1, Int(parsed.limit) ?? cap)
        var window = Array(matching.prefix(min(cap, limit)))
        if misorderOnPage == servedPages {
            window.reverse()
        }
        if mutateAfterPage == servedPages {
            mutate?(&rows)
        }
        servedIDs.append(contentsOf: window.map(\.id))
        return DeltaPageResponse(rows: window, totalCount: matching.count)
    }

    private static func parse(_ request: DeltaPageRequest) throws -> Request {
        let items = request.queryItems
        let order = items.first { $0.name == "order" }?.value ?? ""
        let limit = items.first { $0.name == "limit" }?.value ?? ""
        let filter: Filter
        if let composite = items.first(where: { $0.name == "or" })?.value {
            filter = try parseComposite(composite)
        } else if let legacy = items.first(where: { $0.name == "updated_at" })?.value {
            filter = .legacy(stamp: try value(of: legacy, dropping: "gte."))
        } else {
            filter = .none
        }
        return Request(order: order, limit: limit, filter: filter)
    }

    private static func parseComposite(_ raw: String) throws -> Filter {
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
        let stamp = try value(of: greater, dropping: "updated_at.gt.")
        guard String(parts[0]) == "updated_at.eq.\(stamp)" else {
            throw FixtureError.malformedFilter(raw)
        }
        return .composite(
            stamp: stamp,
            entityID: try value(of: String(parts[1]), dropping: "id.gt.")
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
        server: CappedDeltaServer,
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
