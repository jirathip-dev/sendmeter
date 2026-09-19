import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #917: a settings/phase change is now a durable account-scoped intent whose
/// replay settles BOTH halves of a training-block transition (the phase periods
/// and the `user_settings` row that has to point at the canonical open period).
/// These tests drive a REAL `AppModel` against a stubbed PostgREST transport and
/// a real on-disk cache + queue, and prove the acceptance criteria at the app
/// boundary:
///
/// * persistence: an offline switch is accepted only because its intent is on
///   disk, and a fresh model over the same files completes it exactly once,
/// * the three termination windows: before the request, between the related
///   transition writes, and after the server applied everything but before the
///   local acknowledgement — none of them may duplicate the phase period or
///   leave `currentPhase`/history mismatched,
/// * revision fencing: an older completion cannot clear or re-publish over a
///   newer local block,
/// * residue: pre-#917 cache-only settings/phase rows get an explicit,
///   provable recovery — or stay visible as unsynced,
/// * account scope: another account cannot execute or absorb the transition.
///
/// Window accounting note: the mid-write and lost-acknowledgement windows are
/// produced by making the SERVER apply the writes while the client's response is
/// lost (the durable state a process kill leaves behind). No SIGKILL is issued
/// in these tests.
final class PhaseTransitionReplayAppTests: XCTestCase {
    /// A fresh account per test: the cache and the pending-write queue are
    /// account-scoped files in the app container, so a shared user id would leak
    /// one test's rows into the next.
    private let userID = UUID()
    private let earlierStart = "2026-01-05"

    private var today: String { LocalDateSupport.string(from: Date()) }

    // MARK: - AC1/AC2: termination BEFORE the request

    @MainActor
    func testOfflinePhaseTransitionIsDurableAndReplaysOnceAfterProcessDeath() async throws {
        let server = FakePhasePostgREST()
        server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(model.settings.currentPhase, .capacity, "fixture: the seeded block is what is open")
        XCTAssertEqual(server.periodCount, 1)

        server.goOffline()
        await model.switchPhase(to: .strength)

        // The optimistic block is published locally, and its durability is the
        // reason it may be: the intent is on disk before this returns.
        XCTAssertEqual(model.settings.currentPhase, .strength, "the optimistic block is published")
        XCTAssertEqual(model.settings.phaseStartDate, today)
        XCTAssertTrue(model.phasePeriods.contains { $0.phase == .strength && $0.endedOn == nil })
        XCTAssertEqual(server.periodCount, 1, "nothing reached the server while offline")
        XCTAssertEqual(server.settings?.phase, .capacity)
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        let queueFile = try Self.queueFileContents()
        XCTAssertTrue(queueFile.contains(userID.uuidString), "the intent is scoped to this account")
        XCTAssertTrue(queueFile.contains("\"strength\""), "the selected block is persisted")
        XCTAssertTrue(queueFile.contains(today), "the intended date is persisted")
        XCTAssertTrue(queueFile.contains(self.earlierStart), "the state the plan was authored against is persisted")

        // Process death: a fresh instance reads the same on-disk state.
        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        XCTAssertEqual(relaunched.settings.currentPhase, .strength, "the pending block is restored from the cache")
        XCTAssertTrue(
            relaunched.phasePeriods.contains { $0.phase == .strength && $0.endedOn == nil },
            "the optimistic period survives the relaunch"
        )
        try await waitForQueueCount(relaunched, expected: 1)

        server.goOnline()
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(server.openPeriods.count, 1, "AC2: one open block after the replay, not two")
        XCTAssertEqual(server.openPeriods.first?.phase, .strength)
        XCTAssertEqual(server.openPeriods.first?.startedOn, today)
        XCTAssertEqual(server.settings?.phase, .strength, "the settings row points at the open block")
        XCTAssertEqual(server.settings?.startDate, today)
        XCTAssertEqual(server.periodCount, 2, "the old block was closed, exactly one new period was created")
        XCTAssertEqual(relaunched.settings.currentPhase, .strength)
        XCTAssertEqual(relaunched.pendingCacheWriteCount, 0, "no cache-only residue is left behind")
    }

    // MARK: - AC2: termination BETWEEN the related transition writes

    /// The transition's mutations run in order (close the old block, create the
    /// new one, point settings at it). Death after the FIRST one leaves the
    /// server half-applied — the replay must complete it, not start a second
    /// transition.
    @MainActor
    func testTerminationBetweenRelatedTransitionWritesDoesNotDuplicateThePeriod() async throws {
        let server = FakePhasePostgREST()
        let oldPeriod = server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // The kill: the first mutation lands, its response (and every later
        // request) never arrives.
        server.killAfterApplyingMutations(1)
        await model.switchPhase(to: .strength)
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        XCTAssertEqual(server.periodCount, 1, "only the close landed before the kill")
        XCTAssertEqual(server.storedPeriod(id: oldPeriod)?.endedOn, today, "the old block is closed on the server")
        XCTAssertEqual(server.openPeriods.count, 0, "and no block is open yet: the transition is half-applied")
        XCTAssertEqual(server.settings?.phase, .capacity, "the settings half has not landed")

        // A fresh model over the same files, then the replay.
        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        server.resume()
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(server.periodCount, 2, "AC2: the replay completes the transition, it does not add a period")
        XCTAssertEqual(server.openPeriods.count, 1, "AC2: exactly one open block")
        XCTAssertEqual(server.openPeriods.first?.phase, .strength)
        XCTAssertEqual(server.openPeriods.first?.startedOn, today)
        XCTAssertEqual(server.settings?.phase, .strength, "currentPhase matches the open period")
        XCTAssertEqual(server.settings?.startDate, today)
        XCTAssertEqual(relaunched.settings.currentPhase, .strength)
        XCTAssertEqual(relaunched.pendingCacheWriteCount, 0)
    }

    /// The same-day switch-back (`delete` the period just created + `reopen` the
    /// previous block) has a mid-write window too. Re-planning from the server's
    /// post-partial state would create a NEW block instead of reopening the old
    /// one — a second period, and a different start date for the same block.
    @MainActor
    func testSameDaySwitchBackReopensThePreviousBlockWithoutASecondPeriod() async throws {
        let server = FakePhasePostgREST()
        server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // First switch: lands cleanly, so the block created today has a server id.
        await model.switchPhase(to: .strength)
        try await waitForQueueCount(model, expected: 0)
        let createdToday = try XCTUnwrap(server.openPeriods.first)
        XCTAssertEqual(createdToday.phase, .strength)

        // Switch back the same day, and die after the delete of today's block.
        server.killAfterApplyingMutations(1)
        await model.switchPhase(to: .capacity)
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)
        XCTAssertNil(server.storedPeriod(id: createdToday.id), "the delete landed before the kill")
        XCTAssertEqual(server.periodCount, 1, "the previous block is still the only server row")

        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        server.resume()
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(
            server.periodCount,
            1,
            "AC2: the same-day switch-back leaves the ONE previous block; the period it created today is gone"
        )
        XCTAssertEqual(server.openPeriods.count, 1, "AC2: exactly one open block")
        XCTAssertEqual(server.openPeriods.first?.phase, .capacity)
        XCTAssertEqual(
            server.openPeriods.first?.startedOn,
            earlierStart,
            "the reopened block keeps its original start date (no one-day sliver)"
        )
        XCTAssertEqual(server.settings?.phase, .capacity)
        XCTAssertEqual(server.settings?.startDate, earlierStart)
        XCTAssertEqual(relaunched.settings.phaseStartDate, earlierStart)
        XCTAssertEqual(relaunched.pendingCacheWriteCount, 0)
    }

    // MARK: - AC2: termination AFTER server success, BEFORE local acknowledgement

    @MainActor
    func testTerminationAfterServerSuccessBeforeLocalAcknowledgementReplaysIdempotently() async throws {
        let server = FakePhasePostgREST()
        server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // Every write lands; the response that would carry the result back is
        // lost, so nothing is acknowledged locally.
        server.dropAcknowledgmentAfterNextWrites()
        await model.switchPhase(to: .strength)
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        XCTAssertEqual(server.periodCount, 2, "the server applied the whole transition")
        XCTAssertEqual(server.openPeriods.count, 1)
        XCTAssertEqual(server.openPeriods.first?.phase, .strength)
        XCTAssertEqual(server.settings?.phase, .strength)
        XCTAssertEqual(
            model.pendingCacheWriteCount,
            3,
            "the transition's three local rows are still unacknowledged"
        )

        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(server.periodCount, 2, "AC3: the replay is idempotent - no second period")
        XCTAssertEqual(server.openPeriods.count, 1)
        XCTAssertEqual(server.openPeriods.first?.phase, .strength)
        XCTAssertEqual(server.settings?.phase, .strength)
        XCTAssertEqual(relaunched.pendingCacheWriteCount, 0)
        XCTAssertEqual(relaunched.settings.currentPhase, .strength)
    }

    /// The other half of the same window: the periods landed, the SETTINGS write
    /// did not. The transition is only complete when the settings row points at
    /// the open block, so the replay has to finish that half too.
    @MainActor
    func testLostSettingsHalfIsCompletedFromTheServerState() async throws {
        let server = FakePhasePostgREST()
        let oldPeriod = server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // The close and the create land; the settings upsert (and everything
        // after it) never arrives.
        server.killAfterApplyingMutations(2)
        await model.switchPhase(to: .strength)
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        XCTAssertEqual(server.periodCount, 2, "the period half landed")
        XCTAssertEqual(server.openPeriods.first?.phase, .strength)
        XCTAssertEqual(server.settings?.phase, .capacity, "the settings half did not")
        XCTAssertEqual(server.storedPeriod(id: oldPeriod)?.endedOn, today)

        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        server.resume()
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(server.periodCount, 2, "no duplicate period for an already-applied create")
        XCTAssertEqual(server.openPeriods.count, 1)
        XCTAssertEqual(server.settings?.phase, .strength, "the completeness step finished the settings half")
        XCTAssertEqual(server.settings?.startDate, today)
        XCTAssertEqual(relaunched.settings.currentPhase, .strength)
        XCTAssertEqual(relaunched.pendingCacheWriteCount, 0)
    }

    // MARK: - AC3: an older completion cannot clear a newer local block

    @MainActor
    func testOlderTransitionCompletionCannotClearANewerLocalBlock() async throws {
        let server = FakePhasePostgREST()
        server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // First switch: its upload is held at its first request, so the newer
        // local change below is definitely written after this request started.
        server.holdNextRequest()
        await model.switchPhase(to: .strength)
        try await waitForHeldRequest(server)

        // Second switch while the first is still in flight: back to the block
        // this account started from (a same-day switch-back). One transition
        // per account, so the newer intent replaces the pending one, and every
        // row it wrote carries a newer revision.
        await model.switchPhase(to: .capacity)
        XCTAssertEqual(model.settings.currentPhase, .capacity, "the newest local block is published")
        XCTAssertEqual(model.settings.phaseStartDate, earlierStart)

        // The second transition's own replay is refused (this server will not
        // reopen a closed block), so the only thing that can change the
        // published block after the first request finishes is the FIRST
        // (older) completion — which still carries the Strength transition.
        server.rejectNextReopen(status: 400, code: "23514")
        server.releaseHeldRequest()
        try await waitForFailureClass(model, expected: .permanent)

        XCTAssertEqual(
            model.settings.currentPhase,
            .capacity,
            "AC3: the older completion must not re-publish its own (older) block"
        )
        XCTAssertEqual(
            model.settings.phaseStartDate,
            earlierStart,
            "AC3: and it must not clear the newer block's start date either"
        )
        XCTAssertEqual(
            model.phasePeriods.first(where: { $0.endedOn == nil })?.phase,
            .capacity,
            "the open local period still carries the newer block"
        )
        XCTAssertGreaterThanOrEqual(
            model.pendingCacheWriteCount,
            1,
            "AC3: the newer local change is still unconfirmed"
        )
        XCTAssertEqual(model.queuedWriteCount, 1, "the newer intent is the one still queued")
        XCTAssertEqual(
            server.settings?.phase,
            .strength,
            "the older request did reach the server; the newer intent has to converge it"
        )

        // Once the server accepts the newer block, its own intent converges the
        // account (authored against the server's rows, since the superseded
        // preview's period id was never minted server-side).
        server.resume()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.openPeriods.count, 1, "exactly one open block server-side")
        XCTAssertEqual(server.openPeriods.first?.phase, .capacity)
        XCTAssertEqual(server.openPeriods.first?.startedOn, earlierStart, "the reopened block keeps its start")
        XCTAssertEqual(server.settings?.phase, .capacity, "currentPhase matches the open period")
        XCTAssertEqual(model.settings.currentPhase, .capacity)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    // MARK: - AC4: pre-#917 cache-only residues

    @MainActor
    func testLegacyPhaseResiduesAreRecoveredOnlyWhenProvable() async throws {
        let server = FakePhasePostgREST()
        // The server's authoritative state: the block the residue belongs to.
        let serverPeriod = server.seedPeriod(phase: .strength, startedOn: today)
        server.seedSettings(phase: .strength, startDate: today)

        // Pre-#917 residue, written straight into the cache with no intent.
        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        let adoptedLocal = PhasePeriod(id: UUID(), phase: .strength, startedOn: today, endedOn: nil)
        try store.upsertLocal(
            adoptedLocal,
            accountUserID: userID,
            entityType: .phasePeriods,
            entityID: adoptedLocal.id.uuidString
        )
        let unresolved = PhasePeriod(id: UUID(), phase: .power, startedOn: today, endedOn: nil)
        try store.upsertLocal(
            unresolved,
            accountUserID: userID,
            entityType: .phasePeriods,
            entityID: unresolved.id.uuidString
        )
        let absentTombstoneID = UUID()
        try store.markDeletedLocal(
            accountUserID: userID,
            entityType: .phasePeriods,
            entityID: absentTombstoneID.uuidString
        )
        try store.markDeletedLocal(
            accountUserID: userID,
            entityType: .phasePeriods,
            entityID: serverPeriod
        )
        try store.upsertLocal(
            UserSettings(currentPhase: .strength, phaseStartDate: today),
            accountUserID: userID,
            entityType: .settings,
            entityID: CacheEntityID.settings
        )

        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(model.pendingCacheWriteCount, 5, "AC4: the residue is visible before the sweep")
        XCTAssertEqual(model.queuedWriteCount, 0, "and none of it has a replay intent")

        await model.drainQueue()

        XCTAssertEqual(
            model.pendingCacheWriteCount,
            2,
            "AC4: the provable residue is resolved; the unprovable rows still count as unsynced"
        )
        XCTAssertEqual(model.queuedWriteCount, 0, "the sweep never invents a transition")
        XCTAssertEqual(server.periodCount, 1, "and never writes to the server")
        let pendingIDs = try store.pendingEntityIDs(
            accountUserID: userID,
            entityType: .phasePeriods,
            includingDeleted: true
        )
        XCTAssertTrue(
            pendingIDs.contains(unresolved.id.uuidString),
            "AC4: a local period the server does not serve is not silently cleared"
        )
        XCTAssertTrue(
            pendingIDs.contains(serverPeriod),
            "AC4: a pending delete the server still has to honour is kept visible"
        )
        XCTAssertFalse(
            pendingIDs.contains(adoptedLocal.id.uuidString),
            "AC4: a live row the server already serves is adopted, not left unreplayable"
        )
        XCTAssertFalse(
            pendingIDs.contains(absentTombstoneID.uuidString),
            "AC4: a delete with nothing left to delete is confirmed"
        )
        XCTAssertEqual(
            try store.pendingEntityIDs(
                accountUserID: userID,
                entityType: .settings,
                includingDeleted: true
            ),
            [],
            "AC4: the settings row the server already serves exactly is confirmed"
        )
        XCTAssertTrue(
            model.phasePeriods.contains { $0.id.uuidString.lowercased() == serverPeriod },
            "the authoritative period is visible after the sweep"
        )
    }

    // MARK: - AC5: permanent rejection, and account scope

    @MainActor
    func testPermanentRejectionPreservesTheTransitionAndItsStatus() async throws {
        let server = FakePhasePostgREST()
        server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // The server refuses THIS payload: a 400 with a constraint code.
        server.rejectNextMutation(status: 400, code: "23514")
        await model.switchPhase(to: .strength)
        await model.drainQueue()
        try await waitForFailureClass(model, expected: .permanent)

        XCTAssertEqual(model.queuedWriteCount, 1, "AC5: the transition is still durable")
        XCTAssertEqual(
            model.queuedWriteDiagnostics.first?.kind,
            "Training block change",
            "the queue describes what is waiting"
        )
        XCTAssertEqual(
            model.queuedWriteDiagnostics.first?.rejectionClass,
            .permanent,
            "AC5: the rejection is reported honestly"
        )
        XCTAssertEqual(server.periodCount, 1, "the rejected write changed nothing on the server")
        XCTAssertEqual(server.settings?.phase, .capacity)
        XCTAssertGreaterThanOrEqual(
            model.pendingCacheWriteCount,
            1,
            "AC5: the local block is preserved, never silently cleared"
        )
        XCTAssertEqual(model.settings.currentPhase, .strength, "and the optimistic block still shows")

        // An explicit retry after the server accepts again drains it.
        server.resume()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)
        XCTAssertEqual(server.openPeriods.count, 1)
        XCTAssertEqual(server.openPeriods.first?.phase, .strength)
        XCTAssertEqual(server.settings?.phase, .strength)
    }

    @MainActor
    func testQueuedPhaseTransitionForOneAccountIsInvisibleToAnother() async throws {
        let server = FakePhasePostgREST()
        server.seedPeriod(phase: .capacity, startedOn: earlierStart)
        server.seedSettings(phase: .capacity, startDate: earlierStart)
        let owner = try await makeSignedInModel(server: server, userID: userID)
        await owner.refreshAll(showSpinner: false)

        server.goOffline()
        await owner.switchPhase(to: .strength)
        try await waitForQueueCount(owner, expected: 1)
        try await waitForRecordedAttempt(owner)

        // A second account in the same process: the cache and the queue are
        // shared on disk, the entries are not.
        let other = try await makeSignedInModel(server: server, userID: UUID())
        server.goOnline()
        await other.retryAllQueuedWrites()

        XCTAssertEqual(other.queuedWriteCount, 0, "another account's queue is empty")
        XCTAssertEqual(other.pendingCacheWriteCount, 0, "and it owns no cache-only rows")
        XCTAssertEqual(server.periodCount, 1, "AC5: it cannot execute the owner's transition")
        XCTAssertEqual(server.settings?.phase, .capacity)

        // The owner's intent is still durable, and replays under its own account.
        await owner.retryAllQueuedWrites()
        try await waitForQueueCount(owner, expected: 0)
        XCTAssertEqual(server.openPeriods.count, 1)
        XCTAssertEqual(server.openPeriods.first?.phase, .strength)
        XCTAssertEqual(server.settings?.phase, .strength)
        XCTAssertEqual(owner.settings.currentPhase, .strength)
    }

    // MARK: - Harness

    /// #970: every wait below is bounded by a WALL-CLOCK deadline, never by a
    /// fixed iteration budget. The old shape (600 × 5 ms ≈ 3 s) expired on a
    /// contended runner while the durable write was legitimately still in
    /// flight: the hosted runs that failed executed this test in 4.370 s inside
    /// a 54.4 s suite, against 1.180 s inside 33.4 s on the passing neighbour.
    /// 60 s is ~14× that worst observed leg; the deadline decides only how long
    /// a wait may take — what is asserted never changes. On expiry the state
    /// actually observed and the elapsed time are reported, so a real
    /// durability/replay regression still fails and stays distinguishable from
    /// slowness.
    private static let waitDeadline: Duration = .seconds(60)

    /// Polls `isSatisfied` until it holds or `timeout` elapses, then fails the
    /// test with the elapsed time and the state `observed`.
    @MainActor
    private func waitUntil(
        _ expectation: String,
        timeout: Duration = PhaseTransitionReplayAppTests.waitDeadline,
        isSatisfied: @MainActor () -> Bool,
        observed: @MainActor () -> String
    ) async throws {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if isSatisfied() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard isSatisfied() else {
            XCTFail(
                "timed out after \(ContinuousClock.now - started) waiting for \(expectation); observed \(observed())"
            )
            return
        }
    }

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        try await waitUntil(
            "the durable queue to reach \(expected) item(s)",
            isSatisfied: { model.queuedWriteCount == expected },
            observed: { Self.durableQueueState(model) }
        )
    }

    @MainActor
    private func waitForRecordedAttempt(_ model: AppModel) async throws {
        try await waitUntil(
            "the queue item to record an upload attempt",
            isSatisfied: { (model.queuedWriteDiagnostics.first?.attempts ?? 0) >= 1 },
            observed: { Self.durableQueueState(model) }
        )
    }

    @MainActor
    private func waitForFailureClass(_ model: AppModel, expected: RejectionClass) async throws {
        try await waitUntil(
            "the queue item to report \(expected)",
            isSatisfied: { model.queuedWriteDiagnostics.first?.rejectionClass == expected },
            observed: { Self.durableQueueState(model) }
        )
    }

    @MainActor
    private func waitForHeldRequest(_ server: FakePhasePostgREST) async throws {
        try await waitUntil(
            "the stubbed server to hold the expected request",
            isSatisfied: { server.isHoldingRequest },
            observed: { server.holdState }
        )
    }

    /// The durable queue as this test can see it: the model's published counts
    /// and per-item diagnostics, plus the queue file a relaunch would read —
    /// together the state that tells a slow/stalled runner apart from a write
    /// that never became durable.
    @MainActor
    private static func durableQueueState(_ model: AppModel) -> String {
        let items = model.queuedWriteDiagnostics
            .map { "\($0.kind) (attempts: \($0.attempts), reject: \(String(describing: $0.rejectionClass)))" }
            .joined(separator: "; ")
        return "queuedWriteCount=\(model.queuedWriteCount), "
            + "pendingCacheWriteCount=\(model.pendingCacheWriteCount), "
            + "account=\(model.currentUserID?.uuidString ?? "none"), "
            + "diagnostics=[\(items)], "
            + "pending-writes.json=\(queueFileState())"
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
        server: FakePhasePostgREST
    ) -> SendmeterRepository {
        let suite = "PhaseTransitionReplayAppTests.repo.\(UUID().uuidString)"
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
        server: FakePhasePostgREST,
        userID: UUID? = nil
    ) async throws -> AppModel {
        let accountID = userID ?? self.userID
        let suite = "PhaseTransitionReplayAppTests.signed-in.\(UUID().uuidString)"
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
        while model.currentUserID == nil, waited < 400 {
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

    private static func queueFileContents() throws -> String {
        let url = supportDirectory().appendingPathComponent("pending-writes.json", isDirectory: false)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The queue file itself — size and last write — for the #970 diagnostics:
    /// it is the state a relaunch would read, and it separates "never persisted"
    /// from "persisted but not published".
    private static func queueFileState() -> String {
        let url = supportDirectory().appendingPathComponent("pending-writes.json", isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "absent"
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let modified = (attributes[.modificationDate] as? Date)
            .map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return "\(size) bytes, modified \(modified)"
    }
}

/// The stubbed backend for `phase_periods` and `user_settings`: server-minted
/// period ids (exactly like `default gen_random_uuid()`), soft deletes hidden
/// from reads, a per-user settings upsert, an offline mode, and the two
/// termination-window modes — "the write applied but the response was lost"
/// (process death between the related writes) and "the last read never came
/// back" (server success, no local acknowledgement) — plus a request hold.
private final class FakePhasePostgREST: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    struct StoredSettings: Equatable {
        var phase: PhaseID
        var startDate: String
        var updatedAt: String
    }

    struct StoredPeriod: Equatable {
        var id: String
        var phase: PhaseID
        var startedOn: String
        var endedOn: String?
        var deletedAt: String?
        var updatedAt: String

        var json: [String: Any] {
            [
                "id": id,
                "phase": phase.rawValue,
                "started_on": startedOn,
                "ended_on": endedOn ?? NSNull(),
                "deleted_at": deletedAt ?? NSNull(),
                "updated_at": updatedAt,
                "created_at": updatedAt,
            ]
        }
    }

    private let lock = NSLock()
    private let condition = NSCondition()
    private var periods: [StoredPeriod] = []
    private var settingsRow: StoredSettings?
    private var online = true
    private var failing = false
    private var remainingMutationsBeforeFailure = 0
    private var dropAcknowledgmentAfterMutation = false
    private var readArmedForDrop = false
    private var rejectNextMutation: (status: Int, code: String)?
    private var rejectNextReopen: (status: Int, code: String)?
    private var pendingHolds = 0
    private var holding = false
    private var releaseGeneration = 0

    // MARK: Control

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

    /// The kill: the next `count` mutations land, then this request's response
    /// (and every later one) never arrives.
    func killAfterApplyingMutations(_ count: Int) {
        lock.lock()
        remainingMutationsBeforeFailure = count
        lock.unlock()
    }

    /// Every write lands; the read that would carry the result back is lost.
    func dropAcknowledgmentAfterNextWrites() {
        lock.lock()
        dropAcknowledgmentAfterMutation = true
        lock.unlock()
    }

    func rejectNextMutation(status: Int, code: String) {
        lock.lock()
        rejectNextMutation = (status, code)
        lock.unlock()
    }

    /// Refuses the next request that would REOPEN a period (a PATCH clearing
    /// `ended_on`), leaving closes/creates/deletes/settings alone.
    func rejectNextReopen(status: Int, code: String) {
        lock.lock()
        rejectNextReopen = (status, code)
        lock.unlock()
    }

    /// Back to a healthy server (and out of any kill/ack-loss mode).
    func resume() {
        lock.lock()
        online = true
        failing = false
        remainingMutationsBeforeFailure = 0
        dropAcknowledgmentAfterMutation = false
        readArmedForDrop = false
        rejectNextMutation = nil
        rejectNextReopen = nil
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

    /// #970 diagnostic: what the hold control was doing when a wait for
    /// `isHoldingRequest` expired.
    var holdState: String {
        condition.lock()
        defer { condition.unlock() }
        return "holding=\(holding) pendingHolds=\(pendingHolds) releaseGeneration=\(releaseGeneration)"
    }

    // MARK: Seeds / reads

    /// Seeds one row and returns the SERVER's row id (the string form the
    /// repository sees).
    @discardableResult
    func seedPeriod(phase: PhaseID, startedOn: String, endedOn: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        periods.append(
            StoredPeriod(
                id: id,
                phase: phase,
                startedOn: startedOn,
                endedOn: endedOn,
                deletedAt: nil,
                updatedAt: Self.timestamp()
            )
        )
        lock.unlock()
        return id
    }

    func seedSettings(phase: PhaseID, startDate: String) {
        lock.lock()
        settingsRow = StoredSettings(
            phase: phase,
            startDate: startDate,
            updatedAt: Self.timestamp()
        )
        lock.unlock()
    }

    var periodCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return periods.filter { $0.deletedAt == nil }.count
    }

    func storedPeriod(id: String) -> StoredPeriod? {
        lock.lock()
        defer { lock.unlock() }
        return periods.first {
            $0.id == id.lowercased() && $0.deletedAt == nil
        }
    }

    var activePeriods: [StoredPeriod] {
        lock.lock()
        defer { lock.unlock() }
        return periods.filter { $0.deletedAt == nil }
    }

    var openPeriods: [StoredPeriod] {
        lock.lock()
        defer { lock.unlock() }
        return periods.filter { $0.deletedAt == nil && $0.endedOn == nil }
    }

    var settings: StoredSettings? {
        lock.lock()
        defer { lock.unlock() }
        return settingsRow
    }

    // MARK: Transport

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakePhaseProtocol.self]
        FakePhaseProtocol.server = self
        return URLSession(configuration: configuration)
    }

    func reply(for request: URLRequest, body: Data?) -> Reply? {
        waitIfHolding()
        lock.lock()
        defer { lock.unlock() }
        guard online, !failing else { return nil }
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let query = request.url?.query ?? ""

        if path.hasSuffix("/phase_periods") {
            switch method {
            case "GET":
                if readArmedForDrop {
                    readArmedForDrop = false
                    return nil
                }
                return Reply(status: 200, body: Self.json(activePeriodsLocked.map(\.json)))
            case "POST":
                return mutateLocked {
                    let payload = Self.object(from: body) ?? [:]
                    periods.append(
                        StoredPeriod(
                            id: UUID().uuidString.lowercased(),
                            phase: PhaseID(rawValue: payload["phase"] as? String ?? "")
                                ?? .capacity,
                            startedOn: payload["started_on"] as? String ?? "1970-01-01",
                            endedOn: nil,
                            deletedAt: nil,
                            updatedAt: Self.timestamp()
                        )
                    )
                }
            case "PATCH":
                let payload = Self.object(from: body) ?? [:]
                if let value = payload["ended_on"],
                   value is NSNull,
                   let rejection = rejectNextReopen {
                    rejectNextReopen = nil
                    return Reply(
                        status: rejection.status,
                        body: Self.errorBody(code: rejection.code)
                    )
                }
                return mutateLocked {
                    guard let id = Self.equalityID(from: query),
                          let index = periods.firstIndex(where: { $0.id == id }) else { return }
                    for (key, value) in payload {
                        switch key {
                        case "phase":
                            periods[index].phase = PhaseID(rawValue: value as? String ?? "")
                                ?? periods[index].phase
                        case "started_on": periods[index].startedOn = value as? String ?? periods[index].startedOn
                        case "ended_on":
                            periods[index].endedOn = value is NSNull ? nil : value as? String
                        case "deleted_at":
                            periods[index].deletedAt = value is NSNull ? nil : value as? String
                        default: break
                        }
                    }
                    periods[index].updatedAt = Self.timestamp()
                }
            default:
                return Reply(status: 405, body: Data("[]".utf8))
            }
        }
        if path.hasSuffix("/user_settings") {
            switch method {
            case "GET":
                // `reply` already holds `lock`: read the stored row directly,
                // never through the locking `settings` accessor (NSLock is not
                // recursive, so that is a deadlock).
                guard let settingsRow else { return Reply(status: 200, body: Data("[]".utf8)) }
                return Reply(
                    status: 200,
                    body: Self.json([[
                        "user_id": "00000000-0000-0000-0000-000000000000",
                        "current_phase": settingsRow.phase.rawValue,
                        "phase_start_date": settingsRow.startDate,
                        "updated_at": settingsRow.updatedAt,
                    ]])
                )
            case "POST":
                return mutateLocked {
                    let payload = Self.object(from: body) ?? [:]
                    settingsRow = StoredSettings(
                        phase: PhaseID(rawValue: payload["current_phase"] as? String ?? "")
                            ?? .capacity,
                        startDate: payload["phase_start_date"] as? String ?? "1970-01-01",
                        updatedAt: Self.timestamp()
                    )
                }
            default:
                return Reply(status: 405, body: Data("[]".utf8))
            }
        }
        return Reply(status: 200, body: Data("[]".utf8))
    }

    /// Applies one mutating request. `nil` means the response never arrived —
    /// the write itself may still have landed, which is exactly what a process
    /// kill between the related writes leaves behind.
    private func mutateLocked(_ work: () -> Void) -> Reply? {
        if let rejection = rejectNextMutation {
            rejectNextMutation = nil
            return Reply(
                status: rejection.status,
                body: Self.errorBody(code: rejection.code)
            )
        }
        work()
        if dropAcknowledgmentAfterMutation {
            dropAcknowledgmentAfterMutation = false
            readArmedForDrop = true
        }
        if remainingMutationsBeforeFailure > 0 {
            remainingMutationsBeforeFailure -= 1
            if remainingMutationsBeforeFailure == 0 {
                failing = true
                return nil
            }
        }
        return Reply(status: 201, body: Data("[]".utf8))
    }

    private var activePeriodsLocked: [StoredPeriod] {
        periods.filter { $0.deletedAt == nil }
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

    private static func errorBody(code: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "message": "check violation",
            "details": NSNull(),
            "hint": NSNull(),
        ])) ?? Data("{}".utf8)
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

private final class FakePhaseProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakePhasePostgREST?

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
