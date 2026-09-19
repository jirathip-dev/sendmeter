import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #916: preset and routine create/update/delete now replay through the
/// EXISTING durable queue instead of a direct write. These tests drive a REAL
/// `AppModel` against a stubbed PostgREST transport and prove the acceptance
/// criteria at the app boundary:
///
/// * persistence round-trip: an offline save is accepted only because its
///   intent is durable, and a fresh model over the same on-disk cache + queue
///   (process death) completes the intended operation exactly once,
/// * lost acknowledgement: the server applied the insert but its response was
///   lost → the replay adopts the landed row instead of inserting a second one,
/// * revision fencing: an older acknowledgement cannot clear (or re-publish) a
///   newer pending local revision,
/// * ordering: create → update → delete cannot resurrect the removed entity,
/// * AC4: a pending cache-only row with no replay intent is adopted with a
///   provable operation instead of being silently cleared or guessed.
final class DirectWriteReplayAppTests: XCTestCase {
    /// A fresh account per test: the cache and the pending-write queue are
    /// account-scoped files in the app container, so a shared user id would
    /// leak one test's rows into the next.
    private let userID = UUID()

    // MARK: - AC1/AC2: preset persistence round-trip across process death

    @MainActor
    func testOfflinePresetSaveReplaysAfterProcessDeathExactlyOnce() async throws {
        let server = FakeDirectWritePostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        let preset = Self.preset(name: "Relaunch Hang")
        XCTAssertEqual(model.presets.count, 0, "fixture: the account starts empty")

        server.goOffline()
        let accepted = await model.savePreset(preset, isNew: true)

        XCTAssertTrue(accepted, "an offline save is accepted: its intent is durable")
        XCTAssertTrue(model.presets.contains { $0.id == preset.id }, "the optimistic row shows")
        XCTAssertEqual(server.presetInsertCount, 0, "nothing reached the server while offline")
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        // AC1: the account, the entity identity and the immutable intended
        // mutation are on disk before this save could report acceptance.
        let queueFile = try Self.queueFileContents()
        XCTAssertTrue(
            queueFile.contains(userID.uuidString),
            "the intent is persisted for this account"
        )
        XCTAssertTrue(
            queueFile.contains(preset.id.uuidString),
            "the entity identity is persisted"
        )
        XCTAssertTrue(
            queueFile.contains("Relaunch Hang"),
            "the immutable intended mutation is persisted"
        )

        // Process death: a fresh instance reads the same on-disk state.
        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        XCTAssertTrue(
            relaunched.presets.contains { $0.id == preset.id },
            "the pending row is restored from the cache before any network call"
        )
        let restoredQueueFile = try Self.queueFileContents()
        XCTAssertTrue(
            restoredQueueFile.contains(preset.id.uuidString),
            "the durable intent is still on disk for this account after the restart"
        )

        server.goOnline()
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(
            server.presetInsertCount,
            1,
            "AC2: the intended operation is performed exactly once after the relaunch"
        )
        XCTAssertEqual(server.activePresets.count, 1)
        XCTAssertEqual(server.activePresets.first?["name"] as? String, "Relaunch Hang")
        XCTAssertEqual(relaunched.presets.count, 1, "the reconciled server row replaced the optimistic one")
        XCTAssertEqual(
            relaunched.pendingCacheWriteCount,
            0,
            "no cache-only row is left behind without replay intent"
        )
    }

    // MARK: - AC1/AC2: routine persistence round-trip across process death

    @MainActor
    func testOfflineRoutineSaveReplaysAfterProcessDeathExactlyOnce() async throws {
        let server = FakeDirectWritePostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        let routine = Self.routine(name: "Relaunch Routine")

        server.goOffline()
        let accepted = await model.saveRoutine(routine, isNew: true)

        XCTAssertTrue(accepted)
        XCTAssertTrue(model.routines.contains { $0.id == routine.id })
        XCTAssertEqual(server.routineInsertCount, 0)
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        let queueFile = try Self.queueFileContents()
        XCTAssertTrue(queueFile.contains(userID.uuidString))
        XCTAssertTrue(queueFile.contains(routine.id.uuidString))
        XCTAssertTrue(queueFile.contains("Relaunch Routine"))

        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        XCTAssertTrue(relaunched.routines.contains { $0.id == routine.id })
        let restoredQueueFile = try Self.queueFileContents()
        XCTAssertTrue(
            restoredQueueFile.contains(routine.id.uuidString),
            "the durable intent is still on disk for this account after the restart"
        )

        server.goOnline()
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(server.routineInsertCount, 1)
        XCTAssertEqual(server.activeRoutines.count, 1)
        XCTAssertEqual(server.activeRoutines.first?["name"] as? String, "Relaunch Routine")
        XCTAssertEqual(relaunched.routines.count, 1)
        XCTAssertEqual(relaunched.pendingCacheWriteCount, 0)
    }

    // MARK: - AC3: lost acknowledgement retries idempotently

    @MainActor
    func testLostPresetInsertAcknowledgementRetriesIdempotently() async throws {
        let server = FakeDirectWritePostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        let preset = Self.preset(name: "Lost Ack Preset")

        server.loseNextInsertAcknowledgement()
        let writeAccepted1 = await model.savePreset(preset, isNew: true)
        XCTAssertTrue(writeAccepted1)
        try await waitForRecordedAttempt(model)

        // The server DID apply the insert; only its acknowledgement was lost.
        XCTAssertEqual(server.presetInsertCount, 1)
        XCTAssertEqual(server.activePresets.count, 1)
        XCTAssertEqual(
            model.queuedWriteCount,
            1,
            "the intent stays durable: the acknowledgement never arrived"
        )

        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.presetInsertCount,
            1,
            "AC3: the replay adopts the landed row instead of inserting a duplicate"
        )
        XCTAssertEqual(server.activePresets.count, 1, "AC3: no duplicate preset")
        XCTAssertEqual(model.presets.count, 1, "AC3: the local list holds the adopted row once")
        XCTAssertEqual(model.presets.first?.name, "Lost Ack Preset")
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    @MainActor
    func testLostRoutineInsertAcknowledgementRetriesIdempotently() async throws {
        let server = FakeDirectWritePostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        let routine = Self.routine(name: "Lost Ack Routine")

        server.loseNextInsertAcknowledgement()
        let writeAccepted2 = await model.saveRoutine(routine, isNew: true)
        XCTAssertTrue(writeAccepted2)
        try await waitForRecordedAttempt(model)

        XCTAssertEqual(server.routineInsertCount, 1)
        XCTAssertEqual(server.activeRoutines.count, 1)
        XCTAssertEqual(model.queuedWriteCount, 1)

        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.routineInsertCount, 1, "AC3: no duplicate routine insert")
        XCTAssertEqual(server.activeRoutines.count, 1)
        XCTAssertEqual(model.routines.count, 1)
        XCTAssertEqual(model.routines.first?.name, "Lost Ack Routine")
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    // MARK: - AC3: an older acknowledgement cannot clear a newer revision

    @MainActor
    func testOlderPresetAcknowledgementCannotClearANewerPendingRevision() async throws {
        let server = FakeDirectWritePostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        let seeded = Self.preset(name: "Original")
        let writeAccepted3 = await model.savePreset(seeded, isNew: true)
        XCTAssertTrue(writeAccepted3)
        try await waitForQueueCount(model, expected: 0)
        let savedRow = try XCTUnwrap(model.presets.first)
        XCTAssertEqual(savedRow.name, "Original")

        // Hold the first edit's PATCH so the newer edit definitely lands while
        // its acknowledgement is still in flight.
        var firstEdit = savedRow
        firstEdit.name = "Edited A"
        server.holdNextRequest()
        let writeAccepted4 = await model.savePreset(firstEdit, isNew: false)
        XCTAssertTrue(writeAccepted4)
        try await waitForHeldRequest(server)

        var secondEdit = savedRow
        secondEdit.name = "Edited B"
        let writeAccepted5 = await model.savePreset(secondEdit, isNew: false)
        XCTAssertTrue(writeAccepted5)
        XCTAssertEqual(model.presets.first?.name, "Edited B", "the newest local edit is published")

        // Release the stale acknowledgement and hold the replacement's request
        // so the stale response's outcome is observable.
        server.holdNextRequest()
        server.releaseHeldRequest()
        try await waitForHeldRequest(server)

        XCTAssertEqual(
            model.presets.first?.name,
            "Edited B",
            "AC3: the older acknowledgement must not re-publish its own (older) row"
        )
        XCTAssertEqual(
            model.pendingCacheWriteCount,
            1,
            "AC3: the newer local revision is still pending"
        )

        server.releaseHeldRequest()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.activePresets.first?["name"] as? String, "Edited B")
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
        XCTAssertEqual(model.presets.first?.name, "Edited B")
    }

    // MARK: - AC2: create → update → delete cannot resurrect

    @MainActor
    func testPresetCreateUpdateDeleteCannotResurrectTheRemovedEntity() async throws {
        let server = FakeDirectWritePostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        server.goOffline()
        let preset = Self.preset(name: "Doomed")
        let writeAccepted6 = await model.savePreset(preset, isNew: true)
        XCTAssertTrue(writeAccepted6)
        try await waitForRecordedAttempt(model)

        var edited = preset
        edited.name = "Doomed (edited)"
        let writeAccepted7 = await model.savePreset(edited, isNew: false)
        XCTAssertTrue(writeAccepted7)
        XCTAssertEqual(model.presets.first?.name, "Doomed (edited)")

        let writeAccepted8 = await model.deletePreset(edited)
        XCTAssertTrue(writeAccepted8)
        XCTAssertFalse(model.presets.contains { $0.id == preset.id })
        XCTAssertEqual(
            model.queuedWriteCount,
            1,
            "one intent per entity: the delete replaced the pending create/update"
        )

        server.goOnline()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.presetInsertCount, 0, "the superseded create is never replayed")
        XCTAssertTrue(server.activePresets.isEmpty, "AC2: the removed entity is not resurrected")
        XCTAssertFalse(model.presets.contains { $0.id == preset.id })
        XCTAssertEqual(model.pendingCacheWriteCount, 0)

        // The identity is terminal now: a later write for it must not enqueue.
        let zombieAccepted = await model.savePreset(Self.preset(name: "Zombie", id: preset.id), isNew: true)
        XCTAssertFalse(
            zombieAccepted,
            "AC2: a completed removal terminalizes the identity"
        )
        XCTAssertEqual(model.queuedWriteCount, 0)
        XCTAssertFalse(model.presets.contains { $0.id == preset.id })
    }

    // MARK: - AC4: pending cache-only rows are adopted with provable intent

    @MainActor
    func testLegacyPendingPresetCacheRowIsAdoptedWithProvableIntent() async throws {
        // Pre-#916 residue: an optimistic cache row whose upload never
        // confirmed, with NO durable intent anywhere.
        let preset = Self.preset(name: "Legacy Row")
        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        try store.upsertLocal(
            preset,
            accountUserID: userID,
            entityType: .presets,
            entityID: CacheEntityID.preset(preset)
        )

        let server = FakeDirectWritePostgREST()
        server.goOffline()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        XCTAssertEqual(model.pendingCacheWriteCount, 1, "the legacy row is unsynced")
        XCTAssertTrue(model.presets.contains { $0.id == preset.id }, "and it is still visible")
        XCTAssertEqual(model.queuedWriteCount, 0, "but it has no replay intent yet")
        XCTAssertEqual(server.presetInsertCount, 0)

        server.goOnline()
        await model.drainQueue()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.presetInsertCount,
            1,
            "AC4: the row is adopted as a provable create and replayed once"
        )
        XCTAssertEqual(server.activePresets.count, 1)
        XCTAssertEqual(server.activePresets.first?["name"] as? String, "Legacy Row")
        XCTAssertEqual(
            model.pendingCacheWriteCount,
            0,
            "AC4: the adopted row is reconciled by the server's own answer"
        )
    }

    // MARK: - AC5: account scoping

    @MainActor
    func testQueuedPresetIntentForOneAccountIsInvisibleToAnother() async throws {
        let server = FakeDirectWritePostgREST()
        let owner = try await makeSignedInModel(server: server, userID: userID)
        await owner.refreshAll(showSpinner: false)

        server.goOffline()
        let ownerAccepted = await owner.savePreset(Self.preset(name: "Owner Only"), isNew: true)
        XCTAssertTrue(ownerAccepted)
        try await waitForQueueCount(owner, expected: 1)
        try await waitForRecordedAttempt(owner)

        // A second account in the same process: the queue file is shared on
        // disk, the entries are not.
        let other = try await makeSignedInModel(server: server, userID: UUID())
        server.goOnline()
        await other.retryAllQueuedWrites()

        XCTAssertEqual(other.queuedWriteCount, 0, "another account's queue is empty")
        XCTAssertEqual(other.pendingCacheWriteCount, 0, "and it owns no cache-only rows")
        XCTAssertEqual(other.presets.count, 0, "and it sees none of the first account's rows")
        XCTAssertEqual(
            server.presetInsertCount,
            0,
            "AC5: another account's drain must not execute the owner's intent"
        )

        // The owner's intent is still durable, and replays under its own account.
        await owner.retryAllQueuedWrites()
        try await waitForQueueCount(owner, expected: 0)
        XCTAssertEqual(server.presetInsertCount, 1)
        XCTAssertEqual(owner.presets.count, 1)
    }

    // MARK: - Model harness (mirrors TindeqSessionMergeAppTests seams)

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        for _ in 0..<400 {
            if model.queuedWriteCount == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue never reached \(expected); last observed \(model.queuedWriteCount)")
    }

    /// Waits until the queue item has recorded at least one failed attempt,
    /// i.e. the spawned upload has settled instead of racing the assertions.
    @MainActor
    private func waitForRecordedAttempt(_ model: AppModel) async throws {
        for _ in 0..<400 {
            if (model.queuedWriteDiagnostics.first?.attempts ?? 0) >= 1 { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the queue item never recorded an attempt")
    }

    private func waitForHeldRequest(_ server: FakeDirectWritePostgREST) async throws {
        for _ in 0..<600 {
            if server.isHoldingRequest { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the stubbed server never held the expected request")
    }

    @MainActor
    private func makeSupabaseClient(storage: any AuthLocalStorage) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: URL(string: "https://example.test")!,
            supabaseKey: "test-key",
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: storage,
                    autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    @MainActor
    private func makeRepository(session: Auth.Session, server: FakeDirectWritePostgREST) -> SendmeterRepository {
        let suite = "DirectWriteReplayAppTests.repo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = { session }
        return SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
    }

    @MainActor
    private func makeSignedInModel(
        server: FakeDirectWritePostgREST,
        userID: UUID? = nil
    ) async throws -> AppModel {
        let accountID = userID ?? self.userID
        let suite = "DirectWriteReplayAppTests.signed-in.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = InMemoryAuthStorage()
        let session = Self.makeSession(userID: accountID)
        try storage.store(
            key: "sb-example-auth-token",
            value: JSONEncoder().encode(session)
        )

        let client = makeSupabaseClient(storage: storage)
        let auth = AuthService(
            client: client,
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
        let model = AppModel(
            auth: auth,
            repository: makeRepository(session: session, server: server),
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession())
        )

        var waited = 0
        while model.currentUserID == nil, waited < 200 {
            waited += 1
            await Task.yield()
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
    }

    private static func makeSession(userID: UUID) -> Auth.Session {
        let payload = Data(#"{"session_id": "session-1", "iat": 1_000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let token = "header.\(payload).signature"
        let user = Auth.User(
            id: userID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return Auth.Session(
            accessToken: token,
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }

    // MARK: - On-disk state (the app container paths AppModel uses)

    private static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SendmeterNative", isDirectory: true)
    }

    private static func cacheDatabaseURL() -> URL {
        supportDirectory().appendingPathComponent("local-cache.sqlite", isDirectory: false)
    }

    /// The raw durable queue file: the evidence that the intent (account +
    /// entity identity + immutable mutation) is on disk before any acceptance.
    private static func queueFileContents() throws -> String {
        let url = supportDirectory().appendingPathComponent("pending-writes.json", isDirectory: false)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Fixtures

    private static func preset(name: String, id: UUID = UUID()) -> TindeqPreset {
        TindeqPreset(
            id: id,
            name: name,
            holdSeconds: 7,
            holdSecondsBySet: [7],
            repetitions: 6,
            sets: 3,
            restBetweenRepetitionsSeconds: 3,
            restBetweenSetsSeconds: 180,
            targetKilograms: 60,
            targetPercentage: 80,
            percentageBasis: .personalRecord,
            percentageStep: 2,
            setupNote: "fixture"
        )
    }

    private static func routine(name: String, id: UUID = UUID()) -> RoutinePreset {
        RoutinePreset(id: id, name: name, steps: [RoutineStep(label: "Hang", seconds: 20)])
    }
}

/// The stubbed backend for the direct-write tables: canned lists, server-minted
/// row ids on insert (exactly like `default gen_random_uuid()`), an offline
/// mode that fails at the transport layer, a "the write applied but the
/// acknowledgement was lost" mode, and a request hold so an in-flight
/// acknowledgement can be observed while newer local state exists.
private final class FakeDirectWritePostgREST: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    private let lock = NSLock()
    private let condition = NSCondition()
    private var presets: [[String: Any]] = []
    private var routines: [[String: Any]] = []
    private var presetInserts = 0
    private var routineInserts = 0
    private var online = true
    private var dropsNextInsertAcknowledgement = false
    private var pendingHolds = 0
    private var holding = false
    private var releaseGeneration = 0

    func goOffline() {
        lock.lock()
        online = false
        lock.unlock()
    }

    func goOnline() {
        lock.lock()
        online = true
        lock.unlock()
    }

    /// The server applies the next insert, then the response never arrives.
    func loseNextInsertAcknowledgement() {
        lock.lock()
        dropsNextInsertAcknowledgement = true
        lock.unlock()
    }

    func holdNextRequest() {
        condition.lock()
        pendingHolds += 1
        condition.unlock()
    }

    func releaseHeldRequest() {
        condition.lock()
        holding = false
        releaseGeneration += 1
        condition.broadcast()
        condition.unlock()
    }

    var isHoldingRequest: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holding
    }

    var presetInsertCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return self.presetInserts
    }

    var routineInsertCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return self.routineInserts
    }

    var activePresets: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return presets.filter { $0["deleted_at"] is NSNull }
    }

    var activeRoutines: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return routines.filter { $0["deleted_at"] is NSNull }
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDirectWriteProtocol.self]
        FakeDirectWriteProtocol.server = self
        return URLSession(configuration: configuration)
    }

    /// Nil means "fail at the transport layer" (offline, or a lost response).
    func reply(for request: URLRequest, body: Data?) -> Reply? {
        waitIfHolding()
        lock.lock()
        defer { lock.unlock() }
        guard online else { return nil }
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        let method = request.httpMethod ?? "GET"

        if path.hasSuffix("/tindeq_presets") {
            switch method {
            case "GET":
                return Reply(status: 200, body: Self.json(activePresetsLocked))
            case "POST":
                presetInserts += 1
                var row = Self.object(from: body) ?? [:]
                row["id"] = UUID().uuidString.lowercased()
                row["deleted_at"] = NSNull()
                row["updated_at"] = Self.timestamp()
                presets.append(row)
                if dropsNextInsertAcknowledgement {
                    dropsNextInsertAcknowledgement = false
                    return nil
                }
                return Reply(status: 201, body: Self.json([row]))
            case "PATCH":
                guard let id = Self.equalityID(from: query),
                      let index = presets.firstIndex(where: { ($0["id"] as? String) == id })
                else {
                    return Reply(status: 200, body: Data("[]".utf8))
                }
                var row = presets[index]
                for (key, value) in Self.object(from: body) ?? [:] {
                    row[key] = value
                }
                row["updated_at"] = Self.timestamp()
                presets[index] = row
                return Reply(status: 200, body: Self.json([row]))
            default:
                return Reply(status: 405, body: Data("[]".utf8))
            }
        }
        if path.hasSuffix("/routine_presets") {
            switch method {
            case "GET":
                return Reply(status: 200, body: Self.json(activeRoutinesLocked))
            case "POST":
                routineInserts += 1
                var row = Self.object(from: body) ?? [:]
                row["id"] = UUID().uuidString.lowercased()
                row["deleted_at"] = NSNull()
                row["updated_at"] = Self.timestamp()
                routines.append(row)
                if dropsNextInsertAcknowledgement {
                    dropsNextInsertAcknowledgement = false
                    return nil
                }
                return Reply(status: 201, body: Self.json([row]))
            case "PATCH":
                guard let id = Self.equalityID(from: query),
                      let index = routines.firstIndex(where: { ($0["id"] as? String) == id })
                else {
                    return Reply(status: 200, body: Data("[]".utf8))
                }
                var row = routines[index]
                for (key, value) in Self.object(from: body) ?? [:] {
                    row[key] = value
                }
                row["updated_at"] = Self.timestamp()
                routines[index] = row
                return Reply(status: 200, body: Self.json([row]))
            default:
                return Reply(status: 405, body: Data("[]".utf8))
            }
        }
        return Reply(status: 200, body: Data("[]".utf8))
    }

    private var activePresetsLocked: [[String: Any]] {
        presets.filter { $0["deleted_at"] is NSNull }
    }

    private var activeRoutinesLocked: [[String: Any]] {
        routines.filter { $0["deleted_at"] is NSNull }
    }

    private func waitIfHolding() {
        condition.lock()
        guard pendingHolds > 0 else {
            condition.unlock()
            return
        }
        pendingHolds -= 1
        holding = true
        condition.broadcast()
        let generation = releaseGeneration
        var waited = 0.0
        while holding, releaseGeneration == generation, waited < 10 {
            condition.wait(until: Date().addingTimeInterval(0.05))
            waited += 0.05
        }
        holding = false
        condition.unlock()
    }

    private static func object(from body: Data?) -> [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func json(_ rows: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
    }

    private static func equalityID(from query: String) -> String? {
        for item in query.split(separator: "&") {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "id" else { continue }
            let value = String(parts[1])
            return value.hasPrefix("eq.") ? String(value.dropFirst(3)) : value
        }
        return nil
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private final class FakeDirectWriteProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeDirectWritePostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands the body to URLProtocol as a stream, never as
        // `httpBody`; the JSON payload must be drained from the stream here.
        let body = Self.drain(request.httpBodyStream)
        guard let server = Self.server, let reply = server.reply(for: request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// In-memory auth storage (duplicated from the other app-target suites; those
/// copies are file-private).
private final class InMemoryAuthStorage: AuthLocalStorage {
    private var store: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        store[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        store[key]
    }

    func remove(key: String) throws {
        store.removeValue(forKey: key)
    }
}
