import Foundation
import XCTest
@testable import SendmeterCore

/// #915 AC2: the shared reader driven with each remaining live delta path's
/// actual page shape — the row's real database identity as the page tie-break
/// and, where the entity's ordering timestamp is not `updated_at`, the column
/// it really orders by.
final class PagedDeltaEntityShapeTests: XCTestCase {
    private let accountID = UUID(uuidString: "91500000-0000-0000-0000-000000000001")!

    // MARK: - user_settings

    /// `user_settings` is one row per user, cached under the constant
    /// `CacheEntityID.settings`. The page tie-break is the row's real
    /// `user_id`, so the fixture holds two rows at one timestamp (the contract
    /// the reader must satisfy if a response ever carries more than the
    /// caller's row) and the reader resumes with `user_id.gt`.
    func testSettingsShapeTiesOnUserIDWhileTheCacheIdentityStaysConstant() async throws {
        let userA = "91500000-0000-0000-0000-0000000000A1"
        let userB = "91500000-0000-0000-0000-0000000000B2"
        let server = CappedDeltaServer(
            rows: [
                keyedRow(userA, at: 0, note: "capacity"),
                keyedRow(userB, at: 0, note: "strength")
            ],
            cap: 1,
            tieBreakColumn: "user_id"
        )

        let delta = try await PagedKeyedReader.read(
            server: server,
            tieBreakColumn: "user_id",
            entityID: { _ in CacheEntityID.settings },
            since: nil,
            value: { $0.note },
            pageSize: 1,
            tieBreakID: { $0.key }
        )

        XCTAssertEqual(
            Set(server.requests.map(\.order)),
            ["updated_at.asc,user_id.asc"],
            "the settings page order uses the table's real tie-break column"
        )
        XCTAssertEqual(
            server.requests.dropFirst().first?.filter,
            .composite(stamp: LocalCacheStore.syncCursorString(from: stubDate(0)), entityID: userA),
            "a page boundary inside the tie group resumes with user_id.gt"
        )
        XCTAssertEqual(
            delta.changes.map(\.entityID),
            [CacheEntityID.settings],
            "every page merges under the constant cache identity, not the user id"
        )
        XCTAssertEqual(delta.changes.first?.value, "strength", "the latest revision wins")
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: stubDate(0), entityID: userB).persisted,
            "the checkpoint carries the row's real user_id so the filter can resume"
        )
    }

    // MARK: - health_metrics

    /// `health_metrics` is keyed `(user_id, date)`; `date` is the tie-break and
    /// the cache identity. The fixture's newest row (T2) sorts last, and the
    /// T1 tie group is split across the cap.
    func testHealthShapeTiesOnDateAndResumesInsideTheTimestampGroup() async throws {
        let server = CappedDeltaServer(
            rows: [
                keyedRow("2026-09-02", at: 60),
                keyedRow("2026-09-01", at: 60),
                keyedRow("2026-09-03", at: 120)
            ],
            cap: 1,
            tieBreakColumn: "date"
        )

        let delta = try await PagedKeyedReader.read(
            server: server,
            tieBreakColumn: "date",
            entityID: { $0.key },
            since: nil,
            value: { $0.note },
            pageSize: 1
        )

        XCTAssertEqual(Set(server.requests.map(\.order)), ["updated_at.asc,date.asc"])
        XCTAssertEqual(
            server.requests.dropFirst().first?.filter,
            .composite(stamp: LocalCacheStore.syncCursorString(from: stubDate(60)), entityID: "2026-09-01"),
            "the split tie group at T1 resumes with date.gt"
        )
        XCTAssertEqual(
            delta.changes.map(\.entityID),
            ["2026-09-01", "2026-09-02", "2026-09-03"],
            "every row of the split tie group is reconciled in (updated_at, date) order"
        )
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: stubDate(120), entityID: "2026-09-03").persisted
        )
    }

    // MARK: - tindeq_tags

    /// `tindeq_tags` is keyed `unique (user_id, name)` and the cache identity is
    /// the row's `name`, so the tag text is both the merge key and the tie-break.
    func testTagShapeTiesOnName() async throws {
        let server = CappedDeltaServer(
            rows: [
                keyedRow("Slopers", at: 60, note: "hidden:false"),
                keyedRow("Crimp", at: 60, note: "hidden:true")
            ],
            cap: 1,
            tieBreakColumn: "name"
        )

        let delta = try await PagedKeyedReader.read(
            server: server,
            tieBreakColumn: "name",
            entityID: { $0.key },
            since: nil,
            value: { $0.note },
            pageSize: 1
        )

        XCTAssertEqual(Set(server.requests.map(\.order)), ["updated_at.asc,name.asc"])
        XCTAssertEqual(
            server.requests.dropFirst().first?.filter,
            .composite(stamp: LocalCacheStore.syncCursorString(from: stubDate(60)), entityID: "Crimp"),
            "the split tie group resumes with name.gt"
        )
        XCTAssertEqual(delta.changes.map(\.entityID), ["Crimp", "Slopers"])
        XCTAssertEqual(delta.changes.first?.value, "hidden:true")
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: stubDate(60), entityID: "Slopers").persisted
        )
    }

    // MARK: - climb_attempts (the workout attempt collection)

    /// The attempt collection is ordered by `started_at` — not `updated_at` —
    /// and tied on `climb_attempts.id`. The same reader pages it, and a legacy
    /// (timestamp-only) checkpoint re-reads its tie group through the same
    /// timestamp column.
    func testAttemptCollectionPagesByStartedAtAndTiesOnTheAttemptID() async throws {
        let rows = [
            StubDeltaRow(uuid: stubUUID(1), updatedAt: stubDate(0), deleted: false, note: "01"),
            StubDeltaRow(uuid: stubUUID(2), updatedAt: stubDate(0), deleted: false, note: "02"),
            StubDeltaRow(uuid: stubUUID(3), updatedAt: stubDate(60), deleted: false, note: "03")
        ]
        let server = CappedDeltaServer(
            rows: rows,
            cap: 1,
            timestampColumn: "started_at",
            tieBreakColumn: "id"
        )

        let delta = try await PagedKeyedAttemptReader.read(server: server, since: nil, pageSize: 1)

        XCTAssertEqual(
            Set(server.requests.map(\.order)),
            ["started_at.asc,id.asc"],
            "the attempt collection pages on its own ordering timestamp"
        )
        XCTAssertEqual(
            server.requests.dropFirst().first?.filter,
            .composite(stamp: LocalCacheStore.syncCursorString(from: stubDate(0)), entityID: stubUUID(1).uuidString),
            "the started_at tie group resumes inside itself"
        )
        XCTAssertEqual(delta.changes.map(\.entityID), (1...3).map { stubUUID($0).uuidString })
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: stubDate(60), entityID: stubUUID(3).uuidString).persisted
        )
    }

    func testAttemptCollectionLegacyCheckpointRereadsItsStartedAtTieGroupAndEmptyCollectionIsComplete() async throws {
        let legacy = LocalCacheStore.syncCursorString(from: stubDate(0))
        let server = CappedDeltaServer(
            rows: [
                StubDeltaRow(uuid: stubUUID(1), updatedAt: stubDate(0), deleted: false, note: "01"),
                StubDeltaRow(uuid: stubUUID(2), updatedAt: stubDate(0), deleted: false, note: "02")
            ],
            cap: 1,
            timestampColumn: "started_at",
            tieBreakColumn: "id"
        )

        let delta = try await PagedKeyedAttemptReader.read(server: server, since: legacy, pageSize: 1)

        XCTAssertEqual(
            server.requests.first?.filter,
            .legacy(stamp: legacy),
            "a timestamp-only checkpoint filters on the collection's timestamp column"
        )
        XCTAssertEqual(
            delta.changes.map(\.entityID),
            (1...2).map { stubUUID($0).uuidString },
            "the whole tie group at the legacy stamp is re-read"
        )

        let empty = CappedDeltaServer<StubDeltaRow>(
            rows: [],
            cap: 1,
            timestampColumn: "started_at",
            tieBreakColumn: "id"
        )
        let emptyDelta = try await PagedKeyedAttemptReader.read(
            server: empty,
            since: delta.cursor,
            pageSize: 1
        )
        XCTAssertTrue(emptyDelta.changes.isEmpty)
        XCTAssertTrue(emptyDelta.activeValues.isEmpty)
        XCTAssertEqual(emptyDelta.cursor, delta.cursor, "an empty collection keeps the checkpoint")
        XCTAssertEqual(empty.servedPages, 1)
    }

    // MARK: - AC2: the retry and the page-budget guard on the new shapes

    func testRetriedAttemptRowReconcilesOnceOnTheNewShape() async throws {
        let rows = [
            StubDeltaRow(uuid: stubUUID(1), updatedAt: stubDate(0), deleted: false, note: "01"),
            StubDeltaRow(uuid: stubUUID(2), updatedAt: stubDate(0), deleted: false, note: "02"),
            StubDeltaRow(uuid: stubUUID(3), updatedAt: stubDate(60), deleted: false, note: "03")
        ]
        let server = CappedDeltaServer(
            rows: rows,
            cap: 1,
            timestampColumn: "started_at",
            tieBreakColumn: "id"
        )
        server.mutateAfterPage = 2
        server.mutate = { rows in
            guard let index = rows.firstIndex(where: { $0.uuid == stubUUID(2) }) else { return }
            rows[index] = StubDeltaRow(
                uuid: stubUUID(2),
                updatedAt: stubDate(30),
                deleted: false,
                note: "02-v2"
            )
        }

        let delta = try await PagedKeyedAttemptReader.read(server: server, since: nil, pageSize: 1)

        let duplicated = stubUUID(2).uuidString
        XCTAssertEqual(
            server.servedIDs.filter { $0 == duplicated }.count,
            2,
            "the fixture really re-served the updated attempt"
        )
        XCTAssertEqual(delta.changes.filter { $0.entityID == duplicated }.count, 1)
        XCTAssertEqual(delta.changes.first { $0.entityID == duplicated }?.value, "02-v2")
        XCTAssertEqual(delta.changes.count, 3)
    }

    func testBudgetExhaustionOnAStartedAtShapeThrowsInsteadOfTruncating() async throws {
        let server = CappedDeltaServer(
            rows: (1...3).map { StubDeltaRow(uuid: stubUUID($0), updatedAt: stubDate(Double($0) * 60), deleted: false, note: "0\($0)") },
            cap: 1,
            timestampColumn: "started_at",
            tieBreakColumn: "id"
        )

        do {
            _ = try await PagedKeyedAttemptReader.read(server: server, since: nil, pageSize: 1, pageLimit: 2)
            XCTFail("a truncated attempt collection must not be reported as complete")
        } catch let error as DeltaReadError {
            XCTAssertEqual(error, .pageBudgetExhausted(pageLimit: 2))
        }
        XCTAssertEqual(server.servedPages, 2)
    }

    // MARK: - AC3: a failed page publishes nothing

    func testFailedAttemptPageThrowsInsteadOfReturningAPartialCollection() async throws {
        let server = CappedDeltaServer(
            rows: (1...3).map { StubDeltaRow(uuid: stubUUID($0), updatedAt: stubDate(Double($0) * 60), deleted: false, note: "0\($0)") },
            cap: 1,
            timestampColumn: "started_at",
            tieBreakColumn: "id"
        )
        server.failOnPage = 2

        do {
            let delta = try await PagedKeyedAttemptReader.read(server: server, since: nil, pageSize: 1)
            XCTFail("a failed attempt page returned \(delta.changes.count) attempts")
        } catch {
            XCTAssertTrue(error is URLError, "the transport error propagates: \(error)")
        }
        XCTAssertEqual(server.servedPages, 2, "the read stopped at the failed page")
    }
}

/// The attempt-collection harness: `started_at` ordering, the attempt's real
/// `id` as both the merge and page tie-break.
enum PagedKeyedAttemptReader {
    static func read(
        server: CappedDeltaServer<StubDeltaRow>,
        since cursor: String?,
        pageSize: Int = 2,
        pageLimit: Int = DeltaPageReader<StubDeltaRow, String>.defaultPageLimit
    ) async throws -> RemoteEntityDelta<String> {
        let reader = DeltaPageReader<StubDeltaRow, String>(
            select: "id,started_at,duration_s,source",
            tieBreakColumn: "id",
            timestampColumn: "started_at",
            pageSize: pageSize,
            pageLimit: pageLimit,
            entityID: { $0.id },
            value: { $0.note },
            isDeleted: { _ in false },
            updatedAt: { $0.updatedAt }
        )
        return try await reader.read(since: cursor) { request in
            try server.page(for: request)
        }
    }
}
