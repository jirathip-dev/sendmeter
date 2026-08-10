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

        // A -> signed-out -> B, all before Stop & Save.
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
        feed(manager, [(30, 1_700_000), (0.5, 1_800_000), (0, 3_299_000)])
        feed(manager, [(0, 3_300_000)])

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
