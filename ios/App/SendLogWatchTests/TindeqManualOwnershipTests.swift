import Foundation
import SendLogWatchCore
import XCTest
@testable import SendLogWatch_Watch_App

/// Issue #529 slice 2 — manual/hands-free Force ownership. `TindeqManager`
/// already stamped `enqueuedUserId` explicitly at the synchronous save
/// boundary for manual paths (unlike ordinary workouts pre-slice-1), but it
/// read `userIdProvider()` live AT THAT SAVE BOUNDARY — i.e. at Stop, not at
/// Start — so a mid-run account switch between Start and Stop still
/// misattributed the rep. The fix mirrors `GuidedForceRunner.ownerUserId`
/// and `WorkoutManager.ownerUserId`: capture the owner once, synchronously,
/// at the first accepted manual `start()`/`armHandsFree()` of a NEW gauge
/// session, and hold it fixed — never re-derive it — for every later rep,
/// disconnect salvage, and the eventual session-completion row, even across
/// a later account transition. Same policy as slice 1: A-owned stays
/// A-owned and is held, never silently rebound to B.
///
/// These exercise the production entry points directly (`start()`,
/// `armHandsFree()`, `stopAndSave`, `handleTransportDisconnect`,
/// `logSessionNow`) against fake queues that capture exactly what was
/// enqueued — the same pattern `GuidedForceRunnerOwnershipTests` and
/// `TindeqHandsFreeIntegrationTests` already use.
@MainActor
final class TindeqManualOwnershipTests: XCTestCase {
    func testManualRepSaveHoldsTheOwnerCapturedAtStartAcrossSignedOutAndB() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start() // captures accountA as this session's owner, before any stop/save
        feed(manager, [(20, 0), (25, 500_000)])

        // A -> signed-out -> B, all before Save now.
        box.current = nil
        box.current = UUID() // account B

        manager.stopAndSave(reason: .userTapped)

        try await waitUntil { await recordings.count() == 1 && !manager.saving }
        let rows = await recordings.snapshot()
        let saved = try XCTUnwrap(rows.first)
        XCTAssertEqual(saved.enqueuedUserId, accountA, "the rep must stay attributed to the account that started it, not whoever is signed in at Stop")
        XCTAssertEqual(saved.row.userId, accountA, "the row-level defense-in-depth stamp must match the queue-level owner")
    }

    /// The named "session completion" acceptance case: the gauge-session row
    /// (`PendingTindeqSession`, the Finish button's payload) must carry the
    /// SAME immutable owner as the reps inside it, not whoever is signed in
    /// when Finish happens to be tapped.
    func testManualSessionCompletionHoldsTheOwnerCapturedAtFirstRepAcrossSignedOutAndB() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start()
        feed(manager, [(20, 0), (25, 500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }

        // The account transition happens AFTER the rep is safely queued but
        // BEFORE Finish is tapped.
        box.current = nil
        box.current = UUID()

        manager.logSessionNow()

        try await waitUntil { await sessions.count() == 1 }
        let sessionRows = await sessions.snapshot()
        let logged = try XCTUnwrap(sessionRows.first)
        XCTAssertEqual(logged.enqueuedUserId, accountA, "the session-completion row must carry the same immutable owner as the reps inside it")
    }

    /// The named "disconnect salvage" acceptance case: an unplanned BLE drop
    /// mid-hold (#151) salvages the in-flight rep AND auto-logs the session
    /// (#280) — both must still carry the run's captured owner, not whoever
    /// is signed in when the drop is handled.
    func testDisconnectSalvageHoldsTheOwnerCapturedAtStartAcrossSignedOutAndB() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Open hand"
        manager.liveSide = "right"

        manager.start()
        feed(manager, [(10, 0), (22, 500_000), (18, 1_000_000)])

        box.current = nil
        box.current = UUID() // account B, active at the moment the drop is handled

        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )

        try await waitUntil { await sessions.count() == 1 }
        let recordingRows = await recordings.snapshot()
        let salvaged = try XCTUnwrap(recordingRows.first)
        XCTAssertEqual(salvaged.row.note, "Recovered after connection loss")
        XCTAssertEqual(salvaged.enqueuedUserId, accountA, "the salvaged rep must stay attributed to the account that started the run, not the account active at drop time")
        XCTAssertEqual(salvaged.row.userId, accountA)

        let sessionRows = await sessions.snapshot()
        let logged = try XCTUnwrap(sessionRows.first)
        XCTAssertEqual(logged.enqueuedUserId, accountA, "the auto-logged session (#280) must also stay attributed to the run's owner")
    }

    /// The other named entry point — "hands-free session start" — captures
    /// the owner at `armHandsFree()`, before any weight sample has even
    /// arrived, and holds it through the auto-detected release/stop.
    func testHandsFreeSessionHoldsTheOwnerCapturedAtArmAcrossSignedOutAndB() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))

        // Account switches WHILE armed — no data has been pulled yet.
        box.current = nil
        box.current = UUID()

        // Now the actual pull happens (two samples >= startStableMs apart,
        // both above startKg, confirm the recording start), then the
        // release grace elapses — same proven deltas as
        // `TindeqHandsFreeIntegrationTests.testHandsFreeRepThenManualRepShareSessionFeedDepletionAndFinishOnce`.
        feed(manager, [(50, 0), (0, 500_000), (2.5, 1_000_000), (2.5, 1_600_000)])
        XCTAssertEqual(manager.status, .measuring, "the pull must have promoted the armed stream to a recording")
        feed(manager, [(30, 3_100_000), (0.5, 3_200_000), (0, 4_699_000)])
        feed(manager, [(0, 4_700_000)])

        try await waitUntil { await recordings.count() == 1 && !manager.saving }
        let rows = await recordings.snapshot()
        let saved = try XCTUnwrap(rows.first)
        XCTAssertEqual(saved.enqueuedUserId, accountA, "a hands-free rep must stay attributed to the account that armed the stream, not whoever is signed in once the pull is detected")
        XCTAssertEqual(saved.row.userId, accountA)
    }

    /// The self-correcting half of the design: holding an owner must not
    /// mean STUCK forever — once Finish closes a session (`clearSession()`),
    /// the NEXT session genuinely starts fresh and binds to whoever is
    /// actually signed in when its first rep begins.
    func testANewSessionAfterFinishCapturesTheNewlyActiveAccount() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start()
        feed(manager, [(20, 0), (25, 500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }
        manager.logSessionNow()
        try await waitUntil { await sessions.count() == 1 }
        XCTAssertNil(manager.sessionId, "Finish must fully close the session")

        // A genuinely new session, under a DIFFERENT account.
        let accountB = UUID()
        box.current = accountB
        manager.start()
        feed(manager, [(18, 0), (24, 500_000)])
        manager.stopAndSave(reason: .userTapped)

        try await waitUntil { await recordings.count() == 2 && !manager.saving }
        let rows = await recordings.snapshot()
        XCTAssertEqual(rows.last?.enqueuedUserId, accountB, "a NEW session started under B must capture B, not stay stuck on the previous session's A")
    }

    // MARK: #529 slice-2 review F5 — clearPersistenceOwner()'s carry-over branch
    //
    // The review named three scenarios: (a) a manual rep continuing a
    // guided run's still-open session while its last save is deferred, (b)
    // the deferred session-completion row itself, (c) either with an
    // already-captured manual owner present. (a) turned out not to be
    // separately reachable: `start()`/`armHandsFree()` both refuse while
    // `saving` is true (`!saving` in their guard), and the guided run's
    // deferred completion keeps `saving` true for exactly as long as
    // `sessionId` stays open on the carry-over path — so no manual rep can
    // ever begin while that window is open. By the time a manual `start()`
    // is accepted again, the deferred completion has already resolved and
    // closed the session (or the test below's block is what's holding it
    // open, which asserts (b) directly). (b) and (c) are the two that are
    // independently reachable, and are what's tested here.

    /// (b) The deferred guided session-completion row itself (built once the
    /// blocked last rep's write finally settles) must carry the bridged
    /// owner even if the active account changed WHILE it was deferred —
    /// this is the exact reproduction from the F1 finding, now fixed.
    func testDeferredGuidedSessionCompletionStampsTheBridgedOwnerAcrossALaterAccountSwitch() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = BlockingManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        let runner = GuidedForceRunner(userIdProvider: { box.current })

        XCTAssertTrue(
            runner.start(protocolValue: shortMovementProtocol, tag: "Half crimp", side: "left", manager: manager)
        )
        let startedAt = try XCTUnwrap(runner.runState?.startedAt)
        feed(manager, [(12, 0), (25, 100_000)])
        runner.advance(to: startedAt.addingTimeInterval(shortMovementProtocol.durationS))
        try await waitUntil { await recordings.count() == 1 && manager.saving }
        XCTAssertEqual(runner.phase, .completed)

        // The account switches WHILE the deferred session finish is still
        // waiting on the blocked write.
        box.current = UUID()

        await recordings.releaseAll()
        try await waitUntil { await sessions.count() == 1 }
        let loggedSessions = await sessions.snapshot()
        let logged = try XCTUnwrap(loggedSessions.first)
        XCTAssertEqual(
            logged.enqueuedUserId, accountA,
            "clearPersistenceOwner()'s carry-over must protect the deferred session-completion row from a later account switch"
        )
    }

    /// (c) The carry-over must never override an owner ALREADY captured for
    /// the CURRENTLY open session — a manual rep that opened it first keeps
    /// governing the session (and its completion row) even after a guided
    /// run continues in the same connect under its own, different owner.
    func testAnAlreadyCapturedManualOwnerIsNotOverriddenByClearPersistenceOwnersCarryOver() async throws {
        let accountX = UUID()
        let accountA = UUID()
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { accountX }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start()
        feed(manager, [(20, 0), (25, 500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }
        XCTAssertNotNil(manager.sessionId, "the session must still be open after one manual rep — Finish was never tapped")

        let runner = GuidedForceRunner(userIdProvider: { accountA })
        XCTAssertTrue(
            runner.start(protocolValue: shortMovementProtocol, tag: "Half crimp", side: "left", manager: manager)
        )
        let startedAt = try XCTUnwrap(runner.runState?.startedAt)
        feed(manager, [(12, 5_000_000), (25, 5_100_000)])
        runner.advance(to: startedAt.addingTimeInterval(shortMovementProtocol.durationS))
        try await waitUntil { await sessions.count() == 1 && !manager.saving }

        let rows = await recordings.snapshot()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.enqueuedUserId, accountA, "the guided run's own rep is still stamped its own explicit owner while active")

        let loggedSessions = await sessions.snapshot()
        let logged = try XCTUnwrap(loggedSessions.first)
        XCTAssertEqual(
            logged.enqueuedUserId, accountX,
            "the session's already-captured manual owner must win — clearPersistenceOwner()'s carry-over only fills in a NIL owner"
        )
    }

    // MARK: #529 slice-2 review round 2 — handleAccountTransition(to:)
    //
    // Round 1 added `handleAccountTransition(to:)` but shipped it with no
    // test of its own; round-2 review (R2-F2) named that gap as exactly why
    // R2-F1 — the deferred transition being dropped on the floor once the
    // straddling rep ended — went unnoticed. These pin the policy directly.

    /// The named acceptance case: a transition arriving mid-rep must defer
    /// (never touch the still-recording rep's owner), then resolve once that
    /// rep actually ends — closing/logging the session under its held owner
    /// — so a SEPARATE, later rep by the new account opens its own fresh
    /// session instead of silently landing in the old one.
    func testAccountTransitionDuringAMeasuringManualRepDefersThenResolvesAtStop() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        let accountB = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start()
        feed(manager, [(20, 0), (25, 500_000)])
        XCTAssertEqual(manager.status, .measuring, "the rep must still be in flight when the transition arrives")

        // The relay that flips `box.current` is the SAME event that reports
        // the transition — mirrors `SendLogWatchApp`'s single `.onChange`.
        box.current = accountB
        manager.handleAccountTransition(to: accountB)
        let sessionsBeforeStop = await sessions.count()
        XCTAssertEqual(sessionsBeforeStop, 0, "a transition mid-rep must defer, not close the session out from under the recording rep")

        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }

        let rows = await recordings.snapshot()
        XCTAssertEqual(rows.first?.enqueuedUserId, accountA, "the straddling rep itself must still be attributed to the account that started it")

        // The deferred transition resolves in the SAME completion that saved
        // the straddling rep — the session must already be closed.
        try await waitUntil { await sessions.count() == 1 }
        let loggedSessions = await sessions.snapshot()
        XCTAssertEqual(loggedSessions.first?.enqueuedUserId, accountA, "the session-completion row must be held under A, the account that opened it")
        XCTAssertNil(manager.sessionId, "the deferred transition must close the session once the straddling rep ends")

        // A genuinely NEW rep, under B (now the live account), must open its
        // OWN session — never inherit A's.
        manager.start()
        feed(manager, [(18, 5_000_000), (22, 5_500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 2 && !manager.saving }
        let allRows = await recordings.snapshot()
        XCTAssertEqual(allRows.last?.enqueuedUserId, accountB, "B's post-transition activity must never inherit A's owner")
    }

    /// The worse-case named in the review: a transition mid-hands-free-pull
    /// must not let the automatic re-arm keep silently accepting B's later
    /// pulls into A's session with no further user action. Resolving the
    /// transition at rep-end must itself cancel hands-free (`logSessionNow()`
    /// → `cancelHandsFree()`), which is what actually breaks the loop.
    func testAccountTransitionDuringAHandsFreePullDefersThenStopsTheAutoRearm() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        let accountB = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        feed(manager, [(50, 0), (0, 500_000), (2.5, 1_000_000), (2.5, 1_600_000)])
        XCTAssertEqual(manager.status, .measuring, "the pull must have promoted the armed stream to a recording")

        box.current = accountB
        manager.handleAccountTransition(to: accountB)
        XCTAssertTrue(manager.handsFreeRequested, "a transition mid-pull must defer — hands-free stays live for the rep already in flight")

        // Release grace elapses — same proven deltas as
        // TindeqHandsFreeIntegrationTests.
        feed(manager, [(30, 3_100_000), (0.5, 3_200_000), (0, 4_699_000)])
        feed(manager, [(0, 4_700_000)])
        try await waitUntil { await recordings.count() == 1 && !manager.saving }

        let rows = await recordings.snapshot()
        XCTAssertEqual(rows.first?.enqueuedUserId, accountA, "the straddling pull must still be attributed to A")

        try await waitUntil { await sessions.count() == 1 }
        XCTAssertFalse(
            manager.handsFreeRequested,
            "resolving the deferred transition must cancel hands-free, or every later pull by whoever's next keeps landing in A's session with no further action"
        )
        XCTAssertNil(manager.sessionId)

        // Confirm the loop is genuinely broken: B has to explicitly re-arm,
        // and that NEW arm captures B, not a resurrected A.
        manager.armHandsFree()
        feed(manager, [(40, 4_800_000), (0, 5_300_000), (3, 5_800_000), (3, 6_400_000)])
        feed(manager, [(20, 6_500_000), (20, 7_900_000), (0.5, 8_000_000), (0, 9_499_000)])
        feed(manager, [(0, 9_500_000)])
        try await waitUntil { await recordings.count() == 2 && !manager.saving }
        let allRows = await recordings.snapshot()
        XCTAssertEqual(allRows.last?.enqueuedUserId, accountB, "B's re-armed pull must never inherit A's owner")
    }

    /// A transition with nothing captured at all (a fresh manager, or one
    /// after Finish/discard) must be a genuine no-op — no session conjured
    /// into existence, no queue call of any kind.
    func testAccountTransitionWithNoOpenSessionIsANoOp() {
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { UUID() }
        )

        manager.handleAccountTransition(to: UUID())

        XCTAssertNil(manager.sessionId)
        XCTAssertEqual(manager.sessionCount, 0)
    }

    /// Same account signing in again (a token refresh, not a real switch)
    /// must not disturb an open session at all.
    func testAccountTransitionToTheSameOwnerIsANoOp() async throws {
        let accountA = UUID()
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { accountA }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"
        manager.start()
        feed(manager, [(20, 0), (25, 500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }
        let sessionIdBefore = manager.sessionId
        XCTAssertNotNil(sessionIdBefore)

        manager.handleAccountTransition(to: accountA)

        XCTAssertEqual(manager.sessionId, sessionIdBefore, "the SAME account relaying again must not close the open session")
        let sessionCountAfter = await sessions.count()
        XCTAssertEqual(sessionCountAfter, 0, "nothing should have been logged")
    }

    /// While a guided run owns the manager (`persistenceOwnerAssigned`),
    /// `handleAccountTransition` must defer entirely to
    /// `GuidedForceRunner`'s own `authStateDidChange` — acting here too
    /// would race two policies over the same state.
    func testAccountTransitionDoesNothingWhileAGuidedRunOwnsTheManager() async throws {
        let accountA = UUID()
        let accountB = UUID()
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { accountA }
        )
        let runner = GuidedForceRunner(userIdProvider: { accountA })
        XCTAssertTrue(
            runner.start(protocolValue: shortMovementProtocol, tag: "Half crimp", side: "left", manager: manager)
        )
        XCTAssertTrue(runner.isActive)

        manager.handleAccountTransition(to: accountB)

        XCTAssertTrue(runner.isActive, "the manual-path transition handler must not touch a manager a guided run owns")
        XCTAssertEqual(manager.status, .measuring)
    }

    /// An armed-but-idle hands-free wait has made no commitment yet (no
    /// claim, no samples) — a transition must close through it immediately,
    /// not defer, and the new account has to re-arm.
    func testAccountTransitionClosesThroughAnArmedButIdleHandsFreeWaitImmediately() {
        let accountA = UUID()
        let accountB = UUID()
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { _ in },
            userIdProvider: { accountA }
        )
        manager.liveTag = "Half crimp"
        manager.armHandsFree()
        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))

        manager.handleAccountTransition(to: accountB)

        XCTAssertFalse(manager.handsFreeRequested, "an armed-but-idle wait must close immediately, not defer — nothing was ever recorded under A")
        XCTAssertNil(manager.sessionId)
    }

    // MARK: #530 — live-mirror beat ownership (round-1 review F2, round-2
    // review R2-F2)
    //
    // `currentForceMirrorOwnerUserId` is a COMPUTED property, deliberately
    // NOT a field pinned once at `connect()` — a BLE connect outlives
    // multiple, differently-owned gauge sessions (Progressor stays connected
    // across Finish/`clearSession()`), so a stamp fixed at connect time could
    // assert an owner a later session doesn't have. It PREFERS
    // `persistenceOwnerUserId`/`manualSessionOwnerUserId`, the SAME two
    // fields `enqueuedUserId` is computed from elsewhere in this file, and
    // FALLS BACK to `forceMirrorConnectOwnerUserId` (round-2 review R2-F2)
    // for a beat that has no session/guided run yet — a nil stamp there was
    // indistinguishable on the wire from a pre-#530 watch, which the phone's
    // legacy branch trusted even for a CURRENT watch. These tests exercise
    // the computed property directly, since its only other observable
    // effect (the stamped WatchConnectivity beat) is unreachable from this
    // unsigned test host (no real WCSession activates). `manager.status =
    // .connected` after `connect()` fakes past the real BLE handshake this
    // host cannot perform — `connect()` itself is safe to call here since
    // its only synchronous side effects are field resets and constructing a
    // `CBCentralManager`, whose async delegate callbacks this test never
    // waits on.

    func testCurrentForceMirrorOwnerIsNilWhenNoConnectHasEverHappened() {
        let manager = TindeqManager(
            recordingQueue: ManualOwnershipRecordingQueue(),
            sessionQueue: ManualOwnershipSessionQueue(),
            commandWriter: { _ in },
            userIdProvider: { UUID() }
        )
        XCTAssertNil(
            manager.currentForceMirrorOwnerUserId,
            "a manager that has never connected has no relayed identity to fall back to either"
        )
    }

    /// The round-2 review R2-F2 fix: before any session/guided run claims
    /// the connect, the mirror must still stamp SOMETHING for a signed-in,
    /// current watch — never silently go unstamped, which the phone cannot
    /// tell apart from a pre-#530 build.
    func testCurrentForceMirrorOwnerFallsBackToTheConnectCapturedIdentityBeforeAnySessionClaimsIt() {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let manager = TindeqManager(
            recordingQueue: ManualOwnershipRecordingQueue(),
            sessionQueue: ManualOwnershipSessionQueue(),
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.connect()
        manager.status = .connected

        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountA,
            "a connected transport with no session yet must fall back to the watch's relayed identity, not go unstamped"
        )
    }

    /// The exact R2-F2 concrete failure: an account switch that lands with
    /// NO session open must update the fallback immediately, so every beat
    /// from that instant forward — not just once a new session's first rep
    /// begins — stamps the NEW account, never the old one and never nothing.
    func testCurrentForceMirrorOwnerFallsBackToTheNewlyRelayedAccountImmediatelyOnATransitionWithNoOpenSession() {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let manager = TindeqManager(
            recordingQueue: ManualOwnershipRecordingQueue(),
            sessionQueue: ManualOwnershipSessionQueue(),
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.connect()
        manager.status = .connected
        XCTAssertEqual(manager.currentForceMirrorOwnerUserId, accountA)

        let accountB = UUID()
        box.current = accountB
        manager.handleAccountTransition(to: accountB)

        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountB,
            "a between-session beat right after an account switch must stamp the NEW account immediately, not stay on the old one or go unstamped"
        )
    }

    func testCurrentForceMirrorOwnerFollowsTheManualSessionOwnerThenFallsBackToTheConnectIdentityOnceTheSessionCloses() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.connect()
        manager.status = .connected
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start()
        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountA,
            "a beat during an open manual session must stamp that session's captured owner"
        )
        feed(manager, [(20, 0), (25, 500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }

        manager.logSessionNow()
        try await waitUntil { await sessions.count() == 1 }
        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountA,
            "once the session is closed, a between-session beat must fall back to the connect-captured identity (still A, no switch happened), not go unstamped"
        )
    }

    /// The exact F2 concrete failure: a second, differently-owned session on
    /// the SAME BLE connect must stamp the SECOND owner, not the first.
    func testCurrentForceMirrorOwnerTracksASecondSessionUnderADifferentAccountOnTheSameConnect() async throws {
        let box = ManualOwnershipAccountBox()
        let accountA = UUID()
        box.current = accountA
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { box.current }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start()
        feed(manager, [(20, 0), (25, 500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }
        manager.logSessionNow()
        try await waitUntil { await sessions.count() == 1 }

        // The Progressor stays connected; a genuinely new session begins
        // under a DIFFERENT account (mirrors production: the watch's own
        // relayed identity changed between the two sessions).
        let accountB = UUID()
        box.current = accountB
        manager.start()

        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountB,
            "a second session on the same connect must stamp its OWN owner, not the first session's — a stale stamp is worse than none"
        )
    }

    /// Mirrors the #529 round-1 F5(c) precedence: while a guided run is
    /// active it wins over an already-open manual session's owner. Once the
    /// guided run hands persistence back (`endRun()` → `clearPersistenceOwner()`,
    /// synchronous, before its own save Task resolves), the carry-over falls
    /// back to X's still-open manual owner rather than reverting early; only
    /// once the whole session actually finishes closing (its deferred
    /// `logSessionAfterPendingSaves()`, after the save resolves) does the
    /// mirror fall all the way back to the connect-captured identity
    /// (round-2 review R2-F2 — still X here, since no account switch
    /// happened). The live mirror stamp must track the SAME three states
    /// `enqueuedUserId` does, never going unstamped for this still-current,
    /// still-signed-in-as-X watch.
    func testCurrentForceMirrorOwnerPrefersTheActiveGuidedRunThenFallsBackToTheManualOwnerThenToTheConnectIdentity() async throws {
        let accountX = UUID()
        let accountA = UUID()
        let recordings = ManualOwnershipRecordingQueue()
        let sessions = ManualOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { accountX }
        )
        manager.connect()
        manager.status = .connected
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.start()
        feed(manager, [(20, 0), (25, 500_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }
        XCTAssertEqual(manager.currentForceMirrorOwnerUserId, accountX)

        let runner = GuidedForceRunner(userIdProvider: { accountA })
        XCTAssertTrue(
            runner.start(protocolValue: shortMovementProtocol, tag: "Half crimp", side: "left", manager: manager)
        )
        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountA,
            "an active guided run must win over the session's already-open manual owner, same as enqueuedUserId"
        )

        let startedAt = try XCTUnwrap(runner.runState?.startedAt)
        feed(manager, [(12, 5_000_000), (25, 5_100_000)])
        runner.advance(to: startedAt.addingTimeInterval(shortMovementProtocol.durationS))

        // `advance()` is fully synchronous through `endRun()`'s
        // `clearPersistenceOwner()` — the guided row's own save Task is
        // still in flight at this point (mirrors `manager.saving == true`
        // in the F5(b)/(c) tests above), so the mirror must already have
        // fallen back to X's still-open manual session, not stay on A and
        // not go nil before the session has actually finished closing.
        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountX,
            "once the guided run hands persistence back, the mirror must revert to the still-open manual session's owner"
        )

        try await waitUntil { await sessions.count() == 1 && !manager.saving }
        XCTAssertEqual(
            manager.currentForceMirrorOwnerUserId, accountX,
            "once the whole session finally closes, a between-session beat must fall back to the connect-captured identity, not go unstamped"
        )
    }

    /// One set, one rep, short enough to complete synchronously via a single
    /// `advance(to:)` call — used by the F5 carry-over tests above, which
    /// only care about reaching `.completed`, not protocol shape.
    private var shortMovementProtocol: WatchForceProtocol {
        WatchForceProtocol(
            id: "carry-over-movement",
            name: "Carry-over movement",
            holdS: 0,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            mode: .reverseAction,
            cadenceOutS: 3,
            cadenceReturnS: 1,
            prepareS: 0
        )
    }

    private func feed(_ manager: TindeqManager, _ samples: [(Float, UInt32)]) {
        var data = Data([0x01, UInt8(samples.count * 8)])
        for (kg, us) in samples {
            withUnsafeBytes(of: kg.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: us.littleEndian) { data.append(contentsOf: $0) }
        }
        manager.handleNotification(data)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("timed out waiting for manager state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A mutable, thread-safe box standing in for "whoever the phone currently
/// says is signed in" — local to this file, same shape as the copies in
/// `WorkoutSavePathResetTests.swift` / `WorkoutManagerHRAndPartialFlushTests.swift`
/// (Swift's top-level `private` is file-scoped).
private final class ManualOwnershipAccountBox: @unchecked Sendable {
    var current: UUID?
}

private actor ManualOwnershipRecordingQueue: TindeqRecordingQueueing {
    private var items: [PendingTindeqRecording] = []

    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome {
        items.append(pending)
        return .queued
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqRecording] { items }
}

private actor ManualOwnershipSessionQueue: TindeqSessionQueueing {
    private var items: [PendingTindeqSession] = []

    func enqueue(_ pending: PendingTindeqSession) async -> QueuePersistOutcome {
        items.append(pending)
        return .queued
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqSession] { items }
}

/// Holds every `enqueue` call open on a continuation until `releaseAll()` —
/// used by the F5 carry-over tests to keep a guided run's last save
/// `saveOperationsInFlight > 0` so its session finish genuinely defers,
/// mirroring `BlockingOwnershipRecordingQueue` in
/// `GuidedForceRunnerOwnershipTests.swift` (Swift's top-level `private` is
/// file-scoped, so this file needs its own copy).
private actor BlockingManualOwnershipRecordingQueue: TindeqRecordingQueueing {
    private var items: [PendingTindeqRecording] = []
    private var waiters: [CheckedContinuation<QueuePersistOutcome, Never>] = []

    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome {
        items.append(pending)
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqRecording] { items }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: .queued) }
    }
}
