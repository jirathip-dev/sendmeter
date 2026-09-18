import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import Supabase

/// #914: the paged sessions/recordings delta through the REAL transport —
/// `SendmeterRepository` → `PostgRESTClient` → `URLSession` → the stub below.
/// The stub behaves like PostgREST with a response cap smaller than the
/// requested page size and reports its `Content-Range` total, so these tests
/// prove the request shape, the page loop and the truncation signal together.
final class PagedDeltaTransportTests: XCTestCase {
    private let userID = UUID(uuidString: "91400000-0000-0000-0000-0000000000BB")!
    private let epoch = Date(timeIntervalSince1970: 1_768_906_800)

    private func date(_ seconds: Double) -> Date {
        epoch.addingTimeInterval(seconds)
    }

    private func uuid(_ n: Int) -> UUID {
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        bytes.15 = UInt8(n)
        return UUID(uuid: bytes)
    }

    /// T1 holds a four-row tie group so the page boundary (cap 3) falls inside
    /// it; rows 7 and 8 are tombstones; row 2 is updated again while the client
    /// pages, so it is served twice.
    private func fixtureRows() -> [CappedPostgRESTPager.Row] {
        [
            CappedPostgRESTPager.Row(id: uuid(1), updatedAt: date(0), deleted: false),
            CappedPostgRESTPager.Row(id: uuid(2), updatedAt: date(0), deleted: false),
            CappedPostgRESTPager.Row(id: uuid(3), updatedAt: date(0), deleted: false),
            CappedPostgRESTPager.Row(id: uuid(4), updatedAt: date(0), deleted: false),
            CappedPostgRESTPager.Row(id: uuid(5), updatedAt: date(60), deleted: false),
            CappedPostgRESTPager.Row(id: uuid(6), updatedAt: date(60), deleted: false),
            CappedPostgRESTPager.Row(id: uuid(7), updatedAt: date(120), deleted: true),
            CappedPostgRESTPager.Row(id: uuid(8), updatedAt: date(120), deleted: true)
        ]
    }

    // MARK: - AC1 / AC2 / AC5

    @MainActor
    func testCappedSessionReadConsumesEveryPageExactlyOnceThroughTheRealTransport() async throws {
        let server = CappedPostgRESTPager(table: .sessions, rows: fixtureRows(), cap: 3)
        server.mutateAfterPage = 1
        server.mutate = { rows in
            guard let index = rows.firstIndex(where: { $0.id == self.uuid(2) }) else { return }
            rows[index].updatedAt = self.date(180)
        }
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchSessionDelta(since: nil, accountUserID: userID)

        XCTAssertEqual(server.servedPages, 3, "a >2-page capped response is consumed to the end")
        XCTAssertEqual(
            delta.changes.map(\.entityID),
            (1...8).map { uuid($0).uuidString },
            "every expected ID is reconciled once, in updated_at + stable-id order"
        )
        XCTAssertEqual(Set(delta.changes.map(\.entityID)).count, 8)
        XCTAssertEqual(
            delta.changes.filter(\.deleted).map(\.entityID),
            [uuid(7).uuidString, uuid(8).uuidString],
            "tombstones cross the wire"
        )
        XCTAssertEqual(
            server.servedIDs.filter { $0 == uuid(2).uuidString }.count,
            2,
            "the fixture really re-served the updated row"
        )
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: date(180), entityID: uuid(2).uuidString).persisted,
            "the checkpoint is the composite cursor of the last row read"
        )

        XCTAssertEqual(
            server.recorded.map(\.order),
            Array(repeating: "updated_at.asc,id.asc", count: 3),
            "every page is ordered by updated_at then id"
        )
        XCTAssertEqual(
            server.recorded.map(\.limit),
            Array(repeating: "500", count: 3),
            "AC5: every request stays bounded at the client's page size"
        )
        XCTAssertEqual(
            server.recorded.map(\.prefer),
            Array(repeating: "count=exact" as String?, count: 3),
            "the client asks for the row total that proves the response was capped"
        )
        XCTAssertEqual(server.recorded.first?.filter, CappedPostgRESTPager.Filter.none)
        XCTAssertEqual(
            server.recorded.dropFirst().first?.filter,
            .composite(stamp: LocalCacheStore.syncCursorString(from: date(0)), entityID: uuid(3).uuidString),
            "the boundary inside the T1 tie group resumes with id.gt"
        )
    }

    @MainActor
    func testCappedRecordingReadConsumesEveryPageThroughTheRealTransport() async throws {
        let server = CappedPostgRESTPager(table: .recordings, rows: fixtureRows(), cap: 3)
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchRecordingDelta(since: nil)

        XCTAssertEqual(server.servedPages, 3)
        XCTAssertEqual(delta.changes.map(\.entityID), (1...8).map { uuid($0).uuidString })
        XCTAssertEqual(
            delta.changes.filter(\.deleted).map(\.entityID),
            [uuid(7).uuidString, uuid(8).uuidString]
        )
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: date(120), entityID: uuid(8).uuidString).persisted
        )
        XCTAssertEqual(server.recorded.map(\.path), Array(repeating: "/rest/v1/tindeq_recordings", count: 3))
    }

    @MainActor
    func testLegacyCursorUpgradeThroughTheRealTransport() async throws {
        let server = CappedPostgRESTPager(table: .sessions, rows: fixtureRows(), cap: 3)
        let repository = makeRepository(server: server)
        let legacy = LocalCacheStore.syncCursorString(from: date(0))

        let delta = try await repository.fetchSessionDelta(since: legacy, accountUserID: userID)

        XCTAssertEqual(
            delta.changes.map(\.entityID),
            (1...8).map { uuid($0).uuidString },
            "the whole T1 tie group at the legacy stamp is re-read"
        )
        XCTAssertEqual(server.recorded.first?.filter, .legacy(stamp: legacy))
        XCTAssertEqual(
            server.recorded.dropFirst().first?.filter,
            .composite(stamp: legacy, entityID: uuid(3).uuidString)
        )
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: date(120), entityID: uuid(8).uuidString).persisted
        )
    }

    // MARK: - AC3

    @MainActor
    func testMiddlePageFailureThrowsInsteadOfReturningAPartialDelta() async throws {
        let server = CappedPostgRESTPager(table: .sessions, rows: fixtureRows(), cap: 3)
        server.failOnPage = 2
        let repository = makeRepository(server: server)

        do {
            let delta = try await repository.fetchSessionDelta(since: nil, accountUserID: userID)
            XCTFail("a failed middle page returned a partial delta: \(delta.changes.count) changes")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertEqual(server.servedPages, 2, "the read stopped at the failed page")
    }

    // MARK: - Harness

    @MainActor
    private func makeRepository(server: CappedPostgRESTPager) -> SendmeterRepository {
        let suite = "PagedDeltaTransportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = { Self.makeSession(userID: self.userID) }
        return SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
    }

    private static func makeSession(userID: UUID) -> Auth.Session {
        let payload = Data(#"{"session_id": "session-1", "iat": 1_000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let token = "header.\(payload).signature"
        let user = Auth.User(
            id: userID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return Auth.Session(
            accessToken: token,
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }
}

/// A PostgREST-shaped pager for the two #914 endpoints: it honours the query
/// the repository sends (`order`, `limit`, the composite/legacy cursor filter)
/// and caps every response at `cap` rows while reporting the matching total in
/// `Content-Range` — the cap signal the reader must not mistake for "done".
private final class CappedPostgRESTPager: @unchecked Sendable {
    enum Table: Equatable {
        case sessions
        case recordings

        var path: String {
            switch self {
            case .sessions: return "/rest/v1/sessions"
            case .recordings: return "/rest/v1/tindeq_recordings"
            }
        }
    }

    struct Row {
        let id: UUID
        var updatedAt: Date
        let deleted: Bool
    }

    enum Filter: Equatable {
        case none
        case legacy(stamp: String)
        case composite(stamp: String, entityID: String)

        func includes(stamp: String, id: String) -> Bool {
            switch self {
            case .none:
                return true
            case .legacy(let cursor):
                return stamp >= cursor
            case .composite(let cursor, let entityID):
                return stamp > cursor || (stamp == cursor && id > entityID)
            }
        }
    }

    struct Recorded: Equatable {
        let path: String
        let order: String
        let limit: String
        let filter: Filter
        let prefer: String?
    }

    struct Reply {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    enum StubError: Error {
        case malformedQuery(String)
    }

    let table: Table
    private(set) var rows: [Row]
    private(set) var recorded: [Recorded] = []
    private(set) var servedIDs: [String] = []
    private(set) var servedPages = 0
    let cap: Int
    var failOnPage: Int?
    var mutateAfterPage: Int?
    var mutate: ((inout [Row]) -> Void)?

    init(table: Table, rows: [Row], cap: Int) {
        self.table = table
        self.rows = rows
        self.cap = cap
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CappedPostgRESTPagerProtocol.self]
        CappedPostgRESTPagerProtocol.server = self
        return URLSession(configuration: configuration)
    }

    func reply(for request: URLRequest) throws -> Reply {
        let items = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        func item(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let filter: Filter
        if let composite = item("or") {
            filter = try Self.parseComposite(composite)
        } else if let legacy = item("updated_at") {
            filter = .legacy(stamp: try Self.value(of: legacy, dropping: "gte."))
        } else {
            filter = .none
        }
        recorded.append(Recorded(
            path: request.url?.path ?? "",
            order: item("order") ?? "",
            limit: item("limit") ?? "",
            filter: filter,
            prefer: request.value(forHTTPHeaderField: "Prefer")
        ))
        servedPages += 1
        if failOnPage == servedPages {
            return Reply(status: 500, body: Data(#"{"message":"boom"}"#.utf8), headers: [:])
        }

        let matching = rows
            .map { (stamp: LocalCacheStore.syncCursorString(from: $0.updatedAt), row: $0) }
            .filter { filter.includes(stamp: $0.stamp, id: $0.row.id.uuidString) }
            .sorted { ($0.stamp, $0.row.id.uuidString) < ($1.stamp, $1.row.id.uuidString) }
        let requested = max(1, Int(item("limit") ?? "") ?? cap)
        let window = Array(matching.prefix(min(cap, requested)))
        if mutateAfterPage == servedPages {
            mutate?(&rows)
        }
        servedIDs.append(contentsOf: window.map { $0.row.id.uuidString })
        let end = window.isEmpty ? -1 : window.count - 1
        let body = "[" + window.map { json(for: $0.row) }.joined(separator: ",") + "]"
        return Reply(
            status: 200,
            body: Data(body.utf8),
            headers: [
                "Content-Type": "application/json",
                "Content-Range": "\(window.isEmpty ? "*" : "0-\(end)")/\(matching.count)"
            ]
        )
    }

    private func json(for row: Row) -> String {
        let stamp = Self.iso(row.updatedAt)
        let deleted = row.deleted ? "\"\(stamp)\"" : "null"
        switch table {
        case .sessions:
            return """
            {"id":"\(row.id.uuidString.lowercased())","date":"2026-01-20","type":"hangboard",\
            "type_label":"Hangboard","duration_min":30,"rpe":7,"rpe_confirmed":true,"load":210,\
            "note":"","phase":"strength","group_id":null,"workout_source":null,\
            "updated_at":"\(stamp)","deleted_at":\(deleted)}
            """
        case .recordings:
            return """
            {"id":"\(row.id.uuidString.lowercased())","deleted_at":\(deleted),\
            "updated_at":"\(stamp)","recorded_at":"\(stamp)","duration_ms":5000,"sample_count":120}
            """
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func parseComposite(_ raw: String) throws -> Filter {
        guard raw.hasPrefix("("), raw.hasSuffix(")") else { throw StubError.malformedQuery(raw) }
        let inner = String(raw.dropFirst().dropLast())
        guard let andRange = inner.range(of: ",and(") else { throw StubError.malformedQuery(raw) }
        let greater = String(inner[..<andRange.lowerBound])
        var nested = String(inner[andRange.upperBound...])
        guard nested.hasSuffix(")") else { throw StubError.malformedQuery(raw) }
        nested = String(nested.dropLast())
        let parts = nested.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { throw StubError.malformedQuery(raw) }
        let stamp = try value(of: greater, dropping: "updated_at.gt.")
        guard String(parts[0]) == "updated_at.eq.\(stamp)" else { throw StubError.malformedQuery(raw) }
        return .composite(stamp: stamp, entityID: try value(of: String(parts[1]), dropping: "id.gt."))
    }

    private static func value(of item: String, dropping prefix: String) throws -> String {
        guard item.hasPrefix(prefix) else { throw StubError.malformedQuery(item) }
        return String(item.dropFirst(prefix.count))
    }
}

private final class CappedPostgRESTPagerProtocol: URLProtocol {
    nonisolated(unsafe) static var server: CappedPostgRESTPager?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let reply: CappedPostgRESTPager.Reply
        do {
            reply = try server.reply(for: request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: reply.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
