import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #920 + #923 at the app boundary: a REAL `AppModel` against a stubbed
/// PostgREST transport that can fail ONE entity, hold a request, and serve
/// per-table rows.
///
/// * #920: the pending/sync status is derived from acknowledged answers (the
///   dispatch exercises `retryAllQueuedWrites`, the button's action, not a
///   label match), a cache-only residue is really retried, a residue the retry
///   cannot move is explained instead of silently no-op'ing, and a double tap
///   coalesces onto one pass.
/// * #923: one slice failing does not stop its siblings publishing, a
///   dependent pair is never half-published, a failed slice keeps last-good
///   data plus pending local overlays, and its cursor does not advance.
final class SyncSurfacesAppTests: XCTestCase {
    /// A fresh account per test: the cache and the pending-write queue are
    /// account-scoped files in the app container, so a shared user id would
    /// leak one test's rows into the next.
    private let userID = UUID()
    private let today = LocalDateSupport.string(from: Date())

    // MARK: - #920 AC1: an unread zero count is never "Synced"

    @MainActor
    func testSignedOutStatusIsCheckingRatherThanSynced() async throws {
        let server = SyncSurfacesFakePostgREST()
        let model = try await makeModel(server: server, signedIn: false)
        let status = model.mutationSyncStatus
        XCTAssertNil(model.currentUserID, "fixture: this model is signed out")
        XCTAssertEqual(model.queuedWriteCount, 0)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
        XCTAssertEqual(
            status.state,
            .notLoaded,
            "zero counts that were never read are not a sync claim"
        )
        XCTAssertEqual(status.statusLabel, "Checking…")
        XCTAssertEqual(status.retry, .hidden)
    }

    // MARK: - #920 AC2/AC3/AC5: the visible Retry really retries cache-only work

    @MainActor
    func testCacheOnlyResidueIsUploadedByTheRetryDispatch() async throws {
        let server = SyncSurfacesFakePostgREST()
        // A pre-#916 residue: an unconfirmed local row with no durable intent
        // (the server has nothing under that id).
        let residue = Self.preset(name: "Residue Hang")
        try writeResidue(
            residue,
            entityType: .presets,
            entityID: CacheEntityID.preset(residue)
        )
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)

        XCTAssertEqual(model.queuedWriteCount, 0, "fixture: the residue has no queue entry")
        XCTAssertEqual(model.pendingCacheWriteCount, 1)
        let before = model.mutationSyncStatus
        XCTAssertEqual(before.state, .awaitingUpload)
        XCTAssertEqual(before.statusLabel, "1 waiting to upload")
        XCTAssertEqual(
            before.retry,
            .ready,
            "a residue whose adoption has not been attempted is retryable"
        )

        // The dispatch a user gets by tapping Retry Now.
        await model.retryAllQueuedWrites()

        XCTAssertEqual(
            server.count(of: "tindeq_presets", method: "POST"),
            1,
            "the residue really reached the server through the retry path"
        )
        XCTAssertEqual(model.pendingCacheWriteCount, 0, "and it is no longer unconfirmed")
        XCTAssertEqual(model.mutationSyncStatus.state, .synced)
        XCTAssertEqual(model.lastRetryOutcome?.unsyncedAfter, 0)
        XCTAssertEqual(model.lastRetryOutcome?.unresolvedResidueCount, 0)
        XCTAssertFalse(model.isRetryingQueuedWrites, "the pass released its scope")
    }

    @MainActor
    func testResidueARetryCannotMoveIsExplainedInsteadOfSilentlyNoOped() async throws {
        let server = SyncSurfacesFakePostgREST()
        // A pre-#917 phase residue: a live period the server does not serve
        // plus a settings row that disagrees with it. The adopter resolves
        // NOTHING on the server's own answer, and the phase/settings writer is
        // a transition, so no retry can upload this pair.
        let period = PhasePeriod(
            id: UUID(),
            phase: .strength,
            startedOn: today,
            endedOn: nil
        )
        try writeResidue(
            period,
            entityType: .phasePeriods,
            entityID: period.id.uuidString.lowercased()
        )
        try writeResidue(
            UserSettings(currentPhase: .strength, phaseStartDate: today),
            entityType: .settings,
            entityID: CacheEntityID.settings
        )
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(model.pendingCacheWriteCount, 2)
        XCTAssertEqual(model.mutationSyncStatus.retry, .ready)

        await model.retryAllQueuedWrites()

        XCTAssertEqual(model.queuedWriteCount, 0)
        XCTAssertEqual(
            model.pendingCacheWriteCount,
            2,
            "no local change is dropped to make the status look clean"
        )
        let outcome = try XCTUnwrap(model.lastRetryOutcome)
        XCTAssertEqual(outcome.unresolvedResidueCount, 2)
        XCTAssertFalse(outcome.changedAnything)
        let status = model.mutationSyncStatus
        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.statusLabel, "2 stayed on this iPhone")
        XCTAssertEqual(
            status.retry,
            .unavailable(.noUploadPath),
            "the visible retry is disabled for work it cannot retry"
        )
        let explanation = try XCTUnwrap(status.retryUnavailableExplanation)
        XCTAssertTrue(explanation.contains("Retrying cannot move"))

        // A second tap does not quietly re-run the once-per-account sweep and
        // pretend something happened.
        let fetchesAfterFirstPass = server.count(of: "phase_periods")
        await model.retryAllQueuedWrites()
        XCTAssertEqual(
            server.count(of: "phase_periods"),
            fetchesAfterFirstPass,
            "the exhausted adopter is not re-run as a silent no-op"
        )
        XCTAssertEqual(model.mutationSyncStatus.retry, .unavailable(.noUploadPath))
    }

    @MainActor
    func testDoubleTapCoalescesOntoTheRunningPass() async throws {
        let server = SyncSurfacesFakePostgREST()
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        // A cache-only preset residue so the pass's first request is the
        // adopter's authoritative preset list.
        let residue = Self.preset(name: "Residue Hang")
        try writeResidue(
            residue,
            entityType: .presets,
            entityID: CacheEntityID.preset(residue)
        )
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)

        server.holdNextRequest(table: "tindeq_presets")
        let first = Task { await model.retryAllQueuedWrites() }
        try await waitForHeldRequest(server)
        XCTAssertTrue(model.isRetryingQueuedWrites, "the pass published its progress")
        XCTAssertEqual(model.mutationSyncStatus.retry, .inFlight)

        let listsDuringFirstPass = server.count(of: "tindeq_presets")
        await model.retryAllQueuedWrites() // the double tap
        XCTAssertEqual(
            server.count(of: "tindeq_presets"),
            listsDuringFirstPass,
            "the second tap coalesces instead of starting a second pass"
        )

        server.releaseHeldRequest()
        await first.value
        try await waitForStatus(model) { $0.state == .synced }
        XCTAssertEqual(server.count(of: "tindeq_presets", method: "POST"), 1,
                       "the adopted residue lands exactly once")
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    @MainActor
    func testQueuedAndUnsyncedWorkStaysScopedToItsAccount() async throws {
        let server = SyncSurfacesFakePostgREST()
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        let ownerID = UUID()
        let owner = try await makeModel(server: server, userID: ownerID)
        await owner.refreshAll(showSpinner: false)

        server.goOffline()
        let accepted = await owner.savePreset(Self.preset(name: "Owner Hang"), isNew: true)
        XCTAssertTrue(accepted)
        try await waitForQueueCount(owner, expected: 1)
        let ownerStatus = owner.mutationSyncStatus
        XCTAssertEqual(ownerStatus.state, .awaitingUpload)
        XCTAssertGreaterThanOrEqual(ownerStatus.pendingCount, 1)
        XCTAssertNotEqual(ownerStatus.statusLabel, "Synced")

        // A different account signs in on the same device: its retry pass must
        // not touch the first account's queue, and the outcome it publishes is
        // stamped with ITS account so no screen can show it as the owner's.
        let other = try await makeModel(server: server, userID: UUID())
        await other.retryAllQueuedWrites()
        XCTAssertEqual(owner.queuedWriteCount, 1, "the other account cannot drain this queue")
        XCTAssertEqual(other.lastRetryOutcome?.accountUserID, other.currentUserID)
        XCTAssertNotEqual(other.lastRetryOutcome?.accountUserID, ownerID)

        server.goOnline()
        await owner.retryAllQueuedWrites()
        try await waitForQueueCount(owner, expected: 0)
        XCTAssertEqual(owner.mutationSyncStatus.state, .synced)
        XCTAssertEqual(server.count(of: "tindeq_presets", method: "POST"), 1)
    }

    // MARK: - #923 AC1: an unrelated failure no longer discards its siblings

    @MainActor
    func testFailingSliceKeepsLastGoodDataWhileSiblingsPublish() async throws {
        let server = SyncSurfacesFakePostgREST()
        let firstSession = Self.sessionRow(date: today, id: UUID())
        server.setRows("sessions", [firstSession])
        server.setRows("health_metrics", [Self.healthRow(date: today, readiness: 63)])
        // A settings row so the first-sync create-default path is not in play
        // (this test is about slice independence, not the default row).
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        // An older cursor for both slices, so "did this slice's freshness
        // advance?" is a real question for each of them.
        try seedCursor(entityType: .sessions)
        try seedCursor(entityType: .healthMetrics)
        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        let workspace = CachedWorkspace(store: store)

        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(model.sessions.count, 1, "fixture: the first sync landed")
        XCTAssertEqual(model.readiness?.readiness, 63)
        XCTAssertNil(
            model.lastPartialRefreshFailure,
            "everything reconciled — served requests: \(server.dumpRequests())"
        )
        let sessionsCursorBefore = try workspace.cursor(
            accountUserID: userID,
            entityType: .sessions
        )
        let healthCursorBefore = try workspace.cursor(
            accountUserID: userID,
            entityType: .healthMetrics
        )
        XCTAssertNotNil(sessionsCursorBefore, "fixture: the sessions slice has a cursor")

        // One entity fails while an independent one has new data.
        let secondSession = Self.sessionRow(date: today, id: UUID())
        server.setRows("sessions", [firstSession, secondSession])
        server.setRows("health_metrics", [
            Self.healthRow(
                date: today,
                readiness: 71,
                updatedAt: Self.timestamp(secondsLater: 60)
            )
        ])
        server.failRequests(to: "health_metrics")
        await model.refreshAll()

        XCTAssertEqual(model.sessions.count, 2, "the sessions slice published its new row")
        XCTAssertEqual(
            model.readiness?.readiness,
            63,
            "the failed slice keeps its last-good data instead of being blanked"
        )
        XCTAssertTrue(model.hasLoadedSessions)
        let summary = try XCTUnwrap(model.lastPartialRefreshFailure)
        XCTAssertEqual(summary.groups, [.healthMetrics])
        XCTAssertEqual(summary.accountUserID, model.currentUserID)
        XCTAssertEqual(summary.source, .userInitiated)
        XCTAssertNil(
            model.errorMessage,
            "a partial failure is not the total-offline banner while usable data is on screen"
        )
        XCTAssertNotNil(model.dashboardLoadFailureClass, "#964 keeps its own failure state")

        // Per-entity freshness: only the slice that COMPLETED reconciliation
        // advances its own cursor.
        let sessionsCursorAfter = try workspace.cursor(
            accountUserID: userID,
            entityType: .sessions
        )
        let healthCursorAfter = try workspace.cursor(
            accountUserID: userID,
            entityType: .healthMetrics
        )
        XCTAssertNotEqual(
            sessionsCursorAfter,
            sessionsCursorBefore,
            "the successfully reconciled slice advanced its own cursor"
        )
        XCTAssertEqual(
            healthCursorAfter,
            healthCursorBefore,
            "the failed slice's cursor did not advance"
        )

        // Healing the slice clears the scoped failure on a full pass.
        server.healRequests(to: "health_metrics")
        await model.refreshAll()
        XCTAssertNil(model.lastPartialRefreshFailure)
        XCTAssertEqual(model.readiness?.readiness, 71, "the healed slice publishes again")
        XCTAssertEqual(model.sessions.count, 2, "and never duplicates the published rows")
    }

    @MainActor
    func testFailedSliceKeepsPendingLocalOverlays() async throws {
        let server = SyncSurfacesFakePostgREST()
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)

        server.goOffline()
        let pendingPreset = Self.preset(name: "Offline Hang")
        let accepted = await model.savePreset(pendingPreset, isNew: true)
        XCTAssertTrue(accepted)
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        server.goOnline()
        server.failRequests(to: "tindeq_presets")
        await model.refreshAll()

        XCTAssertTrue(
            model.presets.contains { $0.id == pendingPreset.id },
            "the failed slice keeps the pending local overlay"
        )
        XCTAssertEqual(model.pendingCacheWriteCount, 1, "and it stays visibly unsynced")
        XCTAssertEqual(model.lastPartialRefreshFailure?.groups, [.presets])
    }

    // MARK: - #923 AC2: a dependent pair never publishes half

    @MainActor
    func testSettingsAndPhasePairNeverPublishesHalf() async throws {
        let server = SyncSurfacesFakePostgREST()
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        server.setRows("phase_periods", [Self.periodRow(phase: "capacity", startedOn: today)])
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(model.settings.currentPhase, .capacity)
        XCTAssertNil(model.lastPartialRefreshFailure)

        // The server moves to a new block, but the period slice fails. The
        // moved rows are stamped ahead of the cursor they are compared with.
        server.setRows("user_settings", [
            Self.settingsRow(
                phase: "strength",
                start: today,
                updatedAt: Self.timestamp(secondsLater: 60)
            )
        ])
        server.setRows("phase_periods", [
            Self.periodRow(
                phase: "strength",
                startedOn: today,
                updatedAt: Self.timestamp(secondsLater: 60)
            )
        ])
        server.failRequests(to: "phase_periods")
        await model.refreshAll()

        XCTAssertEqual(
            model.settings.currentPhase,
            .capacity,
            "the settings half of the pair is NOT published without its periods"
        )
        XCTAssertEqual(model.lastPartialRefreshFailure?.groups, [.settingsAndPhase])

        // Both halves together publish.
        server.healRequests(to: "phase_periods")
        await model.refreshAll()
        XCTAssertEqual(model.settings.currentPhase, .strength)
        XCTAssertTrue(
            model.phasePeriods.contains { $0.phase == .strength },
            "the moved block's period published with its settings row"
        )
        XCTAssertNil(model.lastPartialRefreshFailure)
    }

    // MARK: - #923 AC4: total failure still escalates; cancellation publishes nothing

    @MainActor
    func testAllSlicesFailingKeepsTheUserInitiatedBanner() async throws {
        let server = SyncSurfacesFakePostgREST()
        let model = try await makeModel(server: server)
        server.goOffline()
        await model.refreshAll()

        XCTAssertNotNil(model.errorMessage, "a total blackout on an explicit load still surfaces")
        XCTAssertNotNil(model.dashboardLoadFailureClass)
        XCTAssertTrue(model.showsDashboardLoadFailure, "#964 state is preserved")
        XCTAssertFalse(model.hasLoadedSessions)
        let summary = try XCTUnwrap(model.lastPartialRefreshFailure)
        XCTAssertEqual(summary.groups.count, RefreshConsistencyGroup.allCases.count)
    }

    @MainActor
    func testCancelledPassPublishesNothingAndReportsNothing() async throws {
        let server = SyncSurfacesFakePostgREST()
        server.setRows("sessions", [Self.sessionRow(date: today, id: UUID())])
        let model = try await makeModel(server: server)

        server.holdNextRequest(table: "sessions")
        let refresh = Task { await model.refreshAll(showSpinner: false) }
        try await waitForHeldRequest(server)
        refresh.cancel()
        server.releaseHeldRequest()
        await refresh.value

        XCTAssertTrue(model.sessions.isEmpty, "a cancelled pass publishes nothing")
        XCTAssertFalse(model.hasLoadedSessions)
        XCTAssertNil(model.errorMessage, "and it is not reported as a failure")
        XCTAssertNil(model.lastPartialRefreshFailure)
        XCTAssertNil(model.dashboardLoadFailureClass)
    }

    @MainActor
    func testTimedOutSliceKeepsItsSiblingsPublishing() async throws {
        let server = SyncSurfacesFakePostgREST()
        server.setRows("sessions", [Self.sessionRow(date: today, id: UUID())])
        server.setRows("health_metrics", [Self.healthRow(date: today, readiness: 63)])
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)

        server.timeoutRequests(to: "health_metrics")
        await model.refreshAll()

        XCTAssertEqual(model.sessions.count, 1, "a timed-out entity does not cancel its siblings")
        XCTAssertEqual(model.readiness?.readiness, 63)
        XCTAssertEqual(model.lastPartialRefreshFailure?.groups, [.healthMetrics])
        XCTAssertEqual(model.lastPartialRefreshFailure?.source, .userInitiated)
        XCTAssertNil(model.errorMessage, "the total-offline copy would be false")
    }

    @MainActor
    func testAuthRejectedSliceStillPublishesAndHeals() async throws {
        let server = SyncSurfacesFakePostgREST()
        server.setRows("sessions", [Self.sessionRow(date: today, id: UUID())])
        server.setRows("health_metrics", [Self.healthRow(date: today, readiness: 63)])
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)

        server.rejectRequests(to: "health_metrics", status: 401)
        await model.refreshAll()
        // Read the synchronous outcomes BEFORE the recovery task gets the
        // MainActor: the recovery may clear the session, and that is the
        // healing this test is looking for.
        XCTAssertEqual(
            model.sessions.count,
            1,
            "a rejected bearer on one slice does not cancel the other slices"
        )
        XCTAssertEqual(model.lastPartialRefreshFailure?.groups, [.healthMetrics])
        XCTAssertNil(model.errorMessage)

        // #842's rule applied per slice: the exact-session recovery runs for a
        // rejected slice even though its failure was not the banner's.
        let healed = await waitForAuthRecoverySignal(model)
        XCTAssertTrue(healed, "the rejected slice never triggered the auth recovery")
    }

    @MainActor
    private func waitForAuthRecoverySignal(_ model: AppModel) async -> Bool {
        for _ in 0..<600 {
            if model.currentUserID == nil { return true }
            if model.authEventLog.contains(where: { $0.detail?.contains("401") ?? false }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    // MARK: - Harness

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        for _ in 0..<400 {
            if model.queuedWriteCount == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue never reached \(expected); last observed \(model.queuedWriteCount)")
    }

    @MainActor
    private func waitForStatus(
        _ model: AppModel,
        _ predicate: (MutationSyncStatus) -> Bool
    ) async throws {
        for _ in 0..<400 {
            if predicate(model.mutationSyncStatus) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("status never matched; last observed \(model.mutationSyncStatus.state)")
    }

    @MainActor
    private func waitForRecordedAttempt(_ model: AppModel) async throws {
        for _ in 0..<400 {
            if (model.queuedWriteDiagnostics.first?.attempts ?? 0) >= 1 { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the queue item never recorded an attempt")
    }

    private func waitForHeldRequest(_ server: SyncSurfacesFakePostgREST) async throws {
        for _ in 0..<600 {
            if server.isHoldingRequest { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the stubbed server never held the expected request")
    }

    @MainActor
    private func makeModel(
        server: SyncSurfacesFakePostgREST,
        userID: UUID? = nil,
        signedIn: Bool = true
    ) async throws -> AppModel {
        let suite = "SyncSurfacesAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = SyncSurfacesInMemoryAuthStorage()
        let session = Self.makeSession(userID: userID ?? self.userID)
        if signedIn {
            try storage.store(
                key: "sb-example-auth-token",
                value: JSONEncoder().encode(session)
            )
        }
        let client = SupabaseClient(
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
        let auth = AuthService(
            client: client,
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
        let provider: (@Sendable () async throws -> Auth.Session) = { session }
        let repository = SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
        let model = AppModel(
            auth: auth,
            repository: repository,
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession())
        )
        guard signedIn else { return model }
        var waited = 0
        while model.currentUserID == nil, waited < 400 {
            waited += 1
            await Task.yield()
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
    }

    /// Writes an unconfirmed cache row for this account with no durable intent
    /// behind it — exactly the residue an older app version leaves.
    private func writeResidue<Value: Encodable>(
        _ value: Value,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws {
        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        try store.upsertLocal(
            value,
            accountUserID: userID,
            entityType: entityType,
            entityID: entityID
        )
    }

    /// Seeds an older cursor so a slice starts out incremental — which makes
    /// "did THIS slice's freshness advance?" a value a test can compare.
    private func seedCursor(entityType: LocalCacheEntityType) throws {
        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        try CachedWorkspace(store: store).setCursor(
            "2020-01-01T00:00:00.000Z",
            accountUserID: userID,
            entityType: entityType
        )
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

    // MARK: - Fixtures

    private static func metric(date: String, readiness: Int) -> HealthMetric {
        HealthMetric(
            date: date,
            readiness: readiness,
            zone: "recover",
            computedAt: Date(),
            hrvSDNNMilliseconds: 41.25,
            restingHeartRate: 50,
            sleepHours: 7.5,
            sleepDeepHours: 1.1,
            sleepREMHours: 1.6,
            bodyMassKilograms: 70,
            respiratoryRate: 14
        )
    }

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

    private static func timestamp(secondsLater: TimeInterval = 0) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(secondsLater))
    }

    private static func sessionRow(date: String, id: UUID) -> [String: Any] {
        [
            "id": id.uuidString.lowercased(),
            "date": date,
            "type": "tindeq",
            "type_label": "Tindeq",
            "duration_min": 45,
            "rpe": 7.5,
            "rpe_confirmed": true,
            "load": 337.5,
            "note": NSNull(),
            "phase": "capacity",
            "group_id": NSNull(),
            "workout_source": NSNull(),
            "updated_at": timestamp(),
            "deleted_at": NSNull(),
        ]
    }

    private static func healthRow(
        date: String,
        readiness: Int,
        updatedAt: String? = nil
    ) -> [String: Any] {
        [
            "date": date,
            "readiness": readiness,
            "zone": "recover",
            "computed_at": timestamp(),
            "hrv_sdnn_ms": 41.25,
            "resting_hr": 50,
            "sleep_hours": 7.5,
            "sleep_deep_hours": 1.1,
            "sleep_rem_hours": 1.6,
            "body_mass_kg": 70,
            "resp_rate_bpm": 14,
            "updated_at": updatedAt ?? timestamp(),
        ]
    }

    /// One settings row. The user id is fixed (the table's identity is the
    /// signed-in user; the cache keys settings by a constant), and a changed
    /// row must carry a strictly later stamp than the cursor it is compared
    /// against, so callers pass `updatedAt` when they move the row.
    private static func settingsRow(
        phase: String,
        start: String,
        updatedAt: String? = nil
    ) -> [String: Any] {
        [
            "user_id": "11111111-1111-1111-1111-111111111111",
            "current_phase": phase,
            "phase_start_date": start,
            "updated_at": updatedAt ?? timestamp(),
        ]
    }

    private static func periodRow(
        phase: String,
        startedOn: String,
        updatedAt: String? = nil
    ) -> [String: Any] {
        [
            "id": UUID().uuidString.lowercased(),
            "phase": phase,
            "started_on": startedOn,
            "ended_on": NSNull(),
            "updated_at": updatedAt ?? timestamp(),
            "deleted_at": NSNull(),
        ]
    }
}

/// One stubbed PostgREST backend: canned per-table rows, a per-table failure
/// switch (transport-level, like a real unreachable request), a request hold,
/// and a request log so a test can assert WHICH slices were fetched with which
/// cursor.
final class SyncSurfacesFakePostgREST: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    private let lock = NSLock()
    private let condition = NSCondition()
    private var online = true
    private var failingTables: Set<String> = []
    private var timingOutTables: Set<String> = []
    private var rejectionStatus: [String: Int] = [:]
    private var tables: [String: [[String: Any]]] = [:]
    private var requests: [(table: String, query: String, method: String)] = []
    private var holdTable: String?
    private var holding = false
    private var releaseGeneration = 0

    func setRows(_ table: String, _ rows: [[String: Any]]) {
        lock.lock()
        tables[table] = rows
        lock.unlock()
    }

    func failRequests(to table: String) {
        lock.lock()
        failingTables.insert(table)
        lock.unlock()
    }

    func healRequests(to table: String) {
        lock.lock()
        failingTables.remove(table)
        lock.unlock()
    }

    /// The slice fails with a transport-level TIMEOUT rather than an
    /// unreachable host.
    func timeoutRequests(to table: String) {
        lock.lock()
        timingOutTables.insert(table)
        lock.unlock()
    }

    /// The slice answers with a real HTTP rejection (e.g. a rejected bearer).
    func rejectRequests(to table: String, status: Int) {
        lock.lock()
        rejectionStatus[table] = status
        lock.unlock()
    }

    func healRejections(to table: String) {
        lock.lock()
        rejectionStatus[table] = nil
        lock.unlock()
    }

    /// The error a failed slice surfaces with (timeout vs unreachable).
    func failureError(forTable table: String) -> URLError {
        lock.lock()
        defer { lock.unlock() }
        return timingOutTables.contains(table)
            ? URLError(.timedOut)
            : URLError(.notConnectedToInternet)
    }

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

    /// Holds the next request for one table so a caller can observe an
    /// in-flight pass.
    func holdNextRequest(table: String) {
        condition.lock()
        holdTable = table
        condition.unlock()
    }

    func releaseHeldRequest() {
        condition.lock()
        holding = false
        holdTable = nil
        releaseGeneration += 1
        condition.broadcast()
        condition.unlock()
    }

    var isHoldingRequest: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holding
    }

    /// Requests served for one table, by method (`GET` by default). Only
    /// requests the stub actually answered are counted.
    func count(of table: String, method: String = "GET") -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.table == table && $0.method == method }.count
    }

    func queries(for table: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.table == table }.map(\.query)
    }

    /// One line per served request (`table METHOD ?query`), for diagnosing a
    /// slice that failed unexpectedly.
    func dumpRequests() -> String {
        lock.lock()
        defer { lock.unlock() }
        return requests
            .map { "\($0.table)#\($0.method)?\($0.query)" }
            .joined(separator: " || ")
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncSurfacesProtocol.self]
        SyncSurfacesProtocol.server = self
        return URLSession(configuration: configuration)
    }

    /// The health row the server currently holds, read back by date.
    func readiness(of date: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return tables["health_metrics"]?
            .first { ($0["date"] as? String) == date }?["readiness"] as? Int
    }

    /// Nil means "fail at the transport layer" (offline, or a failing slice).
    func reply(for request: URLRequest, body: Data?) -> Reply? {
        let table = Self.tableKey(request.url?.path ?? "")
        let query = request.url?.query ?? ""
        let method = request.httpMethod ?? "GET"
        lock.lock()
        let reachable = online
            && !failingTables.contains(table)
            && !timingOutTables.contains(table)
        let rejection = rejectionStatus[table]
        if reachable {
            requests.append((table, query, method))
        }
        let rows = tables[table] ?? []
        lock.unlock()
        guard reachable else { return nil }
        if let rejection {
            let body = Self.json([[
                "message": "JWT expired",
                "code": "PGRST301",
                "details": NSNull(),
                "hint": NSNull(),
            ]])
            return Reply(status: rejection, body: body)
        }
        waitIfHolding(table)

        if table == "sync_purge_generations" {
            return Reply(status: 200, body: Self.json([["generation": 1]]))
        }
        switch method {
        case "GET":
            return Reply(status: 200, body: Self.json(Self.deltaRows(rows, query: query)))
        case "POST":
            var row = Self.object(from: body) ?? [:]
            row["id"] = row["id"] ?? UUID().uuidString.lowercased()
            row["deleted_at"] = NSNull()
            row["updated_at"] = Self.timestamp()
            lock.lock()
            tables[table, default: []].append(row)
            lock.unlock()
            return Reply(status: 201, body: Self.json([row]))
        case "PATCH":
            return Reply(status: 200, body: Self.json(rows))
        default:
            return Reply(status: 200, body: Self.json(rows))
        }
    }

    private func waitIfHolding(_ table: String) {
        condition.lock()
        guard holdTable == table else {
            condition.unlock()
            return
        }
        holdTable = nil
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

    /// The last path component is the table the stub keys on.
    static func tableKey(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    /// Serves a delta request the way PostgREST does: rows strictly after the
    /// requested cursor, ascending by (updated_at, tie-break). The production
    /// delta reader fails closed (`outOfOrderPage` / `cursorDidNotAdvance`)
    /// when a server returns unordered rows or ignores its cursor, so a stub
    /// that did either would be testing the wrong thing.
    static func deltaRows(_ rows: [[String: Any]], query: String) -> [[String: Any]] {
        let sorted = rows.sorted { lhs, rhs in
            let left = rowDate(lhs)
            let right = rowDate(rhs)
            if left != right { return left < right }
            return tieBreakID(lhs) < tieBreakID(rhs)
        }
        guard let bound = deltaBound(in: query) else { return sorted }
        return sorted.filter { afterCursor($0, bound: bound) }
    }

    /// A parsed `<timestamp>.gt.<stamp>` / `<timestamp>=gte.<stamp>` cursor:
    /// the stamp plus (for the composite form) the tie-break id.
    struct DeltaBound: Equatable {
        let date: Date
        let tieBreak: String?
    }

    static func deltaBound(in query: String) -> DeltaBound? {
        let decoded = query.removingPercentEncoding ?? query
        if let range = decoded.range(of: "updated_at.gt.") {
            let tail = decoded[range.upperBound...]
            guard let stop = tail.firstIndex(of: ",") else { return nil }
            guard let date = parseStamp(String(tail[..<stop])) else { return nil }
            var tieBreak: String?
            if let idRange = decoded.range(of: ".gt.", options: .backwards),
               idRange.lowerBound > range.upperBound {
                let idTail = decoded[idRange.upperBound...]
                let idStop = idTail.firstIndex(of: ")") ?? idTail.endIndex
                tieBreak = String(idTail[..<idStop])
            }
            return DeltaBound(date: date, tieBreak: tieBreak)
        }
        if let range = decoded.range(of: "updated_at=gte.") {
            let tail = decoded[range.upperBound...]
            let stop = tail.firstIndex(of: "&") ?? tail.endIndex
            guard let date = parseStamp(String(tail[..<stop])) else { return nil }
            return DeltaBound(date: date, tieBreak: nil)
        }
        return nil
    }

    /// `(timestamp, tie-break) > (cursor.timestamp, cursor.tie-break)` — the
    /// strict pair comparison the reader's own cursor filter uses. A legacy
    /// cursor carries no tie-break, so a row at exactly its stamp is already
    /// consumed.
    private static func afterCursor(_ row: [String: Any], bound: DeltaBound) -> Bool {
        let date = rowDate(row)
        if date != bound.date { return date > bound.date }
        guard let tieBreak = bound.tieBreak else { return false }
        // UUID text is case-insensitive (the reader's own tie-break closure
        // upper-cases UUIDs while the wire form is lower-case), so comparing
        // the canonical lower-case form is the faithful comparison here.
        return tieBreakID(row).lowercased() > tieBreak.lowercased()
    }

    private static func rowDate(_ row: [String: Any]) -> Date {
        parseStamp((row["updated_at"] as? String) ?? "") ?? .distantPast
    }

    private static func tieBreakID(_ row: [String: Any]) -> String {
        for key in ["id", "name", "date", "user_id"] {
            if let value = row[key] as? String { return value }
        }
        return ""
    }

    private static func parseStamp(_ value: String) -> Date? {
        if let date = LocalDateSupport.iso8601Date(from: value) { return date }
        return nil
    }

    private static func object(from body: Data?) -> [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func json(_ rows: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

final class SyncSurfacesProtocol: URLProtocol {
    nonisolated(unsafe) static var server: SyncSurfacesFakePostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands the body to URLProtocol as a stream, never as
        // `httpBody`; the JSON payload must be drained from the stream here.
        let body = Self.drain(request.httpBodyStream)
        let table = SyncSurfacesFakePostgREST.tableKey(request.url?.path ?? "")
        guard let server = Self.server, let reply = server.reply(for: request, body: body) else {
            let failure = Self.server?.failureError(forTable: table) ?? URLError(.notConnectedToInternet)
            client?.urlProtocol(self, didFailWithError: failure)
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
final class SyncSurfacesInMemoryAuthStorage: AuthLocalStorage {
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
