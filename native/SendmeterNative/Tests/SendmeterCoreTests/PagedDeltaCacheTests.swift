import Foundation
import XCTest
@testable import SendmeterCore

/// #914: the paged delta reader reconciled into the account cache. The cache
/// half of the contract — exactly-once rows, no tombstone from a partial page,
/// checkpoint advance only after safely reconciled work, legacy cursor upgrade,
/// empty response and the pending-local overlay.
final class PagedDeltaCacheTests: XCTestCase {
    private let accountID = UUID(uuidString: "91400000-0000-0000-0000-0000000000AA")!

    private func makeWorkspace() throws -> CachedWorkspace {
        CachedWorkspace(store: try LocalCacheStore())
    }

    private func row(_ n: Int, at seconds: Double, deleted: Bool = false) -> StubDeltaRow {
        StubDeltaRow(
            uuid: stubUUID(n),
            updatedAt: stubDate(seconds),
            deleted: deleted,
            note: String(format: "%02d", n)
        )
    }

    private func session(_ n: Int, date: String) -> Session {
        Session(
            id: stubUUID(n),
            date: date,
            type: "hangboard",
            typeLabel: "Hangboard",
            durationMinutes: 30,
            rpe: 7,
            phase: .strength,
            accountUserID: accountID
        )
    }

    private func cachedSessionIDs(_ workspace: CachedWorkspace) throws -> [UUID] {
        try workspace.load(accountUserID: accountID).sessions.map(\.id)
    }

    // MARK: - AC1 / AC2: every page reconciled, exactly once

    func testPagedFullSnapshotReconcilesEveryPageAndAdvancesTheCompositeCheckpoint() async throws {
        let workspace = try makeWorkspace()
        let rows = [
            row(1, at: 0),
            row(2, at: 0),
            row(3, at: 0),
            row(4, at: 60),
            row(5, at: 60),
            row(6, at: 120),
            row(7, at: 120),
            row(8, at: 180, deleted: true)
        ]
        let server = CappedDeltaServer(rows: rows, cap: 2)

        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: nil,
            pageSize: 2
        )
        try workspace.reconcileServerDelta(delta, accountUserID: accountID, entityType: .sessions)

        XCTAssertGreaterThan(server.servedPages, 2)
        XCTAssertEqual(
            try cachedSessionIDs(workspace),
            (1...7).map { stubUUID($0) },
            "every active row from every page is cached; the tombstone is not"
        )
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountID, entityType: .sessions),
            DeltaCursor(updatedAt: stubDate(180), entityID: stubUUID(8).uuidString).persisted
        )
        XCTAssertTrue(try workspace.hasCompletedSync(accountUserID: accountID, entityType: .sessions))
    }

    // MARK: - AC3: a failed page never becomes authoritative

    func testMiddlePageFailureLeavesCachedRowsCheckpointAndBoundaryUntouched() async throws {
        let workspace = try makeWorkspace()
        let server = CappedDeltaServer(
            rows: [row(1, at: 0), row(2, at: 0), row(3, at: 60), row(4, at: 120)],
            cap: 2
        )
        let firstDelta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: nil,
            pageSize: 2
        )
        try workspace.reconcileServerDelta(firstDelta, accountUserID: accountID, entityType: .sessions)
        let checkpoint = try workspace.cursor(accountUserID: accountID, entityType: .sessions)
        let before = try workspace.load(accountUserID: accountID)
        XCTAssertEqual(before.sessions.count, 4, "fixture: four cached rows before the failed read")

        // Rows 1 and 2 were hard-deleted server-side and rows 5-7 are new; a
        // partial read that were treated as authoritative would tombstone rows
        // it never saw and advance the checkpoint past work it never did.
        let failing = CappedDeltaServer(
            rows: [
                row(3, at: 60),
                row(4, at: 120),
                row(5, at: 240),
                row(6, at: 300),
                row(7, at: 360)
            ],
            cap: 2
        )
        failing.failOnPage = 2
        do {
            let delta = try await PagedSessionReader.read(
                server: failing,
                accountUserID: accountID,
                since: checkpoint,
                pageSize: 2
            )
            try workspace.reconcileServerDelta(delta, accountUserID: accountID, entityType: .sessions)
            XCTFail("a failed middle page reconciled \(delta.changes.count) changes as authoritative")
        } catch {
            XCTAssertTrue(error is URLError, "the transport error propagates: \(error)")
        }

        XCTAssertEqual(try workspace.load(accountUserID: accountID), before, "the cache is untouched")
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountID, entityType: .sessions),
            checkpoint,
            "the durable checkpoint did not advance past the failed page"
        )
        XCTAssertTrue(try workspace.hasCompletedSync(accountUserID: accountID, entityType: .sessions))
        XCTAssertFalse(try cachedSessionIDs(workspace).contains(stubUUID(5)), "the unseen row is not invented")
    }

    // MARK: - AC4: legacy cursor upgrade, empty response, pending overlay

    func testLegacyTimestampOnlyCursorUpgradeKeepsEveryRowAtItsTimestamp() async throws {
        let workspace = try makeWorkspace()
        let legacyStamp = LocalCacheStore.syncCursorString(from: stubDate(0))
        try workspace.setCursor(legacyStamp, accountUserID: accountID, entityType: .sessions)

        let server = CappedDeltaServer(
            rows: [row(1, at: 0), row(2, at: 0), row(3, at: 0), row(4, at: 60)],
            cap: 2
        )
        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: legacyStamp,
            pageSize: 2
        )
        try workspace.reconcileDelta(delta, accountUserID: accountID, entityType: .sessions)

        XCTAssertEqual(
            try cachedSessionIDs(workspace),
            (1...4).map { stubUUID($0) },
            "the whole tie group at the legacy stamp is reconciled, not skipped"
        )
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountID, entityType: .sessions),
            DeltaCursor(updatedAt: stubDate(60), entityID: stubUUID(4).uuidString).persisted,
            "the checkpoint is composite after the upgrade"
        )
    }

    func testEmptyPagedResponseKeepsTheCheckpointAndStillMarksTheBoundary() async throws {
        let workspace = try makeWorkspace()
        let server = CappedDeltaServer(rows: [row(1, at: 0), row(2, at: 60)], cap: 2)
        let firstDelta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: nil,
            pageSize: 2
        )
        try workspace.reconcileServerDelta(firstDelta, accountUserID: accountID, entityType: .sessions)
        let checkpoint = try workspace.cursor(accountUserID: accountID, entityType: .sessions)

        let empty = CappedDeltaServer(rows: [], cap: 2)
        let emptyDelta = try await PagedSessionReader.read(
            server: empty,
            accountUserID: accountID,
            since: checkpoint,
            pageSize: 2
        )
        try workspace.reconcileDelta(emptyDelta, accountUserID: accountID, entityType: .sessions)

        XCTAssertTrue(emptyDelta.changes.isEmpty)
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountID, entityType: .sessions),
            checkpoint,
            "an empty response leaves the existing checkpoint alone"
        )
        XCTAssertTrue(try workspace.hasCompletedSync(accountUserID: accountID, entityType: .sessions))
        XCTAssertEqual(try cachedSessionIDs(workspace), [stubUUID(1), stubUUID(2)])
    }

    func testPagedReconcileKeepsThePendingLocalOverlay() async throws {
        let workspace = try makeWorkspace()
        _ = try workspace.upsertLocal(
            session(9, date: "local"),
            accountUserID: accountID,
            entityType: .sessions,
            entityID: stubUUID(9).uuidString
        )

        let server = CappedDeltaServer(
            rows: [row(1, at: 0), row(2, at: 0), row(9, at: 60)],
            cap: 2
        )
        let delta = try await PagedSessionReader.read(
            server: server,
            accountUserID: accountID,
            since: nil,
            pageSize: 2
        )
        try workspace.reconcileServerDelta(delta, accountUserID: accountID, entityType: .sessions)

        let loaded = try workspace.load(accountUserID: accountID)
        XCTAssertEqual(
            loaded.sessions.map(\.id),
            [stubUUID(1), stubUUID(2), stubUUID(9)],
            "the server rows arrive and the pending row is not tombstoned"
        )
        XCTAssertEqual(
            loaded.sessions.first { $0.id == stubUUID(9) }?.date,
            "local",
            "the pending local value still wins over the server row"
        )
    }
}
