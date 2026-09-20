import Foundation
import XCTest
@testable import SendmeterCore

/// #934: behavioural coverage of the extracted workspace refresh /
/// reconciliation owner.
///
/// Every test drives `WorkspaceSyncCoordinator` with an INJECTED store seam and
/// injected fetches — no BLE, HealthKit, network or UI service is constructed.
/// Two of them additionally drive the REAL account-scoped cache
/// (`CachedWorkspace` over an in-memory `LocalCacheStore`), because the
/// coordinator's promise is that it reconciles through the app's one existing
/// store rather than a second one of its own.
@MainActor
final class WorkspaceSyncCoordinatorTests: XCTestCase {
    private let account = UUID(uuidString: "0F934000-0000-4000-8000-000000000934")!
    private let otherAccount = UUID(uuidString: "0F934001-0000-4000-8000-000000000935")!
    private let sessionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let secondSessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private enum StubError: Error, Equatable {
        case offline
        case corruptMarker
    }

    private func session(id: UUID, note: String) -> Session {
        Session(
            id: id,
            date: "2026-09-20",
            type: "hangboard",
            typeLabel: "Hangboard",
            durationMinutes: 40,
            rpe: 7,
            note: note,
            phase: .strength,
            accountUserID: account
        )
    }

    private func delta(
        _ values: [Session],
        cursor: String?
    ) -> RemoteEntityDelta<Session> {
        RemoteEntityDelta(
            changes: values.map {
                RemoteEntityChange(entityID: $0.id.uuidString, value: $0, updatedAt: Date())
            },
            activeValues: values,
            cursor: cursor
        )
    }

    private func read(
        cursors: [LocalCacheEntityType: String],
        sessions: [Session] = []
    ) -> LocalCacheSnapshotRead {
        LocalCacheSnapshotRead(
            snapshot: CachedWorkspaceSnapshot(sessions: sessions),
            revision: LocalCacheRevision(liveRowCount: sessions.count, tombstoneCount: 0, digest: "stub"),
            cursors: cursors,
            completedEntityTypes: [],
            purgeGenerations: [:],
            pendingRows: []
        )
    }

    // MARK: - Injected storage double

    /// One recorded cache write, as the coordinator asked for it.
    private enum AppliedKind: Equatable {
        case delta
        case full(purgeGeneration: Int64?)
    }

    private struct Applied: Equatable {
        let entityType: LocalCacheEntityType
        let kind: AppliedKind
        let rowCount: Int
    }

    /// The injected storage seam. Lock-guarded because the coordinator performs
    /// its store work on the storage side, never on the caller's actor.
    private final class FakeStore: WorkspaceSyncStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var _applied: [Applied] = []
        private var _cursorReads: [(UUID, LocalCacheEntityType)] = []
        private var _reports: [String] = []
        private var _readAccountUserID: UUID?
        private var _cursorResult: String?
        private var _cursorError: Error?
        private var _purgeError: Error?
        private var _readError: Error?
        private var _applyError: Error?

        init(
            cursorResult: String? = nil,
            cursorError: Error? = nil,
            purgeError: Error? = nil,
            readError: Error? = nil,
            applyError: Error? = nil
        ) {
            self._cursorResult = cursorResult
            self._cursorError = cursorError
            self._purgeError = purgeError
            self._readError = readError
            self._applyError = applyError
        }

        var applied: [Applied] { lock.lock(); defer { lock.unlock() }; return _applied }
        var cursorReads: [(UUID, LocalCacheEntityType)] {
            lock.lock(); defer { lock.unlock() }; return _cursorReads
        }
        var readAccountUserID: UUID? { lock.lock(); defer { lock.unlock() }; return _readAccountUserID }

        func syncCursor(accountUserID: UUID, entityType: LocalCacheEntityType) throws -> String? {
            lock.lock()
            _cursorReads.append((accountUserID, entityType))
            let error = _cursorError
            let result = _cursorResult
            lock.unlock()
            if let error { throw error }
            return result
        }

        func syncNeedsPurgeReconcile(
            accountUserID: UUID,
            remoteGeneration: Int64?
        ) throws -> Bool {
            lock.lock()
            let error = _purgeError
            lock.unlock()
            if let error { throw error }
            return true
        }

        func applyDeltaReconcile<Value: Encodable & Sendable>(
            _ delta: RemoteEntityDelta<Value>,
            accountUserID: UUID,
            entityType: LocalCacheEntityType
        ) throws {
            lock.lock()
            let error = _applyError
            if error == nil {
                _applied.append(Applied(entityType: entityType, kind: .delta, rowCount: delta.activeValues.count))
            }
            lock.unlock()
            if let error { throw error }
        }

        func applyFullReconcile<Value: Encodable & Sendable>(
            _ delta: RemoteEntityDelta<Value>,
            accountUserID: UUID,
            entityType: LocalCacheEntityType,
            purgeGeneration: Int64?
        ) throws {
            lock.lock()
            let error = _applyError
            if error == nil {
                _applied.append(
                    Applied(
                        entityType: entityType,
                        kind: .full(purgeGeneration: purgeGeneration),
                        rowCount: delta.activeValues.count
                    )
                )
            }
            lock.unlock()
            if let error { throw error }
        }

        func syncCoherentRead(accountUserID: UUID) throws -> LocalCacheSnapshotRead {
            lock.lock()
            _readAccountUserID = accountUserID
            let error = _readError
            lock.unlock()
            if let error { throw error }
            return LocalCacheSnapshotRead(
                snapshot: CachedWorkspaceSnapshot(),
                revision: LocalCacheRevision(liveRowCount: 0, tombstoneCount: 0, digest: "stub"),
                cursors: [:],
                completedEntityTypes: [],
                purgeGenerations: [:],
                pendingRows: []
            )
        }
    }

    private func makeCoordinator() -> WorkspaceSyncCoordinator {
        WorkspaceSyncCoordinator()
    }

    // MARK: - AC3: success

    func testASuccessfulPassPlansTheHydratedCursorsAndReconcilesBoundedDeltas() async {
        let coordinator = makeCoordinator()
        let store = FakeStore(cursorResult: "2026-09-01T00:00:00.000000Z")
        let hydrated = read(
            cursors: [
                .sessions: "2026-09-01T00:00:00.000000Z",
                .recordings: "2026-09-01T00:00:00.000000Z",
            ]
        )

        let plan = coordinator.plan(hydrated: hydrated, forceFullReconcile: false)

        XCTAssertEqual(plan.cursor(for: .sessions), "2026-09-01T00:00:00.000000Z")
        XCTAssertEqual(plan.cursor(for: .recordings), "2026-09-01T00:00:00.000000Z")
        XCTAssertFalse(plan.appliesFullSnapshot(for: .sessions))
        // No persisted cursor for this entity: it is a first-sync full page.
        XCTAssertNil(plan.cursor(for: .healthMetrics))
        XCTAssertTrue(plan.appliesFullSnapshot(for: .healthMetrics))

        let fetched = delta([session(id: sessionID, note: "server")], cursor: "2026-09-02T00:00:00.000000Z")
        await coordinator.reconcileEntity(
            in: store,
            fetched,
            accountUserID: account,
            entityType: .sessions,
            fullSnapshot: nil
        )

        XCTAssertEqual(
            store.applied,
            [Applied(entityType: .sessions, kind: .delta, rowCount: 1)],
            "a persisted cursor reconciles as a bounded delta"
        )

        let collected = coordinator.collectOutcomes(
            [
                (slice: .sessions, error: nil),
                (slice: .recordings, error: nil),
                (slice: .healthMetrics, error: nil),
            ],
            isCancelled: false
        )
        XCTAssertTrue(collected.outcomes.didFullyRefresh)
        XCTAssertTrue(collected.outcomes.didPublishAnyGroup)
        XCTAssertTrue(collected.failures.isEmpty)
    }

    // MARK: - AC3: empty cache

    func testAnEmptyCachePlansAFullFirstSyncForEveryEntityAndRecordsThePurgeGeneration() async {
        let coordinator = makeCoordinator()
        let store = FakeStore()

        let plan = coordinator.plan(hydrated: nil, forceFullReconcile: false)

        for entityType in LocalCacheEntityType.allCases {
            XCTAssertNil(plan.cursor(for: entityType), "\(entityType) has no cursor to fetch with")
            XCTAssertTrue(plan.appliesFullSnapshot(for: entityType))
        }

        let fetched = delta([session(id: sessionID, note: "first sync")], cursor: "2026-09-02T00:00:00.000000Z")
        await coordinator.reconcileEntity(
            in: store,
            fetched,
            accountUserID: account,
            entityType: .sessions,
            fullSnapshot: CachedWorkspaceSnapshot(sessions: fetched.activeValues),
            purgeGeneration: 7
        )

        XCTAssertEqual(
            store.applied,
            [Applied(entityType: .sessions, kind: .full(purgeGeneration: 7), rowCount: 1)],
            "a nil cursor reconciles as a full snapshot, carrying the purge generation"
        )
    }

    // MARK: - AC3: partial failure

    func testAPartialFailurePublishesOnlyGroupsWhoseEverySliceSucceeded() {
        let coordinator = makeCoordinator()

        let collected = coordinator.collectOutcomes(
            [
                (slice: .sessions, error: nil),
                (slice: .recordings, error: StubError.offline),
                (slice: .settings, error: nil),
                (slice: .phasePeriods, error: nil),
                (slice: .healthMetrics, error: nil),
            ],
            isCancelled: false
        )

        XCTAssertFalse(collected.outcomes.publishes(.sessionsAndRecordings))
        XCTAssertTrue(collected.outcomes.publishes(.settingsAndPhase))
        XCTAssertTrue(collected.outcomes.publishes(.healthMetrics))
        XCTAssertEqual(collected.outcomes.failedGroups, [.sessionsAndRecordings])
        XCTAssertEqual(collected.outcomes.failedSlicesInOrder, [.recordings])
        XCTAssertFalse(collected.outcomes.didFullyRefresh)
        XCTAssertTrue(collected.outcomes.didPublishAnyGroup)
        XCTAssertEqual(Array(collected.failures.keys), [.recordings])
    }

    func testAPassWhoseEverySliceFailedPublishesNothingAndIsNotAFullRefresh() {
        let coordinator = makeCoordinator()

        let collected = coordinator.collectOutcomes(
            RefreshSlice.allCases.map { (slice: $0, error: StubError.offline) },
            isCancelled: false
        )

        XCTAssertFalse(collected.outcomes.didPublishAnyGroup)
        XCTAssertFalse(collected.outcomes.didFullyRefresh)
        XCTAssertEqual(collected.outcomes.failedGroups, RefreshConsistencyGroup.allCases)
        XCTAssertEqual(collected.failures.count, RefreshSlice.allCases.count)
    }

    func testOnlyTheGroupsWhoseSlicesWereReportedCanPublish() {
        let coordinator = makeCoordinator()

        // A pass that reported only the sessions/recordings pair: the other
        // groups were not part of this pass, so they are not refused by it.
        let collected = coordinator.collectOutcomes(
            [
                (slice: .sessions, error: StubError.offline),
                (slice: .recordings, error: StubError.offline),
            ],
            isCancelled: false
        )

        XCTAssertTrue(collected.outcomes.didPublishAnyGroup)
        XCTAssertEqual(collected.outcomes.failedGroups, [.sessionsAndRecordings])
        XCTAssertFalse(collected.outcomes.publishes(.sessionsAndRecordings))
        XCTAssertTrue(collected.outcomes.publishes(.settingsAndPhase))
    }

    func testACancelledPassIsNotAVerdict() {
        let coordinator = makeCoordinator()

        let collected = coordinator.collectOutcomes(
            [
                (slice: .sessions, error: CancellationError()),
                (slice: .recordings, error: StubError.offline),
            ],
            isCancelled: true
        )

        XCTAssertTrue(collected.outcomes.wasCancelled)
        XCTAssertTrue(collected.failures.isEmpty, "an interrupted slice is not a reported failure")
        XCTAssertTrue(collected.outcomes.failedGroups.isEmpty, "nothing was refused by a cancelled pass")
        XCTAssertFalse(collected.outcomes.didPublishAnyGroup)
        XCTAssertFalse(collected.outcomes.didFullyRefresh)
    }

    // MARK: - AC3: account switch

    func testAnAccountSwitchBetweenFetchAndReconcileWritesNothing() async throws {
        let coordinator = makeCoordinator()
        let store = FakeStore()
        let scope = LiveScope(current: true)
        let boundary = WorkspaceAccountBoundary(
            fetch: AccountScopedFetch(accountUserID: account, accountEpoch: 3),
            isCurrent: { scope.current }
        )

        let snapshot = try await coordinator.reconcileSlice(
            in: store,
            boundary: boundary,
            entityType: .sessions,
            fetch: { _ in
                // The account switches while the fetch is in flight.
                scope.current = false
                return self.delta([self.session(id: self.sessionID, note: "old account")], cursor: "c1")
            },
            fullSnapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) }
        )

        XCTAssertNil(snapshot)
        XCTAssertTrue(store.applied.isEmpty, "a stale boundary must not write the old account's rows")
        XCTAssertNil(store.readAccountUserID, "and must not publish a snapshot for it")
    }

    func testAReconcileThatLosesItsAccountBeforeThePublicationReadPublishesNothing() async throws {
        let coordinator = makeCoordinator()
        let store = FakeStore(cursorResult: "2026-09-01T00:00:00.000000Z")
        let scope = LiveScope(current: true)
        let boundary = WorkspaceAccountBoundary(
            fetch: AccountScopedFetch(accountUserID: account, accountEpoch: 3),
            isCurrent: { scope.current }
        )

        let snapshot = try await coordinator.reconcileSlice(
            in: store,
            boundary: boundary,
            entityType: .sessions,
            fetch: { _ in
                // The switch lands after the fetch: the delta is reconciled,
                // but nothing may be published for the old account.
                let value = self.delta([self.session(id: self.sessionID, note: "old")], cursor: "c1")
                scope.current = false
                return value
            },
            fullSnapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) },
            onFailure: { _, _ in }
        )

        XCTAssertNil(snapshot)
        XCTAssertNil(store.readAccountUserID)
    }

    // MARK: - The optional purge-generation endpoint

    func testTheOptionalPurgeEndpointReportsFailureAsData() async {
        let coordinator = makeCoordinator()

        let failed = await coordinator.resolvePurgeGeneration { throw StubError.offline }
        XCTAssertNil(failed.generation)
        XCTAssertEqual(failed.endpointFailure as? StubError, .offline)
        XCTAssertFalse(failed.isAvailable)

        let ok = await coordinator.resolvePurgeGeneration { 12 }
        XCTAssertEqual(ok.generation, 12)
        XCTAssertNil(ok.endpointFailure)
        XCTAssertTrue(ok.isAvailable)
    }

    func testAPurgeMismatchForcesOnlyTheTwoHardDeleteBackedEntitiesToFullReconcile() {
        let coordinator = makeCoordinator()
        let hydrated = read(
            cursors: [
                .sessions: "s1",
                .recordings: "r1",
                .healthMetrics: "h1",
                .presets: "p1",
            ]
        )

        let plan = coordinator.plan(hydrated: hydrated, forceFullReconcile: true)

        XCTAssertNil(plan.cursor(for: .sessions))
        XCTAssertNil(plan.cursor(for: .recordings))
        XCTAssertTrue(plan.appliesFullSnapshot(for: .sessions))
        XCTAssertTrue(plan.appliesFullSnapshot(for: .recordings))
        XCTAssertEqual(plan.cursor(for: .healthMetrics), "h1", "an unrelated entity is untouched")
        XCTAssertEqual(plan.cursor(for: .presets), "p1")
    }

    func testAnUnreadablePurgeMarkerFailsClosedAndIsReported() async {
        let coordinator = makeCoordinator()
        let store = FakeStore(purgeError: StubError.corruptMarker)
        var reports: [String] = []

        let needsFull = await coordinator.needsPurgeReconcile(
            in: store,
            accountUserID: account,
            remoteGeneration: 3,
            onFailure: { operation, _ in reports.append(operation) }
        )

        XCTAssertTrue(needsFull, "a corrupt marker is never permission to keep the old cursor")
        XCTAssertEqual(reports, ["cache purge-generation read"])
    }

    func testAnUnreadableCursorDegradesToTheFirstSyncPageAndIsReported() async {
        let coordinator = makeCoordinator()
        let store = FakeStore(cursorError: StubError.offline)
        var reports: [String] = []

        let cursor = await coordinator.cursor(
            in: store,
            accountUserID: account,
            entityType: .sessions,
            onFailure: { operation, _ in reports.append(operation) }
        )

        XCTAssertNil(cursor)
        XCTAssertEqual(reports, ["cache cursor read"])
    }

    // MARK: - Targeted slice reconciliation

    func testASliceWithNoCursorReconcilesAsAFullSnapshotAndPublishesTheRealStoreRead() async throws {
        let coordinator = makeCoordinator()
        let store = FakeStore()

        let snapshot = try await coordinator.reconcileSlice(
            in: store,
            boundary: LiveBoundary(accountUserID: account).boundary(),
            entityType: .sessions,
            fetch: { cursor in
                XCTAssertNil(cursor, "an empty cache has no cursor to fetch with")
                return self.delta([self.session(id: self.sessionID, note: "first")], cursor: "c1")
            },
            fullSnapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) }
        )

        XCTAssertEqual(store.applied, [Applied(entityType: .sessions, kind: .full(purgeGeneration: nil), rowCount: 1)])
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(store.readAccountUserID, account)
    }

    func testASliceWithoutACacheStillPublishesItsFetchedPage() async throws {
        let coordinator = makeCoordinator()
        let missingStore: FakeStore? = nil
        let fetched = delta([session(id: sessionID, note: "network only")], cursor: "c1")

        let snapshot = try await coordinator.reconcileSlice(
            in: missingStore,
            boundary: LiveBoundary(accountUserID: account).boundary(),
            entityType: .sessions,
            fetch: { _ in fetched },
            fullSnapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) }
        )

        XCTAssertEqual(snapshot?.sessions.map(\.id), [sessionID])
    }

    func testAnUnreadableCacheDegradesACursorBoundedSliceToOneFullNetworkPage() async throws {
        let coordinator = makeCoordinator()
        let store = FakeStore(cursorResult: "2026-09-01T00:00:00.000000Z", readError: StubError.offline)
        var fetchedCursors: [String?] = []
        let page = delta([session(id: secondSessionID, note: "full page")], cursor: "2026-09-02T00:00:00.000000Z")
        var reports: [String] = []

        let snapshot = try await coordinator.reconcileSlice(
            in: store,
            boundary: LiveBoundary(accountUserID: account).boundary(),
            entityType: .sessions,
            fetch: { cursor in
                fetchedCursors.append(cursor)
                return page
            },
            fullSnapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) },
            onFailure: { operation, _ in reports.append(operation) }
        )

        XCTAssertEqual(fetchedCursors.count, 2)
        XCTAssertEqual(fetchedCursors.first!, "2026-09-01T00:00:00.000000Z")
        XCTAssertNil(fetchedCursors.last!, "the degraded retry drops the cursor and re-fetches the page")
        XCTAssertEqual(snapshot?.sessions.map(\.id), [secondSessionID])
        XCTAssertEqual(reports, ["cache realtime publish"])
    }

    func testACacheWriteFailureIsReportedAtTheBoundaryAndDoesNotAbortThePass() async {
        let coordinator = makeCoordinator()
        let store = FakeStore(applyError: StubError.offline)
        var reports: [String] = []

        await coordinator.reconcileEntity(
            in: store,
            delta([session(id: sessionID, note: "boom")], cursor: "c1"),
            accountUserID: account,
            entityType: .sessions,
            fullSnapshot: nil,
            onFailure: { operation, _ in reports.append(operation) }
        )

        XCTAssertEqual(reports, ["cache entity reconcile"])
        XCTAssertTrue(store.applied.isEmpty)
    }

    func testAHealthyStoreReportsNoFailure() async {
        let coordinator = makeCoordinator()
        let store = FakeStore()
        var reports: [String] = []

        await coordinator.reconcileEntity(
            in: store,
            delta([session(id: sessionID, note: "fine")], cursor: "c1"),
            accountUserID: account,
            entityType: .sessions,
            fullSnapshot: nil,
            onFailure: { operation, _ in reports.append(operation) }
        )

        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(store.applied.count, 1)
    }

    // MARK: - The same store the app already uses

    func testTheCoordinatorReconcilesThroughTheOneAccountScopedStore() async throws {
        let coordinator = makeCoordinator()
        let workspace = CachedWorkspace(store: try LocalCacheStore())
        let fetched = delta([session(id: sessionID, note: "server row")], cursor: "2026-09-02T00:00:00.000000Z")

        await coordinator.reconcileEntity(
            in: workspace,
            fetched,
            accountUserID: account,
            entityType: .sessions,
            fullSnapshot: nil
        )

        let cachedIDs = try workspace.load(accountUserID: account).sessions.map(\.id)
        let cachedCursor = try workspace.cursor(accountUserID: account, entityType: .sessions)
        let otherAccountSessions = try workspace.load(accountUserID: otherAccount).sessions

        XCTAssertEqual(cachedIDs, [sessionID])
        XCTAssertEqual(cachedCursor, "2026-09-02T00:00:00.000000Z")
        // The write is account-scoped: the other account's cache is untouched.
        XCTAssertTrue(otherAccountSessions.isEmpty)
    }

    func testAFullReconcileKeepsAPendingLocalRowTheServerDidNotCarry() async throws {
        let coordinator = makeCoordinator()
        let workspace = CachedWorkspace(store: try LocalCacheStore())
        let pendingSession = session(id: sessionID, note: "pending local write")
        try workspace.upsertLocal(
            pendingSession,
            accountUserID: account,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )
        let serverSession = session(id: secondSessionID, note: "server row")
        let fetched = delta([serverSession], cursor: "2026-09-02T00:00:00.000000Z")

        await coordinator.reconcileEntity(
            in: workspace,
            fetched,
            accountUserID: account,
            entityType: .sessions,
            fullSnapshot: CachedWorkspaceSnapshot(sessions: [serverSession])
        )

        let cachedIDs = try workspace.load(accountUserID: account).sessions.map(\.id)
        let cachedCursor = try workspace.cursor(accountUserID: account, entityType: .sessions)
        XCTAssertEqual(
            Set(cachedIDs),
            [sessionID, secondSessionID],
            "pending-write precedence stays the store's guard: a full reconcile must not tombstone an unconfirmed local row"
        )
        XCTAssertEqual(cachedCursor, "2026-09-02T00:00:00.000000Z")
    }
}

// MARK: - Doubles

/// A live account identity a test can flip mid-flight.
private final class LiveScope: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: Bool

    init(current: Bool) {
        self._current = current
    }

    var current: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }
}

/// A boundary that stays valid for the whole operation.
@MainActor
private struct LiveBoundary {
    let accountUserID: UUID

    func boundary() -> WorkspaceAccountBoundary {
        WorkspaceAccountBoundary(
            fetch: AccountScopedFetch(accountUserID: accountUserID, accountEpoch: 1),
            isCurrent: { true }
        )
    }
}
