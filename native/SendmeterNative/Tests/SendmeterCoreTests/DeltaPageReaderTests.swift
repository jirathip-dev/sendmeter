import Foundation
import XCTest
@testable import SendmeterCore

/// #914: the one reusable bounded delta reader, driven against a deterministic
/// capped-response fixture that behaves like PostgREST (order + limit + cursor
/// filter) but never returns more than `cap` rows per response.
final class DeltaPageReaderTests: XCTestCase {
    private let accountID = UUID(uuidString: "91400000-0000-0000-0000-000000000001")!

    /// Three rows at T1 (a timestamp tie group), three at T2, three at T3, and
    /// two tombstones at T4 — 11 rows, every one of them expected exactly once.
    private func elevenRowFixture() -> [StubDeltaRow] {
        [
            row(1, at: 0),
            row(2, at: 0),
            row(3, at: 0),
            row(4, at: 60),
            row(5, at: 60),
            row(6, at: 60),
            row(7, at: 120),
            row(8, at: 120),
            row(9, at: 120),
            row(10, at: 180, deleted: true),
            row(11, at: 180, deleted: true)
        ]
    }

    private func row(_ n: Int, at seconds: Double, deleted: Bool = false) -> StubDeltaRow {
        StubDeltaRow(
            uuid: stubUUID(n),
            updatedAt: stubDate(seconds),
            deleted: deleted,
            note: String(format: "%02d", n)
        )
    }

    private func expectedIDs(_ numbers: ClosedRange<Int>) -> [String] {
        numbers.map { stubUUID($0).uuidString }
    }

    // MARK: - AC1 / AC2: every page consumed, in (updated_at, id) order, once

    func testCappedFixtureConsumesEveryPageInUpdatedAtThenIDOrderExactlyOnce() async throws {
        let server = CappedDeltaServer(rows: elevenRowFixture(), cap: 2)

        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: nil,
            pageSize: 2
        )

        XCTAssertGreaterThan(server.servedPages, 2, "AC2: the fixture is more than two pages")
        XCTAssertEqual(
            delta.changes.map(\.entityID),
            expectedIDs(1...11),
            "every expected ID is reconciled, in updated_at + stable-id order"
        )
        XCTAssertEqual(Set(delta.changes.map(\.entityID)).count, 11, "no ID is reconciled twice")
        XCTAssertEqual(
            delta.changes.filter(\.deleted).map(\.entityID),
            expectedIDs(10...11),
            "tombstones are part of the delta"
        )
        XCTAssertEqual(delta.activeValues.count, 9, "tombstones are not active values")
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: stubDate(180), entityID: stubUUID(11).uuidString).persisted,
            "the checkpoint is the composite cursor of the last row read"
        )
        let stamps = delta.changes.map { LocalCacheStore.syncCursorString(from: $0.updatedAt) }
        XCTAssertEqual(stamps, stamps.sorted(), "ordering is updated_at, then the stable id")

        XCTAssertEqual(
            Set(server.requests.map(\.order)),
            ["updated_at.asc,id.asc"],
            "every page is requested in the deterministic composite order"
        )
        XCTAssertEqual(Set(server.requests.map(\.limit)), ["2"], "the page size bounds every request")
        XCTAssertEqual(server.requests.first?.filter, CappedDeltaServer.Filter.none, "a first sync has no cursor filter")
        XCTAssertEqual(
            server.requests.dropFirst().first?.filter,
            .composite(
                stamp: LocalCacheStore.syncCursorString(from: stubDate(0)),
                entityID: stubUUID(2).uuidString
            ),
            "the page boundary falls inside the T1 tie group and resumes with id.gt"
        )
    }

    func testResponseCapBelowTheRequestedPageSizeStillConsumesEveryRow() async throws {
        let rows = (1...7).map { row($0, at: Double($0) * 60) }
        let server = CappedDeltaServer(rows: rows, cap: 2)

        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: nil,
            pageSize: 5
        )

        XCTAssertEqual(delta.changes.map(\.entityID), expectedIDs(1...7))
        XCTAssertEqual(server.servedPages, 4, "the server's cap is smaller than the requested page")
        XCTAssertEqual(
            server.requests.map(\.limit),
            Array(repeating: "5", count: 4),
            "the client never raises the row limit to work around the cap"
        )
    }

    func testDuplicateRetryReconcilesTheEntityOnceWithItsLatestRevision() async throws {
        let rows = [
            row(1, at: 0),
            row(2, at: 0),
            row(3, at: 0),
            row(4, at: 60),
            row(5, at: 60),
            row(6, at: 120)
        ]
        let server = CappedDeltaServer(rows: rows, cap: 2)
        server.mutateAfterPage = 2
        server.mutate = { rows in
            guard let index = rows.firstIndex(where: { $0.uuid == stubUUID(3) }) else { return }
            rows[index] = StubDeltaRow(
                uuid: stubUUID(3),
                updatedAt: stubDate(300),
                deleted: false,
                note: "03-v2"
            )
        }

        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: nil,
            pageSize: 2
        )

        let duplicatedID = stubUUID(3).uuidString
        XCTAssertEqual(
            server.servedIDs.filter { $0 == duplicatedID }.count,
            2,
            "the fixture really served the row twice (a retried/updated row)"
        )
        XCTAssertEqual(delta.changes.filter { $0.entityID == duplicatedID }.count, 1)
        let revision = try XCTUnwrap(delta.changes.first { $0.entityID == duplicatedID })
        XCTAssertEqual(revision.value?.date, "03-v2", "the latest revision wins")
        XCTAssertEqual(revision.updatedAt, stubDate(300))
        XCTAssertEqual(delta.changes.count, 6, "every other ID is reconciled exactly once")
    }

    // MARK: - AC3: a failed page never becomes a delta

    func testMiddlePageFailureThrowsAndNeverReturnsADelta() async throws {
        let server = CappedDeltaServer(rows: elevenRowFixture(), cap: 2)
        server.failOnPage = 2

        do {
            let delta = try await PagedSessionReader.read(
                server: server,
                accountUserID: accountID,
                since: nil,
                pageSize: 2
            )
            XCTFail("a failed middle page returned a delta: \(delta.changes.count) changes")
        } catch {
            XCTAssertTrue(error is URLError, "the transport error propagates: \(error)")
        }
        XCTAssertEqual(server.servedPages, 2, "the read stopped at the failed page")
    }

    func testPageBudgetExhaustionThrowsInsteadOfClaimingCompleteness() async throws {
        let rows = (1...3).map { row($0, at: Double($0) * 60) }
        let server = CappedDeltaServer(rows: rows, cap: 1)

        do {
            _ = try await PagedSessionReader.read(
                server: server,
                accountUserID: accountID,
                since: nil,
                pageSize: 1,
                pageLimit: 2
            )
            XCTFail("a truncated read must not be reported as complete")
        } catch let error as DeltaReadError {
            XCTAssertEqual(error, .pageBudgetExhausted(pageLimit: 2))
        }
        XCTAssertEqual(server.servedPages, 2, "the run stops at its page budget")
    }

    func testOutOfOrderPageFailsClosed() async throws {
        let server = CappedDeltaServer(rows: elevenRowFixture(), cap: 2)
        server.misorderOnPage = 2

        do {
            _ = try await PagedSessionReader.read(
                server: server,
                accountUserID: accountID,
                since: nil,
                pageSize: 2
            )
            XCTFail("a page the server did not order must not advance the cursor")
        } catch let error as DeltaReadError {
            XCTAssertEqual(error, .outOfOrderPage)
        }
    }

    // MARK: - AC4: legacy cursor upgrade and empty responses

    func testLegacyTimestampOnlyCursorUpgradesWithoutSkippingItsTieGroup() async throws {
        let rows = [row(1, at: 0), row(2, at: 0), row(3, at: 0), row(4, at: 60)]
        let server = CappedDeltaServer(rows: rows, cap: 2)
        let legacyCursor = LocalCacheStore.syncCursorString(from: stubDate(0))

        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: legacyCursor,
            pageSize: 2
        )

        XCTAssertEqual(
            delta.changes.map(\.entityID),
            expectedIDs(1...4),
            "the whole tie group at the legacy stamp is re-read, not skipped"
        )
        XCTAssertEqual(server.requests.first?.filter, .legacy(stamp: legacyCursor))
        XCTAssertEqual(
            server.requests.dropFirst().first?.filter,
            .composite(stamp: legacyCursor, entityID: stubUUID(2).uuidString),
            "the upgrade resumes inside the tie group"
        )
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: stubDate(60), entityID: stubUUID(4).uuidString).persisted,
            "the checkpoint is composite after the upgrade"
        )
    }

    func testEmptyResponseLeavesTheCheckpointUntouched() async throws {
        let server = CappedDeltaServer<StubDeltaRow>(rows: [], cap: 2)
        let existing = DeltaCursor(updatedAt: stubDate(120), entityID: stubUUID(9).uuidString).persisted

        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: existing,
            pageSize: 2
        )

        XCTAssertTrue(delta.changes.isEmpty)
        XCTAssertTrue(delta.activeValues.isEmpty)
        XCTAssertEqual(delta.cursor, existing, "an empty page keeps the durable checkpoint")
        XCTAssertEqual(server.servedPages, 1)
    }

    // MARK: - Cursor format

    func testCompositeCursorRoundTripsAndUnparseableInputFallsBackToAFullRead() async throws {
        let cursor = DeltaCursor(updatedAt: stubDate(60), entityID: stubUUID(7).uuidString)
        XCTAssertEqual(cursor.persisted, "\(LocalCacheStore.syncCursorString(from: stubDate(60)))|\(stubUUID(7).uuidString)")
        XCTAssertEqual(cursor.stamp.count, 27, "the stamp is the fixed-width UTC microsecond form")
        XCTAssertEqual(DeltaCursor.parse(cursor.persisted), cursor)

        let legacy = LocalCacheStore.syncCursorString(from: stubDate(60))
        let upgraded = try XCTUnwrap(DeltaCursor.parse(legacy))
        XCTAssertEqual(upgraded.stamp, legacy)
        XCTAssertNil(upgraded.entityID, "a timestamp-only cursor carries no tie-break")
        XCTAssertNil(DeltaCursor.parse("not-a-cursor"), "an unreadable cursor is no cursor")

        let server = CappedDeltaServer(rows: elevenRowFixture(), cap: 2)
        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: "not-a-cursor",
            pageSize: 2
        )
        XCTAssertEqual(server.requests.first?.filter, CappedDeltaServer.Filter.none, "an unreadable cursor re-reads everything")
        XCTAssertEqual(delta.changes.count, 11)
    }
}
