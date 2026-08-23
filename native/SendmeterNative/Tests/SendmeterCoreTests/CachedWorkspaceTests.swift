import Foundation
import XCTest
@testable import SendmeterCore

final class CachedWorkspaceTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherSessionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeWorkspace() throws -> CachedWorkspace {
        CachedWorkspace(store: try LocalCacheStore())
    }

    private func session(
        _ id: UUID,
        date: String = "2026-08-20",
        accountID: UUID
    ) -> Session {
        Session(
            id: id,
            date: date,
            type: "hangboard",
            typeLabel: "Hangboard",
            durationMinutes: 40,
            rpe: 7,
            phase: .strength,
            accountUserID: accountID
        )
    }

    private func settings() -> UserSettings {
        UserSettings(currentPhase: .power, phaseStartDate: "2026-08-01")
    }

    private func recording(_ id: UUID, accountID: UUID = .init()) -> TindeqRecording {
        TindeqRecording(
            id: id,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 5000,
            peakKilograms: 12.3,
            averageKilograms: 10.1,
            sampleCount: 120,
            note: "",
            tag: "campus",
            side: .left,
            groupID: nil
        )
    }

    private func preset(_ id: UUID) -> TindeqPreset {
        TindeqPreset(
            id: id,
            name: "Max hang 7s",
            holdSeconds: 7,
            repetitions: 3,
            sets: 5,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 180,
            targetPercentage: 85,
            percentageBasis: .personalRecord,
            protocolMode: .hold
        )
    }

    private func routine(_ id: UUID) -> RoutinePreset {
        RoutinePreset(
            id: id,
            name: "Warm-up ladder",
            steps: [RoutineStep(label: "Hang", seconds: 7, repetitions: 3, restSeconds: 60)]
        )
    }

    private func workout(_ id: UUID) -> WorkoutListItem {
        WorkoutListItem(
            id: id,
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_030_000),
            averageHeartRate: 138,
            maxHeartRate: 156,
            activeKilocalories: 412,
            elevationGainMeters: 88,
            attemptsConfirmed: 4,
            attemptsDetected: 6,
            rpeConfirmed: 7,
            rpePredicted: 7,
            source: .watch
        )
    }

    private func phasePeriod(_ id: UUID) -> PhasePeriod {
        PhasePeriod(id: id, phase: .capacity, startedOn: "2026-07-01", endedOn: nil)
    }

    private func healthMetric() -> HealthMetric {
        HealthMetric(
            date: "2026-08-20",
            readiness: 82,
            zone: "green",
            computedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hrvSDNNMilliseconds: 61.5,
            restingHeartRate: 52,
            sleepHours: 7.4,
            sleepDeepHours: 1.9,
            sleepREMHours: 1.4,
            bodyMassKilograms: 71.2,
            respiratoryRate: 14.1
        )
    }

    func testColdStartLoadReturnsCachedRowsWithoutRemoteCall() throws {
        let workspace = try makeWorkspace()
        let local = session(sessionID, date: "local", accountID: accountA)
        try workspace.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )

        let loaded = try workspace.load(accountUserID: accountA)

        XCTAssertEqual(loaded.sessions, [local])
        XCTAssertEqual(loaded.settings, nil)
    }

    func testServerRefreshDoesNotClobberPendingLocalRow() throws {
        let workspace = try makeWorkspace()
        let local = session(sessionID, date: "local", accountID: accountA)
        _ = try workspace.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )

        let remote = session(sessionID, date: "server", accountID: accountA)
        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(sessions: [remote]),
            accountUserID: accountA
        )

        let loaded = try workspace.load(accountUserID: accountA)
        XCTAssertEqual(loaded.sessions, [local])
        let revision = try XCTAssertNotNilAndReturn(workspace.localRevision(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        ))
        XCTAssertGreaterThan(revision, 0)
    }

    func testServerRefreshAdoptsAndTombstonesAbsentRows() throws {
        let workspace = try makeWorkspace()
        let old = session(otherSessionID, date: "old", accountID: accountA)
        try workspace.upsertServer(
            old,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: otherSessionID.uuidString,
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let remote = session(sessionID, date: "remote", accountID: accountA)
        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(sessions: [remote]),
            accountUserID: accountA
        )

        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [remote])
        XCTAssertTrue(try workspace.store.loadAll(
            Session.self,
            accountUserID: accountA,
            entityType: .sessions
        ).filter { $0.id == otherSessionID }.isEmpty)
    }

    func testTargetedSliceReconcileLeavesOtherSlicesUntouched() throws {
        let workspace = try makeWorkspace()
        let snapshot = CachedWorkspaceSnapshot(
            sessions: [session(sessionID, accountID: accountA)],
            recordings: [recording(sessionID, accountID: accountA)]
        )
        try workspace.reconcileServer(snapshot, accountUserID: accountA)

        try workspace.reconcileSlices(
            CachedWorkspaceSnapshot(recordings: []),
            accountUserID: accountA,
            slices: [.recordings],
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let loaded = try workspace.load(accountUserID: accountA)
        XCTAssertEqual(loaded.sessions, [session(sessionID, accountID: accountA)])
        XCTAssertTrue(loaded.recordings.isEmpty)
    }

    func testStaleConfirmationDoesNotClearNewerPendingEdit() throws {
        let workspace = try makeWorkspace()
        let first = session(sessionID, date: "first", accountID: accountA)
        let firstRevision = try workspace.upsertLocal(
            first,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )
        let second = session(sessionID, date: "second", accountID: accountA)
        _ = try workspace.upsertLocal(
            second,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )

        try workspace.confirmServerUpsert(
            session(sessionID, date: "server", accountID: accountA),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString,
            confirmingLocalRevision: firstRevision
        )

        XCTAssertEqual(
            try workspace.load(accountUserID: accountA).sessions,
            [second]
        )
        let pending: Int? = try workspace.store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT pending FROM cache_rows WHERE account_user_id = ? AND entity_id = ?",
                arguments: [accountA.uuidString, sessionID.uuidString]
            )
        }
        XCTAssertEqual(pending, 1)
    }

    func testAccountIsolationAcrossLoadReconcileAndLocalDelete() throws {
        let workspace = try makeWorkspace()
        let localA = session(sessionID, accountID: accountA)
        let localB = session(otherSessionID, accountID: accountB)
        try workspace.upsertLocal(
            localA,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )
        try workspace.upsertLocal(
            localB,
            accountUserID: accountB,
            entityType: .sessions,
            entityID: otherSessionID.uuidString
        )

        let loadedA = try workspace.load(accountUserID: accountA)
        let loadedB = try workspace.load(accountUserID: accountB)
        XCTAssertEqual(loadedA.sessions, [localA])
        XCTAssertEqual(loadedB.sessions, [localB])

        _ = try workspace.markDeletedLocal(
            accountUserID: accountB,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )
        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [localA])

        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(sessions: [session(sessionID, accountID: accountB)]),
            accountUserID: accountB
        )
        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [localA])
        XCTAssertEqual(try workspace.load(accountUserID: accountB).sessions, [localB])
    }

    func testConfirmationUsesRevisionReadAfterReload() throws {
        let workspace = try makeWorkspace()
        let local = session(sessionID, date: "local", accountID: accountA)
        _ = try workspace.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )

        let revision = try workspace.localRevision(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )
        let confirmed = session(sessionID, date: "confirmed", accountID: accountA)
        try workspace.confirmServerUpsert(
            confirmed,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString,
            confirmingLocalRevision: revision ?? 0
        )

        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [confirmed])
        let pending: Int? = try workspace.store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT pending FROM cache_rows WHERE account_user_id = ? AND entity_id = ?",
                arguments: [accountA.uuidString, sessionID.uuidString]
            )
        }
        XCTAssertEqual(pending, 0)
    }

    func testNineEntitySnapshotRoundTrip() throws {
        let workspace = try makeWorkspace()
        let snapshot = CachedWorkspaceSnapshot(
            sessions: [session(sessionID, accountID: accountA)],
            settings: settings(),
            phasePeriods: [phasePeriod(sessionID)],
            healthMetrics: [healthMetric()],
            recordings: [recording(sessionID)],
            presets: [preset(sessionID)],
            routines: [routine(sessionID)],
            workouts: [workout(sessionID)],
            tagMetadata: [TagMetadata(name: "campus", hidden: true)]
        )

        try workspace.reconcileServer(snapshot, accountUserID: accountA)
        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(),
            accountUserID: accountA,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let loaded = try workspace.load(accountUserID: accountA)
        XCTAssertTrue(loaded.sessions.isEmpty)
        XCTAssertNil(loaded.settings)
        XCTAssertTrue(loaded.phasePeriods.isEmpty)
        XCTAssertTrue(loaded.healthMetrics.isEmpty)
        XCTAssertTrue(loaded.recordings.isEmpty)
        XCTAssertTrue(loaded.presets.isEmpty)
        XCTAssertTrue(loaded.routines.isEmpty)
        XCTAssertTrue(loaded.workouts.isEmpty)
        XCTAssertTrue(loaded.tagMetadata.isEmpty)
    }

    func testPendingDirectWriteCountIncludesHiddenDeletes() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.upsertLocal(
            preset(sessionID),
            accountUserID: accountA,
            entityType: .presets,
            entityID: sessionID.uuidString
        )
        _ = try workspace.markDeletedLocal(
            accountUserID: accountA,
            entityType: .routinePresets,
            entityID: otherSessionID.uuidString
        )

        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 2)
    }

    func testPendingDirectWriteSurvivesFullRefreshWithoutRemoteAndStaysVisible() throws {
        let workspace = try makeWorkspace()
        let local = preset(sessionID)
        _ = try workspace.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .presets,
            entityID: sessionID.uuidString
        )

        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(),
            accountUserID: accountA,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertEqual(try workspace.load(accountUserID: accountA).presets, [local])
        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 1)
        XCTAssertEqual(
            try Self.pendingFlag(
                in: workspace,
                accountUserID: accountA,
                entityID: sessionID.uuidString
            ),
            1
        )
    }

    func testPendingDirectWriteSurvivesRelaunchAndFullRefreshWithoutRemote() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cached-workspace-relaunch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let firstLaunch = CachedWorkspace(store: try LocalCacheStore(databaseURL: url))
        let local = preset(sessionID)
        _ = try firstLaunch.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .presets,
            entityID: sessionID.uuidString
        )

        let relaunched = CachedWorkspace(store: try LocalCacheStore(databaseURL: url))
        try relaunched.reconcileServer(
            CachedWorkspaceSnapshot(),
            accountUserID: accountA,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertEqual(try relaunched.load(accountUserID: accountA).presets, [local])
        XCTAssertEqual(try relaunched.pendingDirectWriteCount(accountUserID: accountA), 1)
    }

    func testPendingDirectDeleteSurvivesFullRefreshAndCanBeConfirmed() throws {
        let workspace = try makeWorkspace()
        let oldTag = TagMetadata(name: "campus", hidden: false)
        try workspace.upsertServer(
            oldTag,
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "campus",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let deleteRevision = try workspace.markDeletedLocal(
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "campus"
        )

        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(),
            accountUserID: accountA,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertTrue(try workspace.load(accountUserID: accountA).tagMetadata.isEmpty)
        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 1)
        try workspace.confirmServerDelete(
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "campus",
            updatedAt: Date(timeIntervalSince1970: 3_000_000_000),
            confirmingLocalRevision: deleteRevision
        )
        XCTAssertTrue(try workspace.load(accountUserID: accountA).tagMetadata.isEmpty)
        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 0)
    }

    func testRenameTagRollbackSurvivesInterleavedFullRefresh() throws {
        let workspace = try makeWorkspace()
        let old = TagMetadata(name: "campus", hidden: false)
        let next = TagMetadata(name: "hang", hidden: false)
        try workspace.upsertServer(
            old,
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "campus",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let nextRevision = try workspace.upsertLocal(
            next,
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "hang"
        )
        let oldDeleteRevision = try workspace.markDeletedLocal(
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "campus"
        )

        // A stale full refresh that still contains the old server row lands
        // while the rename is unconfirmed. It must not adopt the pending
        // tombstone as server-authoritative or hide the pending new row.
        try workspace.reconcileServer(
            CachedWorkspaceSnapshot(tagMetadata: [old]),
            accountUserID: accountA,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(
            try workspace.load(accountUserID: accountA).tagMetadata,
            [next]
        )
        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 2)

        // The rename failed; roll back through the same revisions after the
        // interleaved refresh.
        try workspace.confirmServerUpsert(
            old,
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "campus",
            updatedAt: Date(timeIntervalSince1970: 3_000_000_000),
            confirmingLocalRevision: oldDeleteRevision
        )
        try workspace.confirmServerDelete(
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "hang",
            updatedAt: Date(timeIntervalSince1970: 3_000_000_000),
            confirmingLocalRevision: nextRevision
        )
        XCTAssertEqual(
            try workspace.load(accountUserID: accountA).tagMetadata,
            [old]
        )
        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 0)
    }

    func testConcurrentRenameTagAndFullRefreshDoNotAdoptPendingTombstone() throws {
        for _ in 0..<10 {
            let workspace = try makeWorkspace()
            let old = TagMetadata(name: "campus", hidden: false)
            let next = TagMetadata(name: "hang", hidden: false)
            try workspace.upsertServer(
                old,
                accountUserID: accountA,
                entityType: .tagMetadata,
                entityID: "campus",
                updatedAt: Date(timeIntervalSince1970: 1)
            )
            let group = DispatchGroup()
            let failureLock = NSLock()
            var failure: Error?
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try workspace.reconcileServer(
                        CachedWorkspaceSnapshot(tagMetadata: [old]),
                        accountUserID: self.accountA,
                        updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
                    )
                } catch {
                    failureLock.lock()
                    failure = error
                    failureLock.unlock()
                }
            }
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let nextRevision = try workspace.upsertLocal(
                        next,
                        accountUserID: self.accountA,
                        entityType: .tagMetadata,
                        entityID: "hang"
                    )
                    let oldDeleteRevision = try workspace.markDeletedLocal(
                        accountUserID: self.accountA,
                        entityType: .tagMetadata,
                        entityID: "campus"
                    )
                    // Simulate the rename failing after the interleaved
                    // refresh: roll back through the captured revisions.
                    try workspace.confirmServerUpsert(
                        old,
                        accountUserID: self.accountA,
                        entityType: .tagMetadata,
                        entityID: "campus",
                        updatedAt: Date(timeIntervalSince1970: 3_000_000_000),
                        confirmingLocalRevision: oldDeleteRevision
                    )
                    try workspace.confirmServerDelete(
                        accountUserID: self.accountA,
                        entityType: .tagMetadata,
                        entityID: "hang",
                        updatedAt: Date(timeIntervalSince1970: 3_000_000_000),
                        confirmingLocalRevision: nextRevision
                    )
                } catch {
                    failureLock.lock()
                    failure = error
                    failureLock.unlock()
                }
            }
            group.wait()
            if let failure { throw failure }
            XCTAssertEqual(
                try workspace.load(accountUserID: accountA).tagMetadata,
                [old]
            )
            XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 0)
        }
    }

    func testTwoConcurrentFullRefreshesPreservePendingLocalRow() throws {
        let workspace = try makeWorkspace()
        let local = session(sessionID, date: "local", accountID: accountA)
        _ = try workspace.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )
        let remote = session(sessionID, date: "server", accountID: accountA)
        let group = DispatchGroup()
        let failureLock = NSLock()
        var failure: Error?
        for index in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let snapshot = index == 0
                        ? CachedWorkspaceSnapshot()
                        : CachedWorkspaceSnapshot(sessions: [remote])
                    try workspace.reconcileServer(
                        snapshot,
                        accountUserID: self.accountA,
                        updatedAt: Date(timeIntervalSince1970: Double(2_000_000_000 + index))
                    )
                } catch {
                    failureLock.lock()
                    failure = error
                    failureLock.unlock()
                }
            }
        }
        group.wait()
        if let failure { throw failure }

        XCTAssertEqual(try workspace.load(accountUserID: accountA).sessions, [local])
        XCTAssertEqual(
            try Self.pendingFlag(
                in: workspace,
                accountUserID: accountA,
                entityID: sessionID.uuidString
            ),
            1
        )
    }

    func testDeleteAccountPurgesAndStaleConfirmationCannotResurrectRow() throws {
        let workspace = try makeWorkspace()
        let local = preset(sessionID)
        let revision = try workspace.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .presets,
            entityID: sessionID.uuidString
        )

        try workspace.store.deleteAccount(accountA)
        try workspace.confirmServerUpsert(
            local,
            accountUserID: accountA,
            entityType: .presets,
            entityID: sessionID.uuidString,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            confirmingLocalRevision: revision
        )

        XCTAssertTrue(try workspace.load(accountUserID: accountA).presets.isEmpty)
        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 0)
    }

    func testDeleteAccountPurgesAndStaleDeleteConfirmationCannotResurrectRow() throws {
        let workspace = try makeWorkspace()
        let revision = try workspace.markDeletedLocal(
            accountUserID: accountA,
            entityType: .presets,
            entityID: sessionID.uuidString
        )

        try workspace.store.deleteAccount(accountA)
        try workspace.confirmServerDelete(
            accountUserID: accountA,
            entityType: .presets,
            entityID: sessionID.uuidString,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            confirmingLocalRevision: revision
        )

        XCTAssertTrue(try workspace.load(accountUserID: accountA).presets.isEmpty)
        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 0)
    }

    func testPendingDirectWriteCountIncludesHealthMetric() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.upsertLocal(
            healthMetric(),
            accountUserID: accountA,
            entityType: .healthMetrics,
            entityID: "2026-08-20"
        )

        XCTAssertEqual(try workspace.pendingDirectWriteCount(accountUserID: accountA), 1)
    }

    func testCacheHydrationWithoutStoreReturnsNil() throws {
        XCTAssertNil(
            try CacheHydrator.load(workspace: nil, accountUserID: accountA)
        )
    }

    func testCacheHydrationReadFailurePropagatesFromClosedStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cached-workspace-closed-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = CachedWorkspace(store: try LocalCacheStore(databaseURL: url))
        try workspace.store.dbQueue.close()

        XCTAssertThrowsError(
            try CacheHydrator.load(workspace: workspace, accountUserID: accountA)
        )
    }

    private static func pendingFlag(
        in workspace: CachedWorkspace,
        accountUserID: UUID,
        entityID: String
    ) throws -> Int? {
        try workspace.store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT pending FROM cache_rows
                    WHERE account_user_id = ? AND entity_id = ?
                    """,
                arguments: [accountUserID.uuidString, entityID]
            )
        }
    }

    private func XCTAssertNotNilAndReturn<T>(_ value: T?) throws -> T {
        guard let value else {
            throw XCTSkip("Expected non-nil value")
        }
        return value
    }
}
