import Foundation
import XCTest
@testable import SendmeterCore

/// #915 AC3/AC4: what a paged read is allowed to publish.
///
/// - The grouped workout snapshot (`workoutsAndAttempts`) may only be published
///   from a read that consumed every page: an incomplete collection must never
///   be marked complete or tombstone the workouts (and attempt groups) it did
///   not see. The publication boundary in code is
///   `CachedWorkspace.reconcileServerDelta` — the first-sync full reconcile
///   that tombstones absent rows and marks the entity complete — and it is
///   reachable only with a delta the reader produced after its last page.
/// - A failed page leaves its entity resumable with local pending values
///   intact.
/// - An account change during the read's await rejects the stale publication.
final class PagedDeltaPublicationBoundaryTests: XCTestCase {
    private let accountA = UUID(uuidString: "91500000-0000-0000-0000-0000000000AA")!
    private let accountB = UUID(uuidString: "91500000-0000-0000-0000-0000000000BB")!

    private func makeWorkspace() throws -> CachedWorkspace {
        CachedWorkspace(store: try LocalCacheStore())
    }

    private func workout(_ n: Int, at seconds: Double) -> StubDeltaRow {
        StubDeltaRow(uuid: stubUUID(n), updatedAt: stubDate(seconds), deleted: false, note: String(n))
    }

    private func tag(_ name: String, at seconds: Double, hidden: Bool) -> KeyedStubRow {
        keyedRow(name, at: seconds, note: hidden ? "hidden:true" : "hidden:false")
    }

    // MARK: - AC3: the grouped workout/attempt publication boundary

    /// Five workouts, each carrying its attempt group, served two rows per
    /// capped response; then a second cursor-bounded read that also has to
    /// complete before anything is published. Only a complete read may reach
    /// `reconcileServerDelta` — the first-sync full reconcile that tombstones
    /// every cached row it did not see and marks the entity complete.
    ///
    /// This is the guard the RED splice removes (see `.report-1.md`): with the
    /// reader's continue rule gone, page 1 alone is published as the finished
    /// snapshot — two workouts active, the other workouts (and their attempt
    /// groups) tombstoned or missing — and the assertions below fail on exactly
    /// that.
    func testGroupedWorkoutSnapshotIsPublishedOnlyFromACompleteRead() async throws {
        let workspace = try makeWorkspace()

        let first = CappedDeltaServer(rows: (1...5).map { workout($0, at: Double($0 - 1) * 60) }, cap: 2)
        let firstDelta = try await PagedWorkoutReader.read(server: first, since: nil, pageSize: 2)
        try workspace.reconcileServerDelta(
            firstDelta,
            accountUserID: accountA,
            entityType: .workoutsAndAttempts
        )

        XCTAssertGreaterThan(first.servedPages, 2, "AC2: the fixture is more than two capped pages")
        var loaded = try workspace.load(accountUserID: accountA)
        XCTAssertEqual(
            loaded.workouts.map(\.id),
            (1...5).map { stubUUID($0) },
            "every page's workout is published"
        )
        XCTAssertEqual(
            loaded.workouts.map(\.attemptsConfirmed),
            [1, 2, 3, 4, 5],
            "each published workout keeps its own attempt group, not page 1's"
        )
        XCTAssertEqual(
            try activeWorkoutIDs(workspace),
            (1...5).map { stubUUID($0).uuidString },
            "no workout absent from a page is tombstoned as an authoritative delete"
        )
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountA, entityType: .workoutsAndAttempts),
            DeltaCursor(updatedAt: stubDate(240), entityID: stubUUID(5).uuidString).persisted,
            "the checkpoint is the composite cursor of the last row actually read"
        )
        XCTAssertTrue(
            try workspace.hasCompletedSync(accountUserID: accountA, entityType: .workoutsAndAttempts),
            "the entity is only marked complete by the complete read that just ran"
        )

        // A cursor-bounded read that must also complete: a sixth workout was
        // created and the cached rows are inside the checkpoint's reach. A
        // partial publish here would tombstone the four workouts it did not
        // see, orphan their attempt groups and still claim the entity complete.
        let second = CappedDeltaServer(rows: (1...6).map { workout($0, at: Double($0 - 1) * 60) }, cap: 2)
        let secondDelta = try await PagedWorkoutReader.read(
            server: second,
            since: LocalCacheStore.syncCursorString(from: stubDate(-60)),
            pageSize: 2
        )
        XCTAssertEqual(
            secondDelta.changes.map(\.entityID),
            (1...6).map { stubUUID($0).uuidString },
            "the cursor-bounded read consumes every capped page"
        )
        try workspace.reconcileServerDelta(
            secondDelta,
            accountUserID: accountA,
            entityType: .workoutsAndAttempts
        )

        loaded = try workspace.load(accountUserID: accountA)
        XCTAssertEqual(
            loaded.workouts.map(\.id),
            (1...6).map { stubUUID($0) },
            "the new workout is published and no cached one is dropped"
        )
        XCTAssertEqual(loaded.workouts.map(\.attemptsConfirmed), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(
            try activeWorkoutIDs(workspace),
            (1...6).map { stubUUID($0).uuidString }
        )
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountA, entityType: .workoutsAndAttempts),
            DeltaCursor(updatedAt: stubDate(300), entityID: stubUUID(6).uuidString).persisted
        )
    }

    private func activeWorkoutIDs(_ workspace: CachedWorkspace) throws -> [String] {
        try workspace.store.activeEntityIDs(
            accountUserID: accountA,
            entityType: .workoutsAndAttempts
        ).sorted()
    }

    // MARK: - AC4: failed page, resumability, pending values

    func testFailedPageLeavesTheEntityResumableWithPendingLocalValuesIntact() async throws {
        let workspace = try makeWorkspace()
        let first = CappedDeltaServer(
            rows: [tag("Crimp", at: 0, hidden: false), tag("Slopers", at: 60, hidden: false)],
            cap: 2,
            tieBreakColumn: "name"
        )
        let firstDelta = try await PagedKeyedReader.read(
            server: first,
            tieBreakColumn: "name",
            entityID: { $0.key },
            since: nil,
            value: { TagMetadata(name: $0.key, hidden: $0.note == "hidden:true") },
            pageSize: 2
        )
        try workspace.reconcileServerDelta(firstDelta, accountUserID: accountA, entityType: .tagMetadata)

        // A local hide the server has not confirmed yet.
        _ = try workspace.upsertLocal(
            TagMetadata(name: "Pockets", hidden: true),
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "Pockets"
        )
        let checkpoint = try workspace.cursor(accountUserID: accountA, entityType: .tagMetadata)
        let before = try workspace.load(accountUserID: accountA)
        XCTAssertEqual(before.tagMetadata.map(\.name), ["Crimp", "Pockets", "Slopers"])

        // Two changed rows and one new row; the read cannot finish page 2.
        let failing = CappedDeltaServer(
            rows: [
                tag("Crimp", at: 120, hidden: true),
                tag("Slopers", at: 120, hidden: true),
                tag("Jugs", at: 180, hidden: false)
            ],
            cap: 1,
            tieBreakColumn: "name"
        )
        failing.failOnPage = 2
        do {
            let delta = try await PagedKeyedReader.read(
                server: failing,
                tieBreakColumn: "name",
                entityID: { $0.key },
                since: checkpoint,
                value: { TagMetadata(name: $0.key, hidden: $0.note == "hidden:true") },
                pageSize: 1
            )
            try workspace.reconcileDelta(delta, accountUserID: accountA, entityType: .tagMetadata)
            XCTFail("a failed page reconciled \(delta.changes.count) changes")
        } catch {
            XCTAssertTrue(error is URLError, "the transport error propagates: \(error)")
        }

        XCTAssertEqual(try workspace.load(accountUserID: accountA), before, "the cache is untouched")
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountA, entityType: .tagMetadata),
            checkpoint,
            "the checkpoint did not advance past the failed page"
        )
        XCTAssertTrue(try workspace.hasCompletedSync(accountUserID: accountA, entityType: .tagMetadata))

        // The retry resumes from the *same* checkpoint and consumes every page.
        let retry = CappedDeltaServer(
            rows: [
                tag("Crimp", at: 120, hidden: true),
                tag("Slopers", at: 120, hidden: true),
                tag("Jugs", at: 180, hidden: false)
            ],
            cap: 1,
            tieBreakColumn: "name"
        )
        let retried = try await PagedKeyedReader.read(
            server: retry,
            tieBreakColumn: "name",
            entityID: { $0.key },
            since: checkpoint,
            value: { TagMetadata(name: $0.key, hidden: $0.note == "hidden:true") },
            pageSize: 1
        )
        XCTAssertEqual(
            retried.changes.map(\.entityID),
            ["Crimp", "Slopers", "Jugs"],
            "the retry resumes from the unchanged checkpoint and reads every page"
        )
        XCTAssertEqual(retry.servedPages, 4, "the capped response needed three data pages plus the end")
        try workspace.reconcileDelta(retried, accountUserID: accountA, entityType: .tagMetadata)

        let after = try workspace.load(accountUserID: accountA)
        XCTAssertEqual(after.tagMetadata.map(\.name), ["Crimp", "Jugs", "Pockets", "Slopers"])
        XCTAssertEqual(after.tagMetadata.first { $0.name == "Crimp" }?.hidden, true)
        XCTAssertEqual(after.tagMetadata.first { $0.name == "Jugs" }?.hidden, false)
        XCTAssertEqual(
            after.tagMetadata.first { $0.name == "Pockets" }?.hidden,
            true,
            "the unconfirmed local value survives the failed read and the retry"
        )
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountA, entityType: .tagMetadata),
            DeltaCursor(updatedAt: stubDate(180), entityID: "Jugs").persisted
        )
    }

    // MARK: - AC4: the account check on the publication path

    /// The paged fetch completes for account A, the live account changes before
    /// the completion resumes: the engine's live check after the await — not a
    /// value captured before it — rejects the publication, so nothing reaches
    /// A's cache and A's checkpoint stays untouched and resumable.
    @MainActor
    func testAccountChangeAfterAPagedFetchAwaitRejectsTheStalePublication() async throws {
        let workspace = try makeWorkspace()
        let server = CappedDeltaServer(
            rows: [tag("Crimp", at: 0, hidden: false), tag("Slopers", at: 60, hidden: false)],
            cap: 1,
            tieBreakColumn: "name"
        )
        let live = AccountScopeBox(userID: accountA, epoch: 0)
        let operation = BackgroundSyncOperation(entityType: .tagMetadata) {
            let delta = try await PagedKeyedReader.read(
                server: server,
                tieBreakColumn: "name",
                entityID: { $0.key },
                since: nil,
                value: { TagMetadata(name: $0.key, hidden: $0.note == "hidden:true") },
                pageSize: 1
            )
            // The account switches while the read is in flight.
            live.userID = self.accountB
            live.epoch = 1
            return BackgroundSyncPreparedOperation {
                try workspace.reconcileServerDelta(delta, accountUserID: self.accountA, entityType: .tagMetadata)
            }
        }

        let outcome = await BackgroundSyncEngine.run(BackgroundSyncRun(
            accountUserID: accountA,
            accountEpoch: 0,
            isCurrent: { userID, epoch in userID == live.userID && epoch == live.epoch },
            drain: {},
            operations: [operation]
        ))

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(server.servedPages, 3, "the stale read did complete every page before it was rejected")
        XCTAssertTrue(try workspace.load(accountUserID: accountA).tagMetadata.isEmpty)
        XCTAssertNil(try workspace.cursor(accountUserID: accountA, entityType: .tagMetadata))
        XCTAssertFalse(try workspace.hasCompletedSync(accountUserID: accountA, entityType: .tagMetadata))
    }

    /// The control: the same paged fetch under the same live account publishes,
    /// so the rejection above is the account check and not a vacuous failure.
    @MainActor
    func testCurrentAccountPublishesTheSamePagedFetch() async throws {
        let workspace = try makeWorkspace()
        let server = CappedDeltaServer(
            rows: [tag("Crimp", at: 0, hidden: false), tag("Slopers", at: 60, hidden: false)],
            cap: 1,
            tieBreakColumn: "name"
        )
        let live = AccountScopeBox(userID: accountA, epoch: 0)
        let operation = BackgroundSyncOperation(entityType: .tagMetadata) {
            let delta = try await PagedKeyedReader.read(
                server: server,
                tieBreakColumn: "name",
                entityID: { $0.key },
                since: nil,
                value: { TagMetadata(name: $0.key, hidden: $0.note == "hidden:true") },
                pageSize: 1
            )
            return BackgroundSyncPreparedOperation {
                try workspace.reconcileServerDelta(delta, accountUserID: self.accountA, entityType: .tagMetadata)
            }
        }

        let outcome = await BackgroundSyncEngine.run(BackgroundSyncRun(
            accountUserID: accountA,
            accountEpoch: 0,
            isCurrent: { userID, epoch in userID == live.userID && epoch == live.epoch },
            drain: {},
            operations: [operation]
        ))

        XCTAssertEqual(outcome, .completed(1))
        XCTAssertEqual(
            try workspace.load(accountUserID: accountA).tagMetadata.map(\.name),
            ["Crimp", "Slopers"]
        )
        XCTAssertTrue(try workspace.hasCompletedSync(accountUserID: accountA, entityType: .tagMetadata))
    }
}

/// The live account/epoch pair the publication check reads after an await.
private final class AccountScopeBox: @unchecked Sendable {
    var userID: UUID?
    var epoch: UInt64

    init(userID: UUID?, epoch: UInt64) {
        self.userID = userID
        self.epoch = epoch
    }
}
