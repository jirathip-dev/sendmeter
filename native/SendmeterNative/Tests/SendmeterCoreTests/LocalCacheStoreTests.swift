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

        try store.upsert(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        try store.upsert(settings, accountUserID: accountA, entityType: .settings, entityID: "settings")
        try store.upsert(period, accountUserID: accountA, entityType: .phasePeriods, entityID: entityA.uuidString)
        try store.upsert(health, accountUserID: accountA, entityType: .healthMetrics, entityID: health.date)
        try store.upsert(recording, accountUserID: accountA, entityType: .recordings, entityID: entityA.uuidString)
        try store.upsert(preset, accountUserID: accountA, entityType: .presets, entityID: entityA.uuidString)
        try store.upsert(routine, accountUserID: accountA, entityType: .routinePresets, entityID: entityA.uuidString)
        try store.upsert(workout, accountUserID: accountA, entityType: .workoutsAndAttempts, entityID: entityA.uuidString)
        try store.upsert(tag, accountUserID: accountA, entityType: .tagMetadata, entityID: tag.name)

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
        try store.upsert(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)

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

        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions),
            [session]
        )
    }

    // MARK: - Cross-account isolation

    func testCrossAccountIsolation() throws {
        let store = try makeStore()
        let session = makeSession(id: entityA)

        try store.upsert(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)

        // Account B cannot read account A's row.
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountB, entityType: .sessions).isEmpty)
        XCTAssertNil(try store.loadOne(Session.self, accountUserID: accountB, entityType: .sessions, entityID: entityA.uuidString))

        // Account B's markDeleted does not hide account A's row (it scopes by account).
        try store.markDeleted(accountUserID: accountB, entityType: .sessions, entityID: entityA.uuidString)
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

        try store.upsert(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1)
        )
        try store.markDeleted(
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(2)
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // A stale remote row older than the tombstone must not clear it.
        try store.upsert(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(1.5)
        )
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)

        // A newer row wins and is visible again.
        try store.upsert(
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

        try store.upsert(
            session,
            accountUserID: accountA,
            entityType: .sessions,
            entityID: entityA.uuidString,
            updatedAt: base.addingTimeInterval(3)
        )
        try store.markDeleted(
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

    func testConcurrentUpsertsRemainConsistent() throws {
        let store = try makeStore()
        let count = 40
        let ids = (0..<count).map { _ in UUID() }
        let lock = NSLock()
        var failures: [Error] = []

        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                try store.upsert(
                    self.makeSession(id: ids[index]),
                    accountUserID: self.accountA,
                    entityType: .sessions,
                    entityID: ids[index].uuidString,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                )
            } catch {
                lock.lock()
                failures.append(error)
                lock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(
            try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).count,
            count
        )
    }

    // MARK: - Upsert replaces + soft delete

    func testUpsertReplacesSameEntity() throws {
        let store = try makeStore()
        let first = makeSession(id: entityA, date: "2026-08-20")
        let second = makeSession(id: entityA, date: "2026-08-21")

        try store.upsert(first, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        try store.upsert(second, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)

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

        try store.upsert(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertEqual(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).count, 1)

        try store.markDeleted(accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertTrue(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions).isEmpty)
        XCTAssertNil(try store.loadOne(Session.self, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString))

        // A fresh upsert for the same key clears the tombstone and is visible again.
        try store.upsert(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        XCTAssertEqual(try store.loadAll(Session.self, accountUserID: accountA, entityType: .sessions), [session])
    }

    // MARK: - Delete account purges rows + cursors

    func testDeleteAccountPurgesRowsAndCursors() throws {
        let store = try makeStore()
        let sessionA = makeSession(id: entityA)
        let sessionB = makeSession(id: entityB)

        try store.upsert(sessionA, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
        try store.upsert(sessionB, accountUserID: accountB, entityType: .sessions, entityID: entityB.uuidString)
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
        try store.upsert(session, accountUserID: accountA, entityType: .sessions, entityID: entityA.uuidString)
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
}
