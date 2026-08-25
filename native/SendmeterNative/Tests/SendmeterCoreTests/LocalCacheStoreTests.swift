import XCTest
import GRDB
import Foundation
@testable import SendmeterCore

final class LocalCacheStoreTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let entityA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let entityB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeStore() throws -> LocalCacheStore {
        try LocalCacheStore()
    }

    private static func pendingFlag(in store: LocalCacheStore, entityID: String, accountID: UUID) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT pending FROM cache_rows WHERE account_user_id = ? AND entity_id = ?",
                arguments: [accountID.uuidString, entityID]
            )!
        }
    }

    private static func originFlag(in store: LocalCacheStore, entityID: String, accountID: UUID) throws -> String {
        try store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT write_origin FROM cache_rows WHERE account_user_id = ? AND entity_id = ?",
                arguments: [accountID.uuidString, entityID]
            )!
        }
    }

    private static func revisionFlag(in store: LocalCacheStore, entityID: String, accountID: UUID) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT local_revision FROM cache_rows WHERE account_user_id = ? AND entity_id = ?",
                arguments: [accountID.uuidString, entityID]
            )!
        }
    }

    // MARK: - Representative payloads

    private func makeSession(id: UUID, date: String = "2026-08-20") -> Session {
        Session(
            id: id,
            date: date,
            type: "hangboard",
            typeLabel: "Hangboard",
            durationMinutes: 40,
            rpe: 7,
            phase: .strength,
            groupID: nil,
            workoutSource: nil,
            pending: false,
            rejected: false,
            accountUserID: accountA
        )
    }

    private func makeSettings() -> UserSettings {
        UserSettings(currentPhase: .power, phaseStartDate: "2026-08-01")
    }

    private func makePhasePeriod(id: UUID) -> PhasePeriod {
        PhasePeriod(id: id, phase: .capacity, startedOn: "2026-07-01", endedOn: nil)
    }

    private func makeHealthMetric(date: String = "2026-08-20") -> HealthMetric {
        HealthMetric(
            date: date,
            readiness: 82,
            zone: "green",
            computedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hrvSDNNMilliseconds: 61.5,
            restingHeartRate: 52.0,
            sleepHours: 7.4,
            sleepDeepHours: 1.9,
            sleepREMHours: 1.4,
            bodyMassKilograms: 71.2,
            respiratoryRate: 14.1
        )
    }

    private func makeRecording(id: UUID) -> TindeqRecording {
        TindeqRecording(
            id: id,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 5000,
            peakKilograms: 12.3,
            averageKilograms: 10.1,
            sampleCount: 120,
            note: "sharp holds",
            tag: "campus",
            side: .left,
            groupID: nil,
            zone: .strength
        )
    }

    private func makePreset(id: UUID) -> TindeqPreset {
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

    private func makeRoutinePreset(id: UUID) -> RoutinePreset {
        RoutinePreset(
            id: id,
            name: "Warm-up ladder",
            steps: [
                RoutineStep(label: "Hang", seconds: 7, repetitions: 3, restSeconds: 60),
                RoutineStep(label: "Rest", seconds: 180)
            ]
        )
    }

    private func makeWorkout(id: UUID) -> WorkoutListItem {
        WorkoutListItem(
            id: id,
            sessionID: entityA,
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

    private func makeTagMetadata() -> TagMetadata {
        TagMetadata(name: "campus", hidden: true)
    }

    // MARK: - JSON round-trip

    func testJSONRoundTripForRepresentativePayloads() throws {
        let store = try makeStore()

        let session = makeSession(id: entityA)
        let settings = makeSettings()
        let period = makePhasePeriod(id: entityA)
        let health = makeHealthMetric()
        let recording = makeRecording(id: entityA)
        let preset = makePreset(id: entityA)
        let routine = makeRoutinePreset(id: entityA)
        let workout = makeWorkout(id: entityA)
        let tag = makeTagMetadata()

        try store.upsertLocal(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        try store.upsertLocal(settings, accountUserID: accountA, entityType: .settings, entityID: "settings")
        try store.upsertLocal(period, accountUserID: accountA, entityType: .phasePeriods, entityID: entityA.uuidString)
        try store.upsertLocal(health, accountUserID: accountA, entityType: .healthMetrics, entityID: health.date)
        try store.upsertLocal(recording, accountUserID: accountA, entityType: .recordings, entityID: entityA.uuidString)
        try store.upsertLocal(preset, accountUserID: accountA, entityType: .presets, entityID: entityA.uuidString)
        try store.upsertLocal(routine, accountUserID: accountA, entityType: .routinePresets, entityID: entityA.uuidString)
        try store.upsertLocal(workout, accountUserID: accountA, entityType: .workoutsAndAttempts, entityID: entityA.uuidString)
        try store.upsertLocal(tag, accountUserID: accountA, entityType: .tagMetadata, entityID: tag.name)

        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions),
            [session]
        )
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            session
        )
        XCTAssertEqual(
            try store.loadAll(UserSettings.self, accountUserID: accountA, entityType: .settings),
            [settings]
        )
        XCTAssertEqual(
            try store.loadAll(PhasePeriod.self, accountUserID: accountA, entityType: .phasePeriods),
            [period]
        )
        XCTAssertEqual(
            try store.loadAll(HealthMetric.self, accountUserID: accountA, entityType: .healthMetrics),
            [health]
        )
        XCTAssertEqual(
            try store.loadAll(TindeqRecording.self, accountUserID: accountA, entityType: .recordings),
            [recording]
        )
        XCTAssertEqual(
            try store.loadAll(TindeqPreset.self, accountUserID: accountA, entityType: .presets),
            [preset]
        )
        let loadedRoutines = try store.loadAll(
            RoutinePreset.self, accountUserID: accountA, entityType: .routinePresets
        )
        XCTAssertEqual(loadedRoutines.count, 1)
        // RoutineStep.id is intentionally NOT encoded (transient SwiftUI
        // identity only), so round-trip regenerates it; compare the persisted
        // fields and leave the id out of equality.
        XCTAssertEqual(loadedRoutines[0].id, routine.id)
        XCTAssertEqual(loadedRoutines[0].name, routine.name)
        let loadedSteps = loadedRoutines[0].steps
            .map { ($0.label, $0.seconds, $0.repetitions, $0.restSeconds) }
        let expectedSteps = routine.steps
            .map { ($0.label, $0.seconds, $0.repetitions, $0.restSeconds) }
        XCTAssertEqual(loadedSteps.count, expectedSteps.count)
        for (loaded, expected) in zip(loadedSteps, expectedSteps) {
            XCTAssertEqual(loaded.0, expected.0)
            XCTAssertEqual(loaded.1, expected.1)
            XCTAssertEqual(loaded.2, expected.2)
            XCTAssertEqual(loaded.3, expected.3)
        }
        XCTAssertEqual(
            try store.loadAll(WorkoutListItem.self, accountUserID: accountA, entityType: .workoutsAndAttempts),
            [workout]
        )
        XCTAssertEqual(
            try store.loadAll(TagMetadata.self, accountUserID: accountA, entityType: .tagMetadata),
            [tag]
        )
    }

    func testLoadAllSkipsInvalidPayloadAndKeepsValidRows() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)
        try store.upsertLocal(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)

        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at)
                    VALUES (?, ?, ?, ?, NULL, ?)
                    """,
                arguments: [
                    accountA.uuidString,
                    LocalCacheEntityType.sessions.rawValue,
                    entityB.uuidString,
                    "not-json",
                    "2026-08-23T09:00:00.000Z"
                ]
            )
        }

        let result = try store.loadAllResult(
            Session.self,
            accountUserID: accountA,
            entityType: .sessions
        )
        XCTAssertEqual(result.values, [session])
        XCTAssertEqual(result.invalidEntityIDs, [entityB.uuidString])
    }

    // MARK: - Cross-account isolation

    func testCrossAccountIsolation() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)

        try store.upsertLocal(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)

        // Account B cannot read account A's row.
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountB, entityType: .sessions).isEmpty)
        XCTAssertNil(try store.loadOne(Session.self, accountUserID: accountB, entityType: .sessions, entityID: entityA.uuidString))

        // Account B's markDeleted does not hide account A's row (it scopes by account).
        try store.markDeletedLocal(accountUserID: accountB, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions),
            [session]
        )

        // Account B's deleteAccount does not purge account A's row.
        try store.deleteAccount(accountB)
        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions),
            [session]
        )
    }

    func testStaleUpsertDoesNotResurrectTombstone() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try store.upsertServer(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        try store.markDeletedServer(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // A stale remote row older than the tombstone must not clear it.
        try store.upsertServer(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1.5)
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // A newer row wins and is visible again.
        try store.upsertServer(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(3)
        )
        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions),
            [session]
        )
    }

    func testStaleDeleteDoesNotHideNewerRow() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try store.upsertServer(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(3)
        )
        try store.markDeletedServer(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )

        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions),
            [session]
        )
    }

    func testServerDeleteRemembersNeverCachedKey() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try store.markDeletedServer(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // A stale upsert for a key the server has already deleted cannot
        // resurrect the row.
        try store.upsertServer(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // A newer server write clears the tombstone.
        try store.upsertServer(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(3)
        )
        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions),
            [session]
        )
    }

    func testServerRefreshDoesNotReplacePendingLocalEdit() throws {
        let store = try makeStore()
        let local = makeSession(id: entityA, date: "2026-08-20")
        let server = makeSession(id: entityA, date: "2026-08-21")

        try store.upsertLocal(local, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        // A stale server refresh must not revert an unconfirmed local edit.
        try store.upsertServer(
            server,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            local
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    func testServerUpsertOnlyAcceptsNewerServerOriginRow() throws {
        let store = try makeStore()
        let first = makeSession(id: entityA, date: "first")
        let stale = makeSession(id: entityA, date: "stale")
        let newest = makeSession(id: entityA, date: "newest")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try store.upsertServer(
            first,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        try store.upsertServer(
            stale,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(0.5)
        )
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            first
        )

        try store.upsertServer(
            newest,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            newest
        )
    }

    func testServerRefreshDeleteDoesNotHidePendingLocalEdit() throws {
        let store = try makeStore()
        let local = makeSession(id: entityA, date: "2026-08-20")

        try store.upsertLocal(local, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        // A stale server delete refresh must not clear an unconfirmed local edit.
        try store.markDeletedServer(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            local
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    func testServerRefreshDeletePreservesPendingRemotePlaceholderWhenCalledDirectly() throws {
        let store = try makeStore()
        var placeholder = makeSession(id: entityA, date: "watch")
        placeholder.pending = true
        let insertedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try store.upsertPendingServer(
            placeholder,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            insertedAt: insertedAt
        )
        try store.markDeletedServer(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: insertedAt.addingTimeInterval(1)
        )

        // CachedWorkspace filters these ids before the refresh delete call;
        // this direct-store test pins the defensive guard as well.
        XCTAssertEqual(
            try store.loadOne(
                Session.self,
                accountUserID: accountA,
                entityType: .sessions,
                entityID: entityA.uuidString
            ),
            placeholder
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
        XCTAssertEqual(try Self.originFlag(in: store, entityID: entityA.uuidString, accountID: accountA), "server")
    }

    func testServerConfirmationDoesNotMatchRemotePlaceholderRevisionZero() throws {
        let store = try makeStore()
        var placeholder = makeSession(id: entityA, date: "watch")
        placeholder.pending = true
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsertPendingServer(
            placeholder,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            insertedAt: base
        )

        try store.confirmServerUpsert(
            makeSession(id: entityA, date: "incorrect confirmation"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: 0
        )
        try store.confirmServerDelete(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2),
            confirmingLocalRevision: 0
        )

        // Revision zero is valid for a remote placeholder, but confirmations
        // are phone-owned acknowledgements and must require local origin.
        XCTAssertEqual(
            try store.loadOne(
                Session.self,
                accountUserID: accountA,
                entityType: .sessions,
                entityID: entityA.uuidString
            ),
            placeholder
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 0)
    }

    func testServerConfirmationClearsPendingAndAllowsLaterRefresh() throws {
        let store = try makeStore()
        let local = makeSession(id: entityA, date: "local")
        let confirmed = makeSession(id: entityA, date: "confirmed")
        let newest = makeSession(id: entityA, date: "newest")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let localRevision = try store.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        try store.confirmServerUpsert(
            confirmed,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: localRevision
        )

        // Confirmation applies the server state and clears pending.
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            confirmed
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 0)
        XCTAssertEqual(try Self.originFlag(in: store, entityID: entityA.uuidString, accountID: accountA), "server")
        // Confirmation clears pending but preserves the monotonic revision so a
        // stale duplicate ack cannot match a future local edit.
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), localRevision)

        // A stale refresh (older server timestamp) is dropped by server LWW.
        try store.upsertServer(
            makeSession(id: entityA, date: "stale"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(0.5)
        )
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            confirmed
        )

        // A newer refresh wins.
        try store.upsertServer(
            newest,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            newest
        )
    }

    func testServerConfirmationDeleteClearsPendingAndAllowsLaterRefresh() throws {
        let store = try makeStore()
        let local = makeSession(id: entityA, date: "local")
        let newest = makeSession(id: entityA, date: "newest")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let localRevision = try store.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        try store.confirmServerDelete(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: localRevision
        )

        // Confirmation applies the tombstone and clears pending.
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 0)
        // Confirmation clears pending but preserves the monotonic revision.
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), localRevision)

        // A stale refresh cannot resurrect the confirmed tombstone.
        try store.upsertServer(
            makeSession(id: entityA, date: "stale"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(0.5)
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // A newer server write clears the tombstone and is visible again.
        try store.upsertServer(
            newest,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            newest
        )
    }

    func testConfirmServerDeleteDoesNotCreateRowForNeverCachedKey() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try store.confirmServerDelete(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2),
            confirmingLocalRevision: 0
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // Confirmation is an ack for a local row that was already pending in
        // the cache; it must not synthesize a tombstone for a key that was
        // never written. That is what makes a late ack harmless after
        // `deleteAccount` purges the account. The refresh path owns server
        // tombstones via `markDeletedServer` (see
        // `testServerDeleteRemembersNeverCachedKey`).
        try store.upsertServer(
            makeSession(id: entityA),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        XCTAssertEqual(
            try store.loadOne(
                Session.self,
                accountUserID: accountA,
                entityType: .sessions,
                entityID: entityA.uuidString
            ),
            makeSession(id: entityA)
        )
    }

    func testConfirmServerUpsertDoesNotCreateRowForNeverCachedKey() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try store.confirmServerUpsert(
            makeSession(id: entityA, date: "confirmed"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2),
            confirmingLocalRevision: 0
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // The confirmation is only an ack for a local pending row, so a later
        // refresh is free to adopt the server row again.
        try store.upsertServer(
            makeSession(id: entityA),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        XCTAssertEqual(
            try store.loadOne(
                Session.self,
                accountUserID: accountA,
                entityType: .sessions,
                entityID: entityA.uuidString
            ),
            makeSession(id: entityA)
        )
    }

    func testLoadOneResultReportsInvalidPayloadAndLoadOneReturnsNil() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)
        try store.upsertLocal(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at)
                    VALUES (?, ?, ?, ?, NULL, ?)
                    """,
                arguments: [
                    accountA.uuidString,
                    LocalCacheEntityType.sessions.rawValue,
                    entityB.uuidString,
                    "not-json",
                    "2026-08-23T09:00:00.000Z"
                ]
            )
        }

        let valid = try store.loadOneResult(
            Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString
        )
        XCTAssertEqual(valid.value, session)
        XCTAssertFalse(valid.invalid)

        let corrupt = try store.loadOneResult(
            Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityB.uuidString
        )
        XCTAssertNil(corrupt.value)
        XCTAssertTrue(corrupt.invalid)
        XCTAssertNil(try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityB.uuidString))

        let missing = try store.loadOneResult(
            Session.self, accountUserID: accountA, entityType: .sessions, entityID: "missing"
        )
        XCTAssertNil(missing.value)
        XCTAssertFalse(missing.invalid)
    }

    func testPendingServerAdoptionDoesNotTreatCorruptRowAsMissing() throws {
        let store = try makeStore()
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at)
                    VALUES (?, ?, ?, 'not-json', NULL, ?)
                    """,
                arguments: [
                    accountA.uuidString,
                    LocalCacheEntityType.sessions.rawValue,
                    entityB.uuidString,
                    "2026-08-23T09:00:00.000Z"
                ]
            )
        }

        var completion = makeSession(id: entityB)
        completion.pending = true
        try store.upsertPendingServer(
            completion,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityB.uuidString
        )

        let result = try store.loadOneResult(
            Session.self,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityB.uuidString
        )
        XCTAssertNil(result.value)
        XCTAssertTrue(result.invalid)
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityB.uuidString, accountID: accountA), 0)
    }

    func testTimestampPreservesMicroseconds() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = makeSession(id: entityA, date: "older")
        let newer = makeSession(id: entityA, date: "newer")

        try store.upsertServer(
            older,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base
        )
        try store.upsertServer(
            newer,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(0.000020)
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            newer
        )
        let stored: String = try store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT updated_at FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(stored.count, 27)
        XCTAssertTrue(stored.hasSuffix("000020Z"))
    }

    func testConcurrentServerUpsertsSameKeyPickMaxTimestamp() throws {
        let store = try makeStore()
        let count = 40
        let lock = NSLock()
        var failures: [Error] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                try store.upsertServer(
                    self.makeSession(id: self.entityA, date: String(index)),
                    accountUserID: self.accountA,
                    entityType: .sessions,
                    entityID: self.entityA.uuidString,
                    updatedAt: base.addingTimeInterval(TimeInterval(index))
                )
            } catch {
                lock.lock()
                failures.append(error)
                lock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            makeSession(id: entityA, date: String(count - 1))
        )
    }

    func testConcurrentPendingLocalUpsertSurvivesStaleServerRefresh() throws {
        let store = try makeStore()
        let count = 40
        let lock = NSLock()
        var failures: [Error] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                if index == count / 2 {
                    // One unconfirmed local edit races many stale server refreshes.
                    try store.upsertLocal(
                        self.makeSession(id: self.entityA, date: "local"),
                        accountUserID: self.accountA,
                        entityType: .sessions,
                        entityID: self.entityA.uuidString
                    )
                } else {
                    try store.upsertServer(
                        self.makeSession(id: self.entityA, date: "server-\(index)"),
                        accountUserID: self.accountA,
                        entityType: .sessions,
                        entityID: self.entityA.uuidString,
                        updatedAt: base.addingTimeInterval(TimeInterval(index) / 10)
                    )
                }
            } catch {
                lock.lock()
                failures.append(error)
                lock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty)
        // Regardless of interleaving, the pending local edit survives refresh.
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            makeSession(id: entityA, date: "local")
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    func testConcurrentPendingLocalDeleteSurvivesStaleServerRefresh() throws {
        let store = try makeStore()
        let count = 40
        let lock = NSLock()
        var failures: [Error] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                if index == count / 2 {
                    try store.markDeletedLocal(
                        accountUserID: self.accountA,
                        entityType: .sessions,
                        entityID: self.entityA.uuidString
                    )
                } else {
                    try store.upsertServer(
                        self.makeSession(id: self.entityA, date: "server-\(index)"),
                        accountUserID: self.accountA,
                        entityType: .sessions,
                        entityID: self.entityA.uuidString,
                        updatedAt: base.addingTimeInterval(TimeInterval(index) / 10)
                    )
                }
            } catch {
                lock.lock()
                failures.append(error)
                lock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty)
        // Regardless of interleaving, the pending local delete stays hidden.
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    // MARK: - Local revision + conditional confirmation

    func testUpsertLocalReturnsIncreasingRevisionAndStoresIt() throws {
        let store = try makeStore()
        let first = makeSession(id: entityA, date: "first")
        let second = makeSession(id: entityA, date: "second")

        let firstRev = try store.upsertLocal(
            first,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        XCTAssertEqual(firstRev, 1)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)

        let secondRev = try store.upsertLocal(
            second,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        XCTAssertEqual(secondRev, 2)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 2)
    }

    func testMarkDeletedLocalReturnsIncreasingRevision() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)

        _ = try store.upsertLocal(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        let deleteRev = try store.markDeletedLocal(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        XCTAssertEqual(deleteRev, 2)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 2)
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    func testConfirmServerUpsertDoesNotClobberNewerLocalEdit() throws {
        let store = try makeStore()
        let a = makeSession(id: entityA, date: "A")
        let b = makeSession(id: entityA, date: "B")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Upload A, then edit again to B while A is in flight.
        let revA = try store.upsertLocal(
            a,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        let revB = try store.upsertLocal(
            b,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        XCTAssertEqual(revB, revA + 1)

        // A's upload completes; confirming with revA is stale and must not
        // clobber the newer local edit B.
        try store.confirmServerUpsert(
            a,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: revA
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            b
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), revB)

        // A stale refresh also cannot revert B.
        try store.upsertServer(
            a,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(0.5)
        )
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            b
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    func testConfirmServerDeleteDoesNotClobberNewerLocalUpsert() throws {
        let store = try makeStore()
        let b = makeSession(id: entityA, date: "B")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Local delete uploaded with deleteRev, then a newer edit to B.
        let deleteRev = try store.markDeletedLocal(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        _ = try store.upsertLocal(
            b,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )

        // The delete upload confirms with the old revision; B must survive.
        try store.confirmServerDelete(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: deleteRev
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            b
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    func testConfirmWithCurrentRevisionAppliesAndClearsPending() throws {
        let store = try makeStore()
        let local = makeSession(id: entityA, date: "local")
        let confirmed = makeSession(id: entityA, date: "confirmed")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let rev = try store.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        try store.confirmServerUpsert(
            confirmed,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: rev
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            confirmed
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 0)
        XCTAssertEqual(try Self.originFlag(in: store, entityID: entityA.uuidString, accountID: accountA), "server")
        // Confirmation clears pending but preserves the monotonic revision.
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), rev)
    }

    func testDuplicateConfirmFromEarlierCycleDoesNotClobberNewerUpsert() throws {
        let store = try makeStore()
        let a = makeSession(id: entityA, date: "A")
        let b = makeSession(id: entityA, date: "B")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // First cycle: upload A, confirm it.
        let revA = try store.upsertLocal(
            a,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        try store.confirmServerUpsert(
            a,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: revA
        )

        // Second cycle: a newer local edit B bumps the monotonic revision.
        let revB = try store.upsertLocal(
            b,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        XCTAssertGreaterThan(revB, revA)

        // A duplicate/late ack for the FIRST cycle (revA) must not match B.
        try store.confirmServerUpsert(
            a,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: revA
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            b
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), revB)
    }

    func testDuplicateConfirmDeleteFromEarlierCycleDoesNotClobberNewerUpsert() throws {
        let store = try makeStore()
        let b = makeSession(id: entityA, date: "B")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // First cycle: local delete, upload, confirm it.
        let revD = try store.markDeletedLocal(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        try store.confirmServerDelete(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: revD
        )

        // Second cycle: a newer local upsert B bumps the monotonic revision.
        let revB = try store.upsertLocal(
            b,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        XCTAssertGreaterThan(revB, revD)

        // A duplicate/late delete ack for the FIRST cycle (revD) must not hide B.
        try store.confirmServerDelete(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1),
            confirmingLocalRevision: revD
        )

        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            b
        )
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), revB)
    }

    func testServerRefreshKeepsLocalRevisionForPendingRow() throws {
        let store = try makeStore()
        let local = makeSession(id: entityA, date: "local")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let rev = try store.upsertLocal(
            local,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        // A refresh on a pending row must preserve the revision.
        try store.upsertServer(
            makeSession(id: entityA, date: "server"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(10)
        )
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), rev)
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }

    func testServerRefreshPreservesLocalRevisionOnNonPendingLocalRow() throws {
        let store = try makeStore()
        // A pre-existing local-origin row that is not pending (e.g. backfilled
        // by a migration) with a stale nonzero revision. A server refresh must
        // take over the row but keep the revision monotonic (never reset it).
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                    VALUES (?, ?, ?, '{}', NULL, '2026-08-23T00:00:00.000000Z', 'local', 0, 3)
                    """,
                arguments: [accountA.uuidString, LocalCacheEntityType.sessions.rawValue, entityA.uuidString]
            )
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsertServer(
            makeSession(id: entityA, date: "server"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        XCTAssertEqual(try Self.originFlag(in: store, entityID: entityA.uuidString, accountID: accountA), "server")
        XCTAssertEqual(try Self.pendingFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 0)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 3)
    }

    func testServerRefreshPreservesLocalRevisionOnNewerServerRow() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.upsertServer(
            makeSession(id: entityA, date: "older"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        // Simulate a server-origin row that once carried a local revision but
        // is now clean; a newer server refresh must keep it monotonic.
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE cache_rows SET local_revision = 7 WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )
        }
        try store.upsertServer(
            makeSession(id: entityA, date: "newer"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        XCTAssertEqual(try Self.originFlag(in: store, entityID: entityA.uuidString, accountID: accountA), "server")
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 7)
    }

    func testServerRefreshLeavesLocalRevisionForStaleServerRow() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.upsertServer(
            makeSession(id: entityA, date: "newest"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        // Simulate a server-origin row that once carried a local revision; a
        // stale refresh must leave it unchanged.
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE cache_rows SET local_revision = 5 WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )
        }
        try store.upsertServer(
            makeSession(id: entityA, date: "stale"),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 5)
    }

    // MARK: - Upsert replaces + soft delete

    func testUpsertReplacesSameEntity() throws {
        let store = try makeStore()
        let first = makeSession(id: entityA, date: "2026-08-20")
        let second = makeSession(id: entityA, date: "2026-08-21")

        try store.upsertLocal(first, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        try store.upsertLocal(second, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)

        let loaded = try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions)
        XCTAssertEqual(loaded, [second])
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(
            try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString),
            second
        )
    }

    func testSoftDeleteHidesRowsAndUpsertClearsTombstone() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)

        try store.upsertLocal(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertEqual(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).count, 1)

        try store.markDeletedLocal(accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)
        XCTAssertNil(try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString))

        // A fresh upsert for the same key clears the tombstone and is visible again.
        try store.upsertLocal(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertEqual(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions), [session])
    }

    // MARK: - Delete account purges rows + cursors

    func testDeleteAccountPurgesRowsAndCursors() throws {
        let store = try makeStore()
        let sessionA = makeSession(id: entityA)
        let sessionB = makeSession(id: entityB)

        try store.upsertLocal(sessionA, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        try store.upsertLocal(sessionB, accountUserID: accountB, entityType: .sessions, entityID: entityB.uuidString)
        try store.setCursor("a-cursor", accountUserID: accountA, entityType: .sessions)
        try store.setCursor("b-cursor", accountUserID: accountB, entityType: .sessions)

        try store.deleteAccount(accountA)

        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)
        XCTAssertNil(try store.cursor(accountUserID: accountA, entityType: .sessions))

        // Account B is untouched.
        XCTAssertEqual(try store.loadAll(Session.self, accountUserID: accountB, entityType: .sessions), [sessionB])
        XCTAssertEqual(try store.cursor(accountUserID: accountB, entityType: .sessions), "b-cursor")
    }

    // MARK: - Cursor scoping

    func testCursorUpdateAndReadAreAccountScoped() throws {
        let store = try makeStore()

        XCTAssertNil(try store.cursor(accountUserID: accountA, entityType: .sessions))

        try store.setCursor("c1", accountUserID: accountA, entityType: .sessions)
        XCTAssertEqual(try store.cursor(accountUserID: accountA, entityType: .sessions), "c1")
        XCTAssertNil(try store.cursor(accountUserID: accountB, entityType: .sessions))

        try store.setCursor("c2", accountUserID: accountA, entityType: .sessions)
        XCTAssertEqual(try store.cursor(accountUserID: accountA, entityType: .sessions), "c2")
        XCTAssertNil(try store.cursor(accountUserID: accountB, entityType: .sessions))
    }

    // MARK: - Schema idempotency

    func testSchemaMigrationCreationIsIdempotent() throws {
        let store = try makeStore()
        let queue = store.dbQueue

        // Re-run the migrator on the same queue (a second store construction and
        // a direct re-migration) must both be no-ops without erroring.
        _ = try LocalCacheStore(dbQueue: queue)
        try LocalCacheStore.migrate(queue)

        // The store still works after the repeated migrations.
        let session = makeSession(id: entityA)
        try store.upsertLocal(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertEqual(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions), [session])
    }

    func testMigrationFileBackedIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-cache-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try LocalCacheStore(databaseURL: url)
        // A second store on the same file must not fail the migration.
        _ = try LocalCacheStore(databaseURL: url)
    }

    func testFileBackedStoreIsSafeToShareAcrossConcurrentTasks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-cache-concurrent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try LocalCacheStore(databaseURL: url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let id = UUID()
                    try store.upsertLocal(
                        self.makeSession(id: id, date: "2026-08-\(String(format: "%02d", index + 1))"),
                        accountUserID: self.accountA,
                        entityType: .sessions,
                        entityID: id.uuidString
                    )
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).count,
            32
        )
    }

    func testOriginMigrationBackfillsPreexistingRowsAsLocal() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE cache_rows (
                    account_user_id TEXT NOT NULL,
                    entity_type     TEXT NOT NULL,
                    entity_id       TEXT NOT NULL,
                    payload         TEXT NOT NULL,
                    deleted_at      TEXT,
                    updated_at      TEXT NOT NULL,
                    PRIMARY KEY (account_user_id, entity_type, entity_id)
                );
                """)
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at)
                    VALUES (?, ?, ?, '{}', NULL, '2026-08-23T00:00:00.000000Z')
                    """,
                arguments: [accountA.uuidString, LocalCacheEntityType.sessions.rawValue, entityA.uuidString]
            )
        }

        _ = try LocalCacheStore(dbQueue: queue)

        let origin: String = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT write_origin FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(origin, LocalCacheWriteOrigin.local.rawValue)

        // The pending migration backfills pre-existing rows as not pending:
        // they predate the pending concept and are not unconfirmed local edits.
        let pending: Int = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT pending FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(pending, 0)

        // The local_revision migration backfills pre-existing rows as 0: they
        // have no unconfirmed local edit to track.
        let revision: Int = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT local_revision FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(revision, 0)
    }

    func testPendingMigrationBackfillsExistingRowsAsNotPending() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            // Simulate a DB that already has write_origin (the schema after the
            // addWriteOrigin migration) but not the pending column.
            try db.execute(sql: """
                CREATE TABLE cache_rows (
                    account_user_id TEXT NOT NULL,
                    entity_type     TEXT NOT NULL,
                    entity_id       TEXT NOT NULL,
                    payload         TEXT NOT NULL,
                    deleted_at      TEXT,
                    updated_at      TEXT NOT NULL,
                    write_origin    TEXT NOT NULL DEFAULT 'local',
                    PRIMARY KEY (account_user_id, entity_type, entity_id)
                );
                """)
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin)
                    VALUES (?, ?, ?, '{}', NULL, '2026-08-23T00:00:00.000000Z', 'local')
                    """,
                arguments: [accountA.uuidString, LocalCacheEntityType.sessions.rawValue, entityA.uuidString]
            )
        }

        _ = try LocalCacheStore(dbQueue: queue)

        let pending: Int = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT pending FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(pending, 0)

        let revision: Int = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT local_revision FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(revision, 0)
    }

    func testColumnAddMigrationsAreIdempotentWhenColumnsAlreadyPresent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            // Simulate a future dev who folded write_origin, pending, AND
            // local_revision into the CREATE TABLE: all three columns already
            // exist, so the guarded ALTER migrations must be no-ops rather
            // than failing with duplicate column.
            try db.execute(sql: """
                CREATE TABLE cache_rows (
                    account_user_id TEXT NOT NULL,
                    entity_type     TEXT NOT NULL,
                    entity_id       TEXT NOT NULL,
                    payload         TEXT NOT NULL,
                    deleted_at      TEXT,
                    updated_at      TEXT NOT NULL,
                    write_origin    TEXT NOT NULL DEFAULT 'local',
                    pending         INTEGER NOT NULL DEFAULT 0,
                    local_revision  INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (account_user_id, entity_type, entity_id)
                );
                """)
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload, deleted_at, updated_at, write_origin, pending, local_revision)
                    VALUES (?, ?, ?, '{}', NULL, '2026-08-23T00:00:00.000000Z', 'local', 0, 0)
                    """,
                arguments: [accountA.uuidString, LocalCacheEntityType.sessions.rawValue, entityA.uuidString]
            )
        }

        // Running the store's migrator on a queue whose columns already exist
        // must not throw a duplicate-column error.
        _ = try LocalCacheStore(dbQueue: queue)
        try LocalCacheStore.migrate(queue)

        let pending: Int = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT pending FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(pending, 0)

        let revision: Int = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT local_revision FROM cache_rows WHERE entity_id = ?",
                arguments: [entityA.uuidString]
            )!
        }
        XCTAssertEqual(revision, 0)
    }

    func testLocalRevisionMigrationCreatesColumnOnFreshSchema() throws {
        let store = try makeStore()
        // A fresh store already has local_revision; a local write bumps it.
        let rev = try store.upsertLocal(
            makeSession(id: entityA),
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString
        )
        XCTAssertEqual(rev, 1)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)

        // Re-running the migrator on the same queue is a no-op and keeps the
        // store usable.
        _ = try LocalCacheStore(dbQueue: store.dbQueue)
        try LocalCacheStore.migrate(store.dbQueue)
        XCTAssertEqual(try Self.revisionFlag(in: store, entityID: entityA.uuidString, accountID: accountA), 1)
    }
}
