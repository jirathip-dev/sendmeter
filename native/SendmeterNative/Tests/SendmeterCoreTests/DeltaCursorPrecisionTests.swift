import Foundation
import XCTest
@testable import SendmeterCore

/// #1020: build 57 showed the unreadable-data banner on EVERY launch after the
/// first sync. The owner's rows all decode; the failure is the client's own
/// date parse. Postgres `timestamptz` — every PostgREST `updated_at` — carries
/// MICROseconds (`2026-10-05T23:22:10.123456+00:00`), and
/// `ISO8601DateFormatter` (`.withFractionalSeconds`) keeps only milliseconds.
/// The delta reader built its persisted cursor from that truncated instant, so
/// the next launch's `updated_at.gt.<cursor>` re-served the very row the
/// cursor stands on and the reader failed closed with `cursorDidNotAdvance`
/// (or, for a tie group whose microseconds disagree with its id order,
/// `outOfOrderPage`).
///
/// The fixture row below is the reproduced shape: its client value is decoded
/// from the PostgREST text through `LocalDateSupport.iso8601Date` — the parser
/// `PostgRESTClient`'s date strategy calls — while the fixture pager filters
/// and orders on the row's TRUE microsecond stamp, as Postgres does.
final class DeltaCursorPrecisionTests: XCTestCase {
    private let accountID = UUID(uuidString: "10200000-0000-0000-0000-000000000001")!

    // MARK: - the parser keeps every fractional digit

    func testPostgresMicrosecondTimestampsParseToTheExactMicrosecond() throws {
        let cases: [(text: String, micros: Int64)] = [
            ("2026-10-05T23:22:10.123456+00:00", 123_456),
            ("2026-10-05T23:22:10.123999+00:00", 123_999),
            ("2026-10-05T23:22:10.000001Z", 1),
            ("2026-10-05T23:22:10.1+00:00", 100_000),
            ("2026-10-05T23:22:10.12Z", 120_000),
            ("2026-10-05T23:22:10.123Z", 123_000),
            ("2026-10-05T23:22:10.1234567Z", 123_456),
            ("2026-10-05T23:22:10Z", 0),
            ("2026-10-05T23:22:10+00:00", 0)
        ]
        let whole = try XCTUnwrap(LocalDateSupport.iso8601Date(from: "2026-10-05T23:22:10Z"))
        let wholeMicros = DeltaCursor.microseconds(of: whole)
        for (text, micros) in cases {
            let parsed = try XCTUnwrap(LocalDateSupport.iso8601Date(from: text), text)
            XCTAssertEqual(
                DeltaCursor.microseconds(of: parsed) - wholeMicros,
                micros,
                "\(text) must keep its fraction to the microsecond"
            )
        }
    }

    func testAnOffsetStampKeepsBothItsOffsetAndItsMicroseconds() throws {
        let utc = try XCTUnwrap(LocalDateSupport.iso8601Date(from: "2026-10-05T16:22:10.654321+00:00"))
        let bangkok = try XCTUnwrap(LocalDateSupport.iso8601Date(from: "2026-10-05T23:22:10.654321+07:00"))
        XCTAssertEqual(DeltaCursor.microseconds(of: utc), DeltaCursor.microseconds(of: bangkok))
        XCTAssertEqual(
            LocalCacheStore.syncCursorString(from: bangkok),
            "2026-10-05T16:22:10.654321Z",
            "the persisted stamp is the exact server instant"
        )
    }

    func testMalformedTimestampsStillFailToParse() {
        for text in [
            "",
            "not a date",
            "2026-10-05T23:22:10.",
            "2026-10-05T23:22:10.12a456Z",
            "2026-10-05T23:22:10.123456",
            "2026-10-05 23:22:10.123456+00:00",
            "2026-13-05T23:22:10.123456Z"
        ] {
            XCTAssertNil(LocalDateSupport.iso8601Date(from: text), "\(text) must not parse")
        }
    }

    func testPersistedCursorParsesBackToItsExactMicroseconds() throws {
        let cursor = try XCTUnwrap(DeltaCursor.parse("2026-10-05T23:22:10.123456Z|abc"))
        let whole = try XCTUnwrap(LocalDateSupport.iso8601Date(from: "2026-10-05T23:22:10Z"))
        XCTAssertEqual(cursor.microseconds - DeltaCursor.microseconds(of: whole), 123_456)
        XCTAssertEqual(cursor.stamp, "2026-10-05T23:22:10.123456Z")
        XCTAssertEqual(cursor.entityID, "abc")
    }

    // MARK: - RED witness: the resumed launch

    /// Launch 1 reads the account with no cursor; launch 2 resumes at the
    /// cursor launch 1 persisted, exactly as the device does. Before the fix
    /// launch 2 threw `cursorDidNotAdvance` — the banner on every launch.
    func testResumedReadAtAMicrosecondCursorDoesNotReServeItsOwnRow() async throws {
        let rows = [
            MicrosecondStampedRow(n: 1, postgres: "2026-10-05T23:22:08.250117+00:00"),
            MicrosecondStampedRow(n: 2, postgres: "2026-10-05T23:22:09.731904+00:00"),
            MicrosecondStampedRow(n: 3, postgres: "2026-10-05T23:22:10.123456+00:00")
        ]
        let server = CappedDeltaServer(rows: rows, cap: 2)

        let launch1 = try await MicrosecondRowReader.read(server: server, since: nil)
        XCTAssertEqual(launch1.changes.map(\.entityID), rows.map(\.fixtureKey))
        XCTAssertEqual(
            launch1.cursor,
            "2026-10-05T23:22:10.123456Z|\(rows[2].fixtureKey)",
            "the checkpoint is the server's own microsecond stamp, not a millisecond truncation"
        )

        let launch2 = try await MicrosecondRowReader.read(server: server, since: launch1.cursor)
        XCTAssertEqual(launch2.changes.count, 0, "nothing changed, so the resumed read is empty")
        XCTAssertEqual(launch2.cursor, launch1.cursor, "an empty read keeps the checkpoint")
    }

    /// Two rows written within one millisecond whose microsecond order is the
    /// reverse of their id order (the owner's presets and tags). Before the
    /// fix both collapsed onto one millisecond, the client's `(stamp, id)` key
    /// disagreed with the server's order and the page failed closed.
    func testRowsInsideOneMillisecondKeepTheServersMicrosecondOrder() async throws {
        let rows = [
            MicrosecondStampedRow(n: 9, postgres: "2026-10-05T23:22:10.123100+00:00"),
            MicrosecondStampedRow(n: 1, postgres: "2026-10-05T23:22:10.123900+00:00")
        ]
        let server = CappedDeltaServer(rows: rows, cap: 5)

        let delta = try await MicrosecondRowReader.read(server: server, since: nil)

        XCTAssertEqual(delta.changes.map(\.entityID), [rows[0].fixtureKey, rows[1].fixtureKey])
    }

    /// A device upgraded from build 57 holds a cursor truncated to the
    /// millisecond. The first launch on the fixed build re-reads that row once
    /// (an idempotent re-apply, never a failure) and persists the exact stamp.
    func testAMillisecondCursorFromTheOldBuildHealsOnTheFirstResumedRead() async throws {
        let rows = [
            MicrosecondStampedRow(n: 1, postgres: "2026-10-05T23:22:09.731904+00:00"),
            MicrosecondStampedRow(n: 2, postgres: "2026-10-05T23:22:10.123456+00:00")
        ]
        let server = CappedDeltaServer(rows: rows, cap: 5)
        let oldBuildCursor = "2026-10-05T23:22:10.123000Z|\(rows[1].fixtureKey)"

        let healed = try await MicrosecondRowReader.read(server: server, since: oldBuildCursor)
        XCTAssertEqual(healed.changes.map(\.entityID), [rows[1].fixtureKey])
        XCTAssertEqual(healed.cursor, "2026-10-05T23:22:10.123456Z|\(rows[1].fixtureKey)")

        let next = try await MicrosecondRowReader.read(server: server, since: healed.cursor)
        XCTAssertEqual(next.changes.count, 0)
    }
}

/// A fixture row as PostgREST serves it. `fixtureStamp` is the TRUE stamp the
/// server filters and orders on, written straight from the text's digits (no
/// date parser involved); `updatedAt` is what the client decodes from the same
/// text through the production parser.
private struct MicrosecondStampedRow: CappedDeltaFixtureRow {
    let uuid: UUID
    let postgres: String
    let updatedAt: Date

    init(n: Int, postgres: String) {
        self.uuid = stubUUID(n)
        self.postgres = postgres
        self.updatedAt = LocalDateSupport.iso8601Date(from: postgres) ?? .distantPast
    }

    var fixtureKey: String { uuid.uuidString }
    /// `2026-10-05T23:22:10.123456+00:00` → `2026-10-05T23:22:10.123456Z`.
    var fixtureStamp: String { String(postgres.dropLast("+00:00".count)) + "Z" }
    var fixtureOrderingInstant: Date { updatedAt }
    var fixtureDeleted: Bool { false }
}

private enum MicrosecondRowReader {
    static func read(
        server: CappedDeltaServer<MicrosecondStampedRow>,
        since cursor: String?
    ) async throws -> RemoteEntityDelta<String> {
        let reader = DeltaPageReader<MicrosecondStampedRow, String>(
            select: "id,updated_at",
            pageSize: 2,
            entityID: { $0.fixtureKey },
            value: { $0.postgres },
            isDeleted: { _ in false },
            updatedAt: { $0.updatedAt }
        )
        return try await reader.read(since: cursor) { request in
            try server.page(for: request)
        }
    }
}
