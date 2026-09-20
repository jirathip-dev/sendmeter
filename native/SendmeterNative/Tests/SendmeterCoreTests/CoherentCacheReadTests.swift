import XCTest

@testable import SendmeterCore

/// #922: one local-cache read is a single point in time, its identity is a
/// documented revision, and it reproduces the per-entity read path exactly —
/// including order — for a large workspace.
final class CoherentCacheReadTests: XCTestCase {
    private let accountA = UUID()
    private let accountB = UUID()

    private func makeWorkspace(_ name: String = UUID().uuidString) throws -> CachedWorkspace {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coherent-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalCacheStore(
            databaseURL: directory.appendingPathComponent("local-cache.sqlite", isDirectory: false)
        )
        return CachedWorkspace(store: store)
    }

    // MARK: - Fixtures

    private func session(_ index: Int, account: UUID? = nil) -> Session {
        Session(
            id: UUID(),
            date: "2026-08-\(String(format: "%02d", (index % 28) + 1))",
            type: "fingerboard",
            typeLabel: "Fingerboard",
            durationMinutes: 30 + (index % 40),
            rpe: Double(5 + (index % 5)),
            note: "row \(index)",
            phase: .capacity,
            accountUserID: account
        )
    }

    private func recording(_ index: Int) -> TindeqRecording {
        TindeqRecording(
            id: UUID(),
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            durationMilliseconds: 5_000 + index,
            peakKilograms: 12.3 + Double(index % 7),
            averageKilograms: 10.1,
            sampleCount: 120,
            note: "",
            tag: "campus",
            side: .left,
            groupID: nil
        )
    }

    private func metric(_ index: Int) -> HealthMetric {
        HealthMetric(
            date: String(format: "2026-07-%02d", (index % 28) + 1),
            readiness: 40 + (index % 50),
            zone: "recover",
            computedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            hrvSDNNMilliseconds: 41.25,
            restingHeartRate: 50,
            sleepHours: 7.5,
            sleepDeepHours: 1.2,
            sleepREMHours: 1.6,
            bodyMassKilograms: 74.5,
            respiratoryRate: 14.2
        )
    }

    private func workout(_ index: Int) -> WorkoutListItem {
        WorkoutListItem(
            id: UUID(),
            sessionID: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600 + Double(index)),
            averageHeartRate: 120,
            maxHeartRate: 155,
            activeKilocalories: 320,
            elevationGainMeters: 12,
            attemptsConfirmed: 6,
            attemptsDetected: 7,
            rpeConfirmed: 7,
            rpePredicted: 7.5,
            source: .watch
        )
    }

    // MARK: - One revision per read

    func testOneReadSeesEveryAccountScopedEntityAndItsSyncState() throws {
        let workspace = try makeWorkspace()
        let session = self.session(1)
        try workspace.upsertLocal(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: CacheEntityID.session(session)
        )
        try workspace.upsertLocal(
            recording(0),
            accountUserID: accountA,
            entityType: .recordings,
            entityID: CacheEntityID.recording(recording(0))
        )
        try workspace.upsertLocal(
            settings(),
            accountUserID: accountA,
            entityType: .settings,
            entityID: CacheEntityID.settings
        )
        try workspace.setCursor("2026-08-01T00:00:00.000000Z", accountUserID: accountA, entityType: .sessions)
        try workspace.store.markSyncComplete(accountUserID: accountA, entityType: .recordings)

        let read = try workspace.coherentSnapshot(accountUserID: accountA)
        XCTAssertEqual(read.snapshot.sessions.map(\.id), [session.id])
        XCTAssertEqual(read.snapshot.recordings.count, 1)
        XCTAssertEqual(read.snapshot.settings?.phaseStartDate, "2026-08-01")
        XCTAssertEqual(read.cursor(for: .sessions), "2026-08-01T00:00:00.000000Z")
        XCTAssertTrue(read.hasCompletedSync(.sessions))
        XCTAssertTrue(read.hasCompletedSync(.recordings))
        XCTAssertFalse(read.hasCompletedSync(.presets))
        XCTAssertEqual(read.revision.liveRowCount, 3)
        XCTAssertEqual(read.revision.tombstoneCount, 0)
    }

    func testTheRevisionIsStableForUnchangedStateAndMovesOnEveryKindOfWrite() throws {
        let workspace = try makeWorkspace()
        let session = self.session(1)
        try workspace.upsertLocal(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: CacheEntityID.session(session)
        )
        let first = try workspace.coherentSnapshot(accountUserID: accountA).revision
        let second = try workspace.coherentSnapshot(accountUserID: accountA).revision
        XCTAssertEqual(first, second, "no write between the reads ⇒ identical revision")
        XCTAssertEqual(first.digest, second.digest)

        // A local update: same row count, same identity — the content identity
        // still has to move.
        var edited = session
        edited.note = "edited"
        try workspace.upsertLocal(
            edited,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: CacheEntityID.session(edited)
        )
        let afterRowChange = try workspace.coherentSnapshot(accountUserID: accountA).revision
        XCTAssertNotEqual(afterRowChange.digest, first.digest)
        XCTAssertEqual(afterRowChange.liveRowCount, first.liveRowCount)

        // A tombstone.
        try workspace.markDeletedLocal(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: CacheEntityID.session(edited)
        )
        let afterDelete = try workspace.coherentSnapshot(accountUserID: accountA).revision
        XCTAssertNotEqual(afterDelete.digest, afterRowChange.digest)
        XCTAssertEqual(afterDelete.liveRowCount, 0)
        XCTAssertEqual(afterDelete.tombstoneCount, 1)

        // A cursor/boundary advance, with no row change at all.
        try workspace.setCursor("2026-09-01T00:00:00.000000Z", accountUserID: accountA, entityType: .sessions)
        let afterCursor = try workspace.coherentSnapshot(accountUserID: accountA).revision
        XCTAssertNotEqual(afterCursor.digest, afterDelete.digest)
        try workspace.store.markSyncComplete(accountUserID: accountA, entityType: .sessions)
        try workspace.store.setPurgeGeneration(3, accountUserID: accountA, entityType: .sessions)
        let afterBoundary = try workspace.coherentSnapshot(accountUserID: accountA).revision
        XCTAssertNotEqual(afterBoundary.digest, afterCursor.digest)
    }

    func testAReadSeesOnlyItsOwnAccountAndOtherAccountsMoveNoRevision() throws {
        let workspace = try makeWorkspace()
        let mine = session(1)
        try workspace.upsertLocal(
            mine,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: CacheEntityID.session(mine)
        )
        let theirs = session(2)
        try workspace.upsertLocal(
            theirs,
            accountUserID: accountB,
            entityType: .sessions,
            entityID: CacheEntityID.session(theirs)
        )
        try workspace.setCursor("2026-08-01T00:00:00.000000Z", accountUserID: accountB, entityType: .sessions)

        let read = try workspace.coherentSnapshot(accountUserID: accountA)
        XCTAssertEqual(read.snapshot.sessions.map(\.id), [mine.id])
        XCTAssertNil(read.cursor(for: .sessions))
        XCTAssertFalse(read.hasCompletedSync(.sessions))
        XCTAssertEqual(read.revision.liveRowCount, 1)

        let before = read.revision
        let extra = session(3)
        try workspace.upsertLocal(
            extra,
            accountUserID: accountB,
            entityType: .sessions,
            entityID: CacheEntityID.session(extra)
        )
        let after = try workspace.coherentSnapshot(accountUserID: accountA).revision
        XCTAssertEqual(before, after, "another account's writes are not this account's revision")
    }

    func testThePendingAccessorsAndCountsMatchTheTargetedQueries() throws {
        let workspace = try makeWorkspace()
        for index in 0..<3 {
            let row = TagMetadata(name: "tag-\(index)", hidden: false)
            try workspace.upsertLocal(
                row,
                accountUserID: accountA,
                entityType: .tagMetadata,
                entityID: CacheEntityID.tagMetadata(row)
            )
        }
        try workspace.markDeletedLocal(
            accountUserID: accountA,
            entityType: .tagMetadata,
            entityID: "tag-2"
        )
        let preset = preset(0)
        try workspace.upsertLocal(
            preset,
            accountUserID: accountA,
            entityType: .presets,
            entityID: CacheEntityID.preset(preset)
        )

        let read = try workspace.coherentSnapshot(accountUserID: accountA)
        XCTAssertEqual(
            read.pendingEntityIDs(.tagMetadata),
            try workspace.pendingEntityIDs(accountUserID: accountA, entityType: .tagMetadata)
        )
        XCTAssertEqual(
            read.pendingEntityIDs(.tagMetadata, includingDeleted: true),
            try workspace.pendingEntityIDs(
                accountUserID: accountA,
                entityType: .tagMetadata,
                includingDeleted: true
            )
        )
        XCTAssertEqual(read.pendingDirectWriteCount, try workspace.pendingDirectWriteCount(accountUserID: accountA))
        XCTAssertEqual(read.pendingRows.count, read.pendingDirectWriteCount)
    }

    func testTheReadDerivesTheSamePurgeDecisionAsTheTargetedCheck() throws {
        let workspace = try makeWorkspace()
        try workspace.store.markSyncComplete(accountUserID: accountA, entityType: .sessions)
        try workspace.store.setPurgeGeneration(4, accountUserID: accountA, entityType: .sessions)
        try workspace.store.markSyncComplete(accountUserID: accountA, entityType: .recordings)
        try workspace.store.setPurgeGeneration(4, accountUserID: accountA, entityType: .recordings)

        let converged = try workspace.coherentSnapshot(accountUserID: accountA)
        XCTAssertFalse(converged.needsPurgeReconcile(remoteGeneration: 4))
        XCTAssertEqual(
            converged.needsPurgeReconcile(remoteGeneration: 4),
            try workspace.needsPurgeReconcile(accountUserID: accountA, remoteGeneration: 4)
        )
        // A newer server generation still forces a full pass, and an absent
        // generation is never read as "generation zero".
        XCTAssertTrue(converged.needsPurgeReconcile(remoteGeneration: 5))
        XCTAssertTrue(converged.needsPurgeReconcile(remoteGeneration: nil))
        XCTAssertEqual(
            converged.needsPurgeReconcile(remoteGeneration: 5),
            try workspace.needsPurgeReconcile(accountUserID: accountA, remoteGeneration: 5)
        )
        XCTAssertEqual(
            converged.purgeGenerations[.sessions],
            try workspace.purgeGeneration(accountUserID: accountA, entityType: .sessions)
        )
    }

    func testTheReadRecordsItsOwnCountAndThread() async throws {
        let workspace = try makeWorkspace()
        let store = workspace.store
        let account = accountA
        XCTAssertEqual(store.snapshotReadCount, 0)
        XCTAssertNil(store.lastSnapshotReadOnMainThread)

        let offMain = try await Task.detached {
            try workspace.coherentSnapshot(accountUserID: account)
        }.value
        _ = offMain
        XCTAssertEqual(store.snapshotReadCount, 1)
        XCTAssertEqual(
            store.lastSnapshotReadOnMainThread,
            false,
            "the production path runs this off the main actor; the instrument must see that"
        )
        _ = try workspace.coherentSnapshot(accountUserID: accountA)
        XCTAssertEqual(store.snapshotReadCount, 2)
    }

    // MARK: - Output identity and order for a large workspace

    func testLargeHistoryKeepsOutputIdentityAndOrderAgainstThePerEntityReads() throws {
        let workspace = try makeWorkspace("large")
        let sessionCount = 1_200
        let recordingCount = 800
        let metricCount = 400
        let workoutCount = 200

        var sessions: [Session] = []
        for index in 0..<sessionCount {
            let row = session(index)
            sessions.append(row)
            try workspace.upsertLocal(
                row,
                accountUserID: accountA,
                entityType: .sessions,
                entityID: CacheEntityID.session(row)
            )
        }
        var recordings: [TindeqRecording] = []
        for index in 0..<recordingCount {
            let row = recording(index)
            recordings.append(row)
            try workspace.upsertLocal(
                row,
                accountUserID: accountA,
                entityType: .recordings,
                entityID: CacheEntityID.recording(row)
            )
        }
        var metrics: [HealthMetric] = []
        for index in 0..<metricCount {
            let row = metric(index)
            guard !metrics.contains(where: { $0.date == row.date }) else { continue }
            metrics.append(row)
            try workspace.upsertLocal(
                row,
                accountUserID: accountA,
                entityType: .healthMetrics,
                entityID: CacheEntityID.healthMetric(row)
            )
        }
        var workouts: [WorkoutListItem] = []
        for index in 0..<workoutCount {
            let row = workout(index)
            workouts.append(row)
            try workspace.upsertLocal(
                row,
                accountUserID: accountA,
                entityType: .workoutsAndAttempts,
                entityID: CacheEntityID.workout(row)
            )
        }
        try workspace.setCursor("2026-08-01T00:00:00.000000Z", accountUserID: accountA, entityType: .sessions)
        try workspace.store.markSyncComplete(accountUserID: accountA, entityType: .recordings)

        // "Before": the per-entity read path this replaces.
        let perEntityStart = Date()
        let perEntity = try workspace.load(accountUserID: accountA)
        let perEntitySeconds = Date().timeIntervalSince(perEntityStart)

        // "After": the coherent read.
        let coherentStart = Date()
        let read = try workspace.coherentSnapshot(accountUserID: accountA)
        let coherentSeconds = Date().timeIntervalSince(coherentStart)

        XCTAssertEqual(read.snapshot, perEntity, "the coherent read is the same workspace")
        XCTAssertEqual(read.snapshot.sessions.count, sessionCount)
        XCTAssertEqual(read.snapshot.recordings.count, recordingCount)
        XCTAssertEqual(read.snapshot.workouts.count, workoutCount)
        XCTAssertEqual(
            read.snapshot.sessions.map(\.id),
            sessions.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id),
            "entity_id ascending, exactly like the per-entity read"
        )
        XCTAssertEqual(
            read.snapshot.recordings.map(\.id),
            recordings.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        )
        // Health metrics stay newest-first, the repository's date.desc order.
        XCTAssertEqual(
            read.snapshot.healthMetrics.map(\.date),
            read.snapshot.healthMetrics.map(\.date).sorted(by: >)
        )
        XCTAssertTrue(read.hasCompletedSync(.sessions))
        XCTAssertTrue(read.hasCompletedSync(.recordings))
        XCTAssertNil(read.cursor(for: .presets))

        // A second read of unchanged state is the same revision, and the row
        // slots in `revision` count what the read returned.
        let again = try workspace.coherentSnapshot(accountUserID: accountA)
        XCTAssertEqual(read.revision, again.revision)
        XCTAssertEqual(read.revision.liveRowCount, read.snapshot.sessions.count
            + read.snapshot.recordings.count
            + read.snapshot.healthMetrics.count
            + read.snapshot.workouts.count)

        print(
            "MEASURED coherent-large-history rows=\(read.revision.liveRowCount) "
                + "perEntity=\(String(format: "%.4f", perEntitySeconds))s "
                + "coherent=\(String(format: "%.4f", coherentSeconds))s "
                + "revision=\(read.revision.digest.prefix(16))"
        )
    }

    // MARK: - Fixtures continued

    private func settings() -> UserSettings {
        UserSettings(currentPhase: .capacity, phaseStartDate: "2026-08-01")
    }

    private func preset(_ index: Int) -> TindeqPreset {
        TindeqPreset(
            id: UUID(),
            name: "Max hang \(index)",
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
}
