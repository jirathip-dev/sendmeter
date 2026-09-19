import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #919: interrupted health writes now carry a durable intent and are resolved
/// by REVALIDATION instead of a blind replay. These tests drive a REAL
/// `AppModel` (real cache, real durable queue, real repository, stubbed
/// PostgREST transport and stubbed HealthKit read) and prove the acceptance
/// criteria at the app boundary:
///
/// * AC1 persistence: the intended write is durable BEFORE the optimistic row
///   and before the server request, and a fresh model over the same on-disk
///   cache + queue (process death) resolves that exact pending revision —
///   without ever presenting it as synced while it is unproven;
/// * AC2 revalidation: a lost acknowledgement is recognised from the server's
///   own row (no second write), and a queued score that is OLDER than the
///   server's row is never sent over it;
/// * AC5 fault matrix: lost ack, newer server row, newer local revision;
/// * AC4 honesty: unavailable HealthKit, permanently rejected recovery, account
///   scoping.
final class HealthWriteRecoveryAppTests: XCTestCase {
    /// A fresh account per test: the cache and the pending-write queue are
    /// account-scoped files in the app container, so a shared user id would
    /// leak one test's rows into the next.
    private let userID = UUID()

    private var today: String {
        LocalDateSupport.string(from: Date(), timeZone: .current)
    }

    private var yesterday: String {
        LocalDateSupport.daysAgo(1)
    }

    // MARK: - AC1: durability boundary

    @MainActor
    func testInterruptedHealthWriteIsDurableBeforeItsRowAndReplaysAfterRelaunch() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([Self.metric(date: today, readiness: 63, hrv: 41.25)])
        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)

        // The write request dies at the transport layer before it is applied.
        server.rejectNextMutation(status: 500, code: "08006")
        await model.syncHealth(requestAuthorization: false)

        XCTAssertEqual(server.mutationCount, 0, "nothing reached the server")
        XCTAssertEqual(model.queuedWriteCount, 1, "the intent is queued, not lost")
        try await waitForQueueCount(model, expected: 1)

        // AC1: the account, the row date and the intended payload are on disk
        // before the pass could have reported anything as saved.
        let queueFile = try Self.queueFileContents()
        XCTAssertTrue(queueFile.contains(userID.uuidString), "the intent is scoped to this account")
        XCTAssertTrue(queueFile.contains(today), "the row identity (date) is persisted")
        XCTAssertTrue(queueFile.contains("63"), "the intended score is persisted")
        XCTAssertTrue(queueFile.contains("41.25"), "the intended biometric is persisted")

        // Process death: a fresh instance reads the same on-disk state.
        let relaunched = try await makeSignedInModel(server: server, readings: readings)
        await relaunched.refreshAll(showSpinner: false)
        XCTAssertEqual(relaunched.queuedWriteCount, 1, "the durable intent survives the restart")
        XCTAssertTrue(
            try Self.queueFileContents().contains(today),
            "the intent is still on disk after the restart"
        )

        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(
            server.mutationCount,
            1,
            "AC2: the interrupted write is re-derived and performed exactly once"
        )
        XCTAssertEqual(server.readiness(of: today), 63)
        XCTAssertEqual(relaunched.readiness?.readiness, 63, "the server's row is published")
        XCTAssertEqual(relaunched.pendingCacheWriteCount, 0, "no unsynced row is left behind")
    }

    // MARK: - AC5 fault matrix: lost acknowledgement

    @MainActor
    func testLostHealthWriteAcknowledgementIsRecognisedInsteadOfRepeated() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([Self.metric(date: today, readiness: 63, hrv: 41.25)])
        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)

        // The server APPLIES the write; only its response is lost.
        server.loseNextMutationAcknowledgement()
        await model.syncHealth(requestAuthorization: false)

        XCTAssertEqual(server.mutationCount, 1, "the server did apply the write")
        XCTAssertEqual(server.readiness(of: today), 63)
        try await waitForQueueCount(model, expected: 1)
        XCTAssertEqual(
            model.queuedWriteCount,
            1,
            "the intent stays durable: the acknowledgement never arrived"
        )

        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.mutationCount,
            1,
            "AC2/AC5: the recovery reads the server's own row and sends nothing"
        )
        XCTAssertEqual(model.readiness?.readiness, 63, "the landed row is adopted")
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    // MARK: - AC5 fault matrix: newer server row

    @MainActor
    func testQueuedHealthScoreNeverOverwritesANewerServerRow() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        // The queued pass scored an hour ago; the server moved on since.
        let readings = HealthReadingBox([
            Self.metric(
                date: today,
                readiness: 63,
                computedAt: Date().addingTimeInterval(-3_600),
                hrv: 41.25
            )
        ])
        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)

        server.rejectNextMutation(status: 500, code: "08006")
        await model.syncHealth(requestAuthorization: false)
        try await waitForQueueCount(model, expected: 1)
        XCTAssertEqual(server.mutationCount, 0)

        // A fresher row for the same date (the watch, or a later pass).
        server.seedMetric(
            Self.metric(
                date: today,
                readiness: 71,
                computedAt: Date(),
                hrv: 44.5
            )
        )

        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.mutationCount,
            0,
            "AC2/AC5: an older queued score must never be written over a newer row"
        )
        XCTAssertEqual(server.readiness(of: today), 71)
        XCTAssertEqual(
            model.readiness?.readiness,
            71,
            "the server's fresher reading is what the user sees"
        )
        XCTAssertEqual(model.pendingCacheWriteCount, 0, "the stale queued write is resolved, honestly")
    }

    // MARK: - AC5 fault matrix: newer local revision

    @MainActor
    func testInFlightRecoveryDoesNotClearANewerLocalRevision() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([
            Self.metric(
                date: today,
                readiness: 63,
                computedAt: Date().addingTimeInterval(-3_600),
                hrv: 41.25
            )
        ])
        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)

        server.rejectNextMutation(status: 500, code: "08006")
        await model.syncHealth(requestAuthorization: false)
        try await waitForQueueCount(model, expected: 1)

        // The older write's recovery is in flight…
        server.holdNextMutation()
        let replay = Task { await model.retryAllQueuedWrites() }
        try await waitForHeldMutation(server)

        // …while a NEWER pass writes the same date (a second foreground
        // refresh): a newer local revision that the older request must not
        // clear, overwrite or mark synced.
        readings.set([Self.metric(date: today, readiness: 71, hrv: 44.5)])
        await model.syncHealth(requestAuthorization: false)

        server.releaseHeldMutation()
        await replay.value
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            model.readiness?.readiness,
            71,
            "AC5: the older recovery's answer must not replace the newer local revision"
        )
        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        let cached = try store.loadOne(
            HealthMetric.self,
            accountUserID: userID,
            entityType: .healthMetrics,
            entityID: today
        )
        XCTAssertEqual(
            cached?.readiness,
            71,
            "AC5: the newer local revision is the row this device keeps"
        )
    }

    // MARK: - AC4: honest, account-scoped failure

    @MainActor
    func testAccountSwitchKeepsAHealthIntentScopedToItsOwnAccount() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([Self.metric(date: today, readiness: 63)])
        let owner = try await makeSignedInModel(server: server, readings: readings)

        server.rejectNextMutation(status: 500, code: "08006")
        await owner.syncHealth(requestAuthorization: false)
        try await waitForQueueCount(owner, expected: 1)

        // A different account signs in on the same device: it must not replay
        // this account's intent.
        let other = try await makeSignedInModel(
            server: server,
            readings: readings,
            userID: UUID()
        )
        await other.retryAllQueuedWrites()
        XCTAssertEqual(
            server.mutationCount,
            0,
            "another account can never replay this account's health write"
        )
        XCTAssertEqual(
            server.foreignRequestCount,
            0,
            "the other account never even asked to write this account's row"
        )
        XCTAssertEqual(other.queuedWriteCount, 0)

        server.resume()
        await owner.retryAllQueuedWrites()
        try await waitForQueueCount(owner, expected: 0)
        XCTAssertEqual(server.mutationCount, 1, "the owning account completes its own write")
        XCTAssertEqual(server.readiness(of: today), 63)
    }

    @MainActor
    func testUnavailableHealthKitLeavesNothingQueuedAndSurfacesTheFailure() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([Self.metric(date: today)])
        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)

        readings.fail(HealthKitStubError.unavailable)
        await model.syncHealth(requestAuthorization: false)

        XCTAssertEqual(
            model.queuedWriteCount,
            0,
            "a read that never produced a payload must not leave a replayable intent"
        )
        XCTAssertEqual(server.mutationCount, 0)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
        XCTAssertNotNil(model.errorMessage, "the failure is surfaced, never reported as synced")
    }

    @MainActor
    func testPermanentlyRejectedHealthRecoveryStaysVisibleAndNeverSilentlyCleared() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([Self.metric(date: today, readiness: 63)])
        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)

        server.rejectNextMutation(status: 500, code: "08006")
        await model.syncHealth(requestAuthorization: false)
        try await waitForQueueCount(model, expected: 1)

        // The server permanently refuses this payload on the retry path (the
        // explicit Settings' Retry, which bypasses the ordinary backoff).
        server.rejectNextMutation(status: 400, code: "PGRST102")
        await model.retryAllQueuedWrites()
        try await waitForClassifiedFailure(model, expected: .permanent)

        XCTAssertEqual(
            model.queuedWriteCount,
            1,
            "AC4: a rejected recovery stays visible on the device"
        )
        XCTAssertTrue(
            (model.quarantinedWrites ?? []).isEmpty,
            "an explicit retry never spends the bounded quarantine budget"
        )
        XCTAssertNil(server.readiness(of: today), "nothing partial was written")
        let queueFile = try Self.queueFileContents()
        XCTAssertTrue(
            queueFile.contains(today),
            "AC4: the rejected recovery's payload is preserved, never silently cleared"
        )
        XCTAssertEqual(
            server.mutationCount,
            0,
            "a permanently rejected payload never lands"
        )

        // The rejection is honest about what happened rather than inventing a
        // success, and the local row is NOT presented as synced.
        XCTAssertEqual(model.queuedWriteDiagnostics.first?.rejectionClass, .permanent)
        XCTAssertNil(model.readiness, "no unconfirmed reading is published")
    }

    // MARK: - AC1/AC2: an unproven write is never reported as synced

    @MainActor
    func testRecoveryThatCannotBeConfirmedStaysQueuedInsteadOfClaimingSync() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([Self.metric(date: today, readiness: 63)])
        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)

        server.rejectNextMutation(status: 500, code: "08006")
        await model.syncHealth(requestAuthorization: false)
        try await waitForQueueCount(model, expected: 1)

        // The write request reports success but the server never applied it:
        // the read-back is the only thing that can prove the end state.
        server.swallowNextMutation()
        await model.retryAllQueuedWrites()

        XCTAssertEqual(
            model.queuedWriteCount,
            1,
            "AC1: an unconfirmable write stays queued — never presented as synced"
        )
        XCTAssertNil(server.readiness(of: today), "the server really has no row")
        XCTAssertNotEqual(
            model.readiness?.readiness,
            63,
            "the unconfirmed payload is not published as an authoritative reading"
        )
        XCTAssertEqual(model.pendingCacheWriteCount, 0, "and nothing new is invented locally")
    }

    // MARK: - Residue (pre-#919 cache-only rows)

    @MainActor
    func testLegacyHealthResidueIsResolvedOnlyOnTheServerProof() async throws {
        let server = FakeHealthPostgREST(accountUserID: userID)
        let readings = HealthReadingBox([Self.metric(date: today)])
        // The server already serves today's row (a landed write whose
        // acknowledgement was lost before #919).
        let landed = Self.metric(date: today, readiness: 60, computedAt: Date(), hrv: 40)
        server.seedMetric(landed)
        // …and an authoritative row for an older date that the residue below
        // does NOT match.
        server.seedMetric(Self.metric(date: LocalDateSupport.daysAgo(2), readiness: 55, hrv: 39))

        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        // 1. A live residue the server already serves exactly: provable.
        try store.upsertLocal(
            landed,
            accountUserID: userID,
            entityType: .healthMetrics,
            entityID: landed.date
        )
        // 2. A live residue for a date the server serves nothing for: the only
        //    writer for that date, so it can be adopted safely.
        let absent = Self.metric(date: yesterday, readiness: 58, computedAt: Date(), hrv: 41)
        try store.upsertLocal(
            absent,
            accountUserID: userID,
            entityType: .healthMetrics,
            entityID: absent.date
        )
        // 3. A live residue whose date the server already serves differently:
        //    not provable, must stay visible.
        let conflicted = Self.metric(
            date: LocalDateSupport.daysAgo(2),
            readiness: 40,
            computedAt: Date().addingTimeInterval(-7_200),
            hrv: 30
        )
        try store.upsertLocal(
            conflicted,
            accountUserID: userID,
            entityType: .healthMetrics,
            entityID: conflicted.date
        )

        let model = try await makeSignedInModel(server: server, readings: readings)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(
            model.pendingCacheWriteCount,
            3,
            "fixture: the residue is visible before the sweep"
        )

        await model.drainQueue()

        XCTAssertEqual(
            model.pendingCacheWriteCount,
            1,
            "AC4: the provable residue is resolved; the unprovable row stays unsynced"
        )
        XCTAssertEqual(server.mutationCount, 1, "only the safe date is written")
        XCTAssertEqual(server.readiness(of: yesterday), 58)
        XCTAssertEqual(server.readiness(of: LocalDateSupport.daysAgo(2)), 55, "the conflicted date is untouched")
        let pendingIDs = try store.pendingEntityIDs(
            accountUserID: userID,
            entityType: .healthMetrics,
            includingDeleted: true
        )
        XCTAssertEqual(
            pendingIDs,
            [conflicted.date],
            "a residue the server does not prove stays exactly where it is"
        )
    }

    // MARK: - Harness

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        for _ in 0..<400 {
            if model.queuedWriteCount == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue count never reached \(expected) (still \(model.queuedWriteCount))")
    }

    @MainActor
    private func waitForClassifiedFailure(
        _ model: AppModel,
        expected: RejectionClass
    ) async throws {
        for _ in 0..<400 {
            if model.queuedWriteDiagnostics.first?.rejectionClass == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the queue never recorded a \(expected) failure")
    }

    private func waitForHeldMutation(_ server: FakeHealthPostgREST) async throws {
        for _ in 0..<600 {
            if server.isHoldingMutation { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the stubbed server never held the expected mutation")
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
    private func makeRepository(
        session: Auth.Session,
        server: FakeHealthPostgREST
    ) -> SendmeterRepository {
        let suite = "HealthWriteRecoveryAppTests.repo.\(UUID().uuidString)"
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
        server: FakeHealthPostgREST,
        readings: HealthReadingBox,
        userID: UUID? = nil
    ) async throws -> AppModel {
        let accountID = userID ?? self.userID
        let suite = "HealthWriteRecoveryAppTests.signed-in.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = InMemoryAuthStorage()
        let session = Self.makeSession(userID: accountID)
        try storage.store(
            key: "sb-example-auth-token",
            value: JSONEncoder().encode(session)
        )
        // A real HealthKit authorization can never be granted to a test host;
        // the write path itself does not need one, and the app must not try to
        // register background delivery during a unit test.
        UserDefaults.standard.set(false, forKey: "sendmeter.native.health-authorized")

        let client = makeSupabaseClient(storage: storage)
        let auth = AuthService(
            client: client,
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
        let health = HealthKitService()
        health.metricsReader = { _, _ in try readings.read() }
        let model = AppModel(
            auth: auth,
            repository: makeRepository(session: session, server: server),
            health: health,
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

    private static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SendmeterNative", isDirectory: true)
    }

    private static func cacheDatabaseURL() -> URL {
        supportDirectory().appendingPathComponent("local-cache.sqlite", isDirectory: false)
    }

    private static func queueFileContents() throws -> String {
        let url = supportDirectory().appendingPathComponent("pending-writes.json", isDirectory: false)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func metric(
        date: String,
        readiness: Int? = 60,
        zone: String? = "maintain",
        computedAt: Date = Date(),
        hrv: Double? = 40,
        rhr: Double? = 54.5,
        sleep: Double? = 7.25
    ) -> HealthMetric {
        HealthMetric(
            date: date,
            readiness: readiness,
            zone: zone,
            computedAt: computedAt,
            hrvSDNNMilliseconds: hrv,
            restingHeartRate: rhr,
            sleepHours: sleep,
            sleepDeepHours: sleep.map { _ in 1 },
            sleepREMHours: sleep.map { _ in 1.5 },
            bodyMassKilograms: 65,
            respiratoryRate: 13
        )
    }
}

private enum HealthKitStubError: Error {
    case unavailable
}

/// The deterministic HealthKit read the test drives (see
/// `HealthKitService.metricsReader`): the app's write path and recovery are the
/// production ones, only the read is stubbed.
private final class HealthReadingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[HealthMetric], Error>

    init(_ metrics: [HealthMetric]) {
        self.result = .success(metrics)
    }

    func set(_ metrics: [HealthMetric]) {
        lock.lock()
        result = .success(metrics)
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        result = .failure(error)
        lock.unlock()
    }

    func read() throws -> [HealthMetric] {
        lock.lock()
        defer { lock.unlock() }
        return try result.get()
    }
}

/// The stubbed `health_metrics` backend: the REST read, the atomic
/// insert-if-missing, and the #802 precedence RPC — plus the failure modes the
/// fault matrix needs (a request that dies, a lost acknowledgement, a request
/// that reports success without applying, a permanent rejection, and a hold so
/// an in-flight request can be observed while newer local state exists).
private final class FakeHealthPostgREST: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    /// The account this fake serves. Rows, counters and the armed failure modes
    /// are all scoped to it: a request for another account is answered as
    /// "invisible" (exactly as RLS makes it on the server) and can neither
    /// mutate this account's rows nor consume an armed mode. `foreignRequests`
    /// still counts them, so a test can prove another account never even asked.
    private let accountUserID: UUID
    private var foreignRequests = 0

    init(accountUserID: UUID) {
        self.accountUserID = accountUserID
    }

    private let lock = NSLock()
    private let condition = NSCondition()
    private var rows: [[String: Any]] = []
    private var mutations = 0
    private var rejectNextMutation: (status: Int, code: String)?
    private var dropNextMutationAcknowledgement = false
    private var swallowNextRequest = false
    private var pendingMutationHolds = 0
    private var holdingMutation = false
    private var releaseGeneration = 0

    // MARK: Control

    func resume() {
        lock.lock()
        rejectNextMutation = nil
        dropNextMutationAcknowledgement = false
        swallowNextRequest = false
        lock.unlock()
    }

    /// The next mutating request fails at the transport layer without applying.
    func rejectNextMutation(status: Int, code: String) {
        lock.lock()
        rejectNextMutation = (status, code)
        lock.unlock()
    }

    /// The next mutating request IS applied, then its response never arrives.
    func loseNextMutationAcknowledgement() {
        lock.lock()
        dropNextMutationAcknowledgement = true
        lock.unlock()
    }

    /// The next mutating request reports success but never applies.
    func swallowNextMutation() {
        lock.lock()
        swallowNextRequest = true
        lock.unlock()
    }

    func holdNextMutation() {
        condition.lock()
        pendingMutationHolds += 1
        condition.unlock()
    }

    func releaseHeldMutation() {
        condition.lock()
        holdingMutation = false
        releaseGeneration += 1
        condition.broadcast()
        condition.unlock()
    }

    var isHoldingMutation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holdingMutation
    }

    // MARK: Seeds / reads

    func seedMetric(_ metric: HealthMetric) {
        lock.lock()
        rows.removeAll { ($0["date"] as? String) == metric.date }
        rows.append(Self.row(for: metric))
        lock.unlock()
    }

    var mutationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mutations
    }

    var foreignRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return foreignRequests
    }

    func readiness(of date: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return rows.first { ($0["date"] as? String) == date }?["readiness"] as? Int
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHealthProtocol.self]
        FakeHealthProtocol.server = self
        return URLSession(configuration: configuration)
    }

    // MARK: Transport

    /// Nil means "fail at the transport layer" (offline, or a lost response).
    func reply(for request: URLRequest, body: Data?) -> Reply? {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"

        if path.hasSuffix("/health_metrics"), method == "GET" {
            lock.lock()
            defer { lock.unlock() }
            return Reply(status: 200, body: Self.json(rows))
        }
        if path.hasSuffix("/health_metrics"), method == "POST" {
            return mutate(
                body: body,
                work: { payload in
                    guard let date = payload["date"] as? String else { return Data("[]".utf8) }
                    if self.rows.contains(where: { ($0["date"] as? String) == date }) {
                        // resolution=ignore-duplicates: nothing was inserted.
                        return Data("[]".utf8)
                    }
                    self.rows.append(Self.row(fromUpsert: payload, date: date))
                    return Self.json([["date": date]])
                },
                swallowed: { _ in
                    // Reported as inserted without a row ever existing.
                    Data("[]".utf8)
                }
            )
        }
        if path.hasSuffix("/rpc/upsert_health_metrics_with_precedence") {
            return mutate(
                body: body,
                work: { payload in
                    let date = payload["p_date"] as? String ?? ""
                    var row = self.rows.first { ($0["date"] as? String) == date } ?? [:]
                    let columns: [(String, String)] = [
                        ("p_hrv_sdnn_ms", "hrv_sdnn_ms"),
                        ("p_resting_hr", "resting_hr"),
                        ("p_sleep_hours", "sleep_hours"),
                        ("p_sleep_deep_hours", "sleep_deep_hours"),
                        ("p_sleep_rem_hours", "sleep_rem_hours"),
                        ("p_body_mass_kg", "body_mass_kg"),
                        ("p_resp_rate_bpm", "resp_rate_bpm"),
                        ("p_readiness", "readiness"),
                        ("p_zone", "zone"),
                        ("p_computed_at", "computed_at"),
                    ]
                    for (parameter, column) in columns {
                        guard let value = payload[parameter], !(value is NSNull) else { continue }
                        row[column] = value
                    }
                    row["date"] = date
                    row["computed_at"] = row["computed_at"] ?? Self.timestamp(Date())
                    row["updated_at"] = Self.timestamp(Date())
                    self.rows.removeAll { ($0["date"] as? String) == date }
                    self.rows.append(row)
                    return Self.json([[
                        "decision": "updated",
                        "date": date,
                        "readiness": row["readiness"] ?? NSNull(),
                        "zone": row["zone"] ?? NSNull(),
                        "computed_at": row["computed_at"] ?? NSNull(),
                    ]])
                },
                swallowed: { payload in
                    // A well-formed answer that admits nothing was written:
                    // the recovery must fall through to its read-back.
                    Self.json([[
                        "decision": "discarded",
                        "date": payload["p_date"] as? String ?? "",
                        "readiness": NSNull(),
                        "zone": NSNull(),
                        "computed_at": NSNull(),
                    ]])
                }
            )
        }
        lock.lock()
        defer { lock.unlock() }
        // Every other table the repository syncs during `refreshAll` is empty
        // for these tests (there are no sessions to load).
        return Reply(status: 200, body: Data("[]".utf8))
    }

    /// One mutating request. `nil` means its response never arrived — the write
    /// itself may still have landed, which is exactly the interruption the
    /// recovery has to resolve.
    private func mutate(
        body: Data?,
        work: ([String: Any]) -> Data,
        swallowed: ([String: Any]) -> Data
    ) -> Reply? {
        let payload = Self.object(from: body) ?? [:]
        guard Self.account(from: payload) == accountUserID else {
            lock.lock()
            foreignRequests += 1
            lock.unlock()
            return Reply(status: 200, body: swallowed(payload))
        }
        condition.lock()
        if pendingMutationHolds > 0 {
            pendingMutationHolds -= 1
            holdingMutation = true
            condition.broadcast()
            let generation = releaseGeneration
            var waited = 0.0
            while holdingMutation, releaseGeneration == generation, waited < 10 {
                condition.wait(until: Date().addingTimeInterval(0.05))
                waited += 0.05
            }
            holdingMutation = false
        }
        condition.unlock()
        lock.lock()
        defer { lock.unlock() }
        if let rejection = rejectNextMutation {
            rejectNextMutation = nil
            return Reply(status: rejection.status, body: Self.errorBody(code: rejection.code))
        }
        if swallowNextRequest {
            swallowNextRequest = false
            return Reply(status: 200, body: swallowed(payload))
        }
        mutations += 1
        let responseBody = work(payload)
        if dropNextMutationAcknowledgement {
            dropNextMutationAcknowledgement = false
            return nil
        }
        return Reply(status: 201, body: responseBody)
    }

    // MARK: Encoding

    private static func row(for metric: HealthMetric) -> [String: Any] {
        var row: [String: Any] = [
            "date": metric.date,
            "readiness": metric.readiness ?? NSNull(),
            "zone": metric.zone ?? NSNull(),
            "computed_at": timestamp(metric.computedAt ?? Date()),
            "hrv_sdnn_ms": metric.hrvSDNNMilliseconds ?? NSNull(),
            "resting_hr": metric.restingHeartRate ?? NSNull(),
            "sleep_hours": metric.sleepHours ?? NSNull(),
            "sleep_deep_hours": metric.sleepDeepHours ?? NSNull(),
            "sleep_rem_hours": metric.sleepREMHours ?? NSNull(),
            "body_mass_kg": metric.bodyMassKilograms ?? NSNull(),
            "resp_rate_bpm": metric.respiratoryRate ?? NSNull(),
            "updated_at": timestamp(Date()),
        ]
        row["date"] = metric.date
        return row
    }

    private static func row(fromUpsert payload: [String: Any], date: String) -> [String: Any] {
        [
            "date": date,
            "readiness": payload["readiness"] ?? NSNull(),
            "zone": payload["zone"] ?? NSNull(),
            "computed_at": payload["computed_at"] ?? timestamp(Date()),
            "hrv_sdnn_ms": payload["hrv_sdnn_ms"] ?? NSNull(),
            "resting_hr": payload["resting_hr"] ?? NSNull(),
            "sleep_hours": payload["sleep_hours"] ?? NSNull(),
            "sleep_deep_hours": payload["sleep_deep_hours"] ?? NSNull(),
            "sleep_rem_hours": payload["sleep_rem_hours"] ?? NSNull(),
            "body_mass_kg": payload["body_mass_kg"] ?? NSNull(),
            "resp_rate_bpm": payload["resp_rate_bpm"] ?? NSNull(),
            "updated_at": timestamp(Date()),
        ]
    }

    private static func json(_ rows: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
    }

    private static func account(from payload: [String: Any]) -> UUID? {
        if let value = payload["p_user_id"] as? String {
            return UUID(uuidString: value)
        }
        if let value = payload["user_id"] as? String {
            return UUID(uuidString: value)
        }
        return nil
    }

    private static func object(from body: Data?) -> [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func errorBody(code: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "message": "health write refused",
            "details": NSNull(),
            "hint": NSNull(),
        ])) ?? Data("{}".utf8)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private final class FakeHealthProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeHealthPostgREST?

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
