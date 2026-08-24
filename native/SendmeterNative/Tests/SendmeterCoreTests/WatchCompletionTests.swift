import Foundation
import GRDB
import XCTest
@testable import SendmeterCore

final class WatchCompletionTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let workoutID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func completion(
        sessionID: UUID? = nil,
        workoutID: UUID? = nil,
        accountUserID: UUID? = nil,
        receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> WatchWorkoutCompletion {
        WatchWorkoutCompletion(
            sessionID: sessionID ?? self.sessionID,
            workoutID: workoutID ?? self.workoutID,
            accountUserID: accountUserID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_060_000),
            attemptCount: 4,
            durationMinutes: 40,
            rpe: 7,
            phase: .strength,
            type: "bouldering",
            typeLabel: "Bouldering",
            note: "watch summary",
            rpeConfirmed: true,
            receivedAt: receivedAt
        )
    }

    private func authoritativeSession(
        id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        accountUserID: UUID
    ) -> Session {
        Session(
            id: id,
            date: "2026-08-20",
            type: "bouldering",
            typeLabel: "Bouldering",
            durationMinutes: 40,
            rpe: 7,
            rpeConfirmed: true,
            note: "server summary",
            phase: .strength,
            workoutSource: .watch,
            pending: false,
            accountUserID: accountUserID
        )
    }

    func testInboxDedupesDirectAndTransferDeliveriesAndAcknowledgesByStableIdentity() {
        var inbox = WatchCompletionInbox(limit: 2)
        let first = completion()
        let duplicate = completion(receivedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let second = completion(
            sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            workoutID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let third = completion(
            sessionID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            workoutID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )

        XCTAssertTrue(inbox.retain(first))
        XCTAssertFalse(inbox.retain(duplicate))
        XCTAssertTrue(inbox.retain(second))
        XCTAssertTrue(inbox.retain(third))
        XCTAssertEqual(inbox.values.map(\.identity), [second.identity, third.identity])

        XCTAssertFalse(inbox.acknowledge(first))
        XCTAssertTrue(inbox.acknowledge(second))
        XCTAssertEqual(inbox.values.map(\.identity), [third.identity])
    }

    func testInboxRelaunchModelDedupesPersistedValuesAndKeepsNewestBoundedEntries() {
        let first = completion()
        let duplicate = completion(receivedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let second = completion(
            sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            workoutID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let third = completion(
            sessionID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            workoutID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )

        let relaunched = WatchCompletionInbox(
            limit: 2,
            values: [first, duplicate, second, third]
        )

        XCTAssertEqual(relaunched.values.map(\.identity), [second.identity, third.identity])
    }

    func testAdoptionGateRejectsWrongAccountAndClosesConcurrentDuplicateWindow() {
        var gate = WatchCompletionAdoptionGate()
        let identity = completion().identity

        XCTAssertEqual(
            gate.claim(
                identity,
                stampedOwner: accountA,
                currentUserID: accountB,
                alreadyAdopted: false
            ),
            .wrongAccount
        )
        XCTAssertEqual(
            gate.claim(
                identity,
                stampedOwner: accountA,
                currentUserID: nil,
                alreadyAdopted: false
            ),
            .signedOut
        )
        XCTAssertEqual(
            gate.claim(
                identity,
                stampedOwner: accountA,
                currentUserID: accountA,
                alreadyAdopted: false
            ),
            .adopt
        )
        XCTAssertEqual(
            gate.claim(
                identity,
                stampedOwner: accountA,
                currentUserID: accountA,
                alreadyAdopted: false
            ),
            .inFlightDuplicate
        )

        gate.finish(identity)
        XCTAssertEqual(
            gate.claim(
                identity,
                stampedOwner: accountA,
                currentUserID: accountA,
                alreadyAdopted: true
            ),
            .alreadyAdopted
        )
    }

    func testAccountEpochInvalidatesCompletionContinuationAfterSwitchOrSignOut() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 12)

        XCTAssertTrue(fetch.canApply(to: accountA, accountEpoch: 12))
        XCTAssertFalse(fetch.canApply(to: accountB, accountEpoch: 12))
        XCTAssertFalse(fetch.canApply(to: accountA, accountEpoch: 13))
        XCTAssertFalse(fetch.canApply(to: nil, accountEpoch: 12))
    }

    func testPendingServerPlaceholderIsVisibleThroughRefreshAndConvergesToAuthoritativeRow() throws {
        let workspace = CachedWorkspace(store: try LocalCacheStore())
        let received = completion(accountUserID: accountA)
        let placeholder = received.pendingSession(accountUserID: accountA)

        try workspace.upsertPendingServer(
            placeholder,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: placeholder.id.uuidString
        )
        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [placeholder])

        // A full refresh that races the watch's upload must not infer a delete
        // from the placeholder's absence in that response.
        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(),
            accountUserID: accountA,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [placeholder])
        XCTAssertEqual(try pendingFlag(in: workspace, accountID: accountA, entityID: placeholder.id), 1)
        XCTAssertEqual(try originFlag(in: workspace, accountID: accountA, entityID: placeholder.id), "server")

        // Repeated direct/transfer adoption is idempotent and cannot replace
        // the first locally visible summary before the server row arrives.
        var duplicate = placeholder
        duplicate.note = "duplicate delivery"
        try workspace.upsertPendingServer(
            duplicate,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: duplicate.id.uuidString
        )
        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [placeholder])

        // Server convergence is authoritative even when its timestamp is older
        // than the phone's placeholder timestamp.
        let authoritative = authoritativeSession(accountUserID: accountA)
        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(sessions: [authoritative]),
            accountUserID: accountA,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [authoritative])
        XCTAssertEqual(try pendingFlag(in: workspace, accountID: accountA, entityID: authoritative.id), 0)
        XCTAssertEqual(try originFlag(in: workspace, accountID: accountA, entityID: authoritative.id), "server")
        XCTAssertTrue(try workspace.load(accountUserID: accountB).sessions.isEmpty)
    }

    func testPendingServerPlaceholderConvergesThroughAuthoritativeDelta() throws {
        let workspace = CachedWorkspace(store: try LocalCacheStore())
        let received = completion(accountUserID: accountA)
        let placeholder = received.pendingSession(accountUserID: accountA)
        try workspace.upsertPendingServer(
            placeholder,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: placeholder.id.uuidString
        )

        let authoritative = authoritativeSession(accountUserID: accountA)
        let deltaAt = Date(timeIntervalSince1970: 2_000_000_001)
        try workspace.reconcileDelta(
            RemoteEntityDelta(
                changes: [
                    RemoteEntityChange(
                        entityID: authoritative.id.uuidString,
                        value: authoritative,
                        updatedAt: deltaAt
                    )
                ],
                activeValues: [authoritative],
                cursor: LocalCacheStore.syncCursorString(from: deltaAt)
            ),
            accountUserID: accountA,
            entityType: .sessions
        )

        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [authoritative])
        XCTAssertEqual(
            try workspace.cursor(accountUserID: accountA, entityType: .sessions),
            LocalCacheStore.syncCursorString(from: deltaAt)
        )
        XCTAssertEqual(try pendingFlag(in: workspace, accountID: accountA, entityID: authoritative.id), 0)
    }

    func testPendingSessionUsesLivePhoneAccountAndAppearsInHistoryTimeline() {
        let pending = completion(accountUserID: accountB).pendingSession(accountUserID: accountA)

        XCTAssertEqual(pending.accountUserID, accountA)
        let items = HistoryTimeline.combinedItems(sessions: [pending], recordings: [])
        guard case let .session(session) = items.first else {
            return XCTFail("watch completion should be immediately visible as a session")
        }
        XCTAssertEqual(session.id, pending.id)
        XCTAssertTrue(session.pending)
    }

    private func pendingFlag(
        in workspace: CachedWorkspace,
        accountID: UUID,
        entityID: UUID
    ) throws -> Int {
        try workspace.store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT pending FROM cache_rows WHERE account_user_id = ? AND entity_id = ?",
                arguments: [accountID.uuidString, entityID.uuidString]
            )!
        }
    }

    private func originFlag(
        in workspace: CachedWorkspace,
        accountID: UUID,
        entityID: UUID
    ) throws -> String {
        try workspace.store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT write_origin FROM cache_rows WHERE account_user_id = ? AND entity_id = ?",
                arguments: [accountID.uuidString, entityID.uuidString]
            )!
        }
    }
}
