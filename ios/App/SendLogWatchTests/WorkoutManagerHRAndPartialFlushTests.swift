import Foundation
import SendLogWatchCore
import XCTest
@testable import SendLogWatch_Watch_App

/// Issue #477. Two defects, proven against `WorkoutManager` itself — not a
/// pure helper beside it — because a pure helper can be correct while the
/// manager still feeds held/unordered HR into the detector, `rawTrace`, and
/// the phone heartbeat (the standing acceptance rule for this fix wave).
///
/// Neither defect is reachable through a real `HKWorkoutSession` in this test
/// host. The start-reset cases inject a deterministic authorization failure
/// through the manager's test seam; the other cases use the manager's own
/// production methods directly. Both fixes add a small, deliberate seam:
/// `performFusionTick(now:)` /
/// `acceptHeartRate(_:)` are the manager's own production methods (the
/// HealthKit delegate calls the latter after extracting a `HeartRateSample`
/// from `HKStatistics`, which cannot be constructed off-device), and
/// `partialUploader` defaults to the real `Repo.flushPartialWorkout` but can
/// be swapped for a deferred fake — `Repo.swift` itself is out of scope for
/// this branch (#475 owns it) and isn't touched.
@MainActor
final class WorkoutManagerHeartRateStalenessTests: XCTestCase {
    private func makeManager(hrStaleAfterS: Double = 5, rawTraceStride: Int = 1) -> WorkoutManager {
        var tunables = Tunables.default
        tunables.hrStaleAfterS = hrStaleAfterS
        tunables.rawTraceStride = rawTraceStride
        let manager = WorkoutManager(tunables: tunables)
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        return manager
    }

    /// The criterion from the issue's own Acceptance section, driven through
    /// production wiring: HR delivery stops mid-trace, and the detector must
    /// see it go ABSENT — not read whatever value happened to arrive last,
    /// forever.
    func testStaleHRReadsAsAbsentOnTheConstructedMotionSample() {
        let manager = makeManager()
        let start = manager.startDate!

        manager.acceptHeartRate(HeartRateSample(value: 150, sampleAt: start))
        manager.performFusionTick(now: start.addingTimeInterval(1))
        XCTAssertEqual(manager.lastMotionSample?.hr, 150, "a fresh reading must reach the detector's MotionSample")

        // No further HR delivery — HealthKit delivery has stopped (bad
        // contact, a sensor gap). Advance well past hrStaleAfterS.
        manager.performFusionTick(now: start.addingTimeInterval(10))
        XCTAssertNil(
            manager.lastMotionSample?.hr,
            "a reading older than hrStaleAfterS must reach the detector as absent, not as a held value"
        )
    }

    /// Same staleness rule, second stated consumer: `rawTrace` must not
    /// persist a stale reading as if it were current (#477 finding 3 — "a
    /// stale value must never be written as if live").
    func testStaleHRIsWrittenAsAbsentInRawTraceRows() {
        let manager = makeManager()
        let start = manager.startDate!

        manager.acceptHeartRate(HeartRateSample(value: 150, sampleAt: start))
        manager.performFusionTick(now: start.addingTimeInterval(1))
        guard let freshRow = manager.rawTrace.last else { return XCTFail("expected a rawTrace row") }
        XCTAssertEqual(freshRow[3], 150)

        manager.performFusionTick(now: start.addingTimeInterval(10))
        guard let staleRow = manager.rawTrace.last else { return XCTFail("expected a second rawTrace row") }
        XCTAssertNil(staleRow[3], "rawTrace must not record a stale HR value as current")
    }

    /// Third stated consumer: the observable `heartRate` property that feeds
    /// `pushBeat()` — both the Supabase live-workout row and the
    /// WatchConnectivity phone mirror read this same property, so proving it
    /// goes nil proves the phone heartbeat does too without needing a real
    /// `WCSession`.
    func testStaleHRMakesTheObservableHeartRatePropertyNilForThePhoneHeartbeat() {
        let manager = makeManager()
        let start = manager.startDate!
        manager.acceptHeartRate(HeartRateSample(value: 150, sampleAt: start))
        manager.performFusionTick(now: start.addingTimeInterval(1))
        XCTAssertEqual(manager.heartRate, 150)

        manager.performFusionTick(now: start.addingTimeInterval(10))
        XCTAssertNil(manager.heartRate, "pushBeat() reads this property directly — stale HR must not reach the phone/Supabase beat")
    }

    /// #477 finding 2: collapsing the per-type `Task { @MainActor }` hop
    /// reduces reordering but does not prove it — a candidate whose OWN
    /// sample interval is older than what's already stored must be rejected
    /// at the point production code accepts it, through the manager's real
    /// entry point (not a parallel Core-only check).
    func testAcceptHeartRateRejectsAnOutOfOrderOlderSample() {
        let manager = makeManager()
        let start = manager.startDate!

        manager.acceptHeartRate(HeartRateSample(value: 160, sampleAt: start))
        // A second, independently-scheduled callback whose OWN sample time
        // is earlier, arriving after the first (the exact reordering the
        // per-type Task hop used to allow).
        manager.acceptHeartRate(HeartRateSample(value: 70, sampleAt: start.addingTimeInterval(-5)))

        manager.performFusionTick(now: start.addingTimeInterval(1))
        XCTAssertEqual(manager.heartRate, 160, "an out-of-order older sample must not move HR backwards")
    }
}

/// #477 review F4: a real HR quantity with no `mostRecentQuantityDateInterval()`
/// used to be silently discarded with no diagnostic at all. The real
/// `HKStatistics`-to-candidate extraction inside the HealthKit delegate is
/// unreachable off-device (no public `HKStatistics` initializer, no
/// entitlement in this host) — `reportHRMissingDateIntervalOnce()` is the
/// manager's own production method the delegate calls on that branch, and
/// `os_log`/`Logger` output isn't independently observable from a unit test,
/// so `hrMissingDateIntervalLogged` (the flag that actually makes "once" real)
/// is what's asserted on here.
@MainActor
final class WorkoutManagerHRMissingDateIntervalTests: XCTestCase {
    func testReportingIsFalseUntilFirstReported() {
        let manager = WorkoutManager()
        XCTAssertFalse(manager.hrMissingDateIntervalLogged)
    }

    func testFirstReportFlipsTheOneShotFlag() {
        let manager = WorkoutManager()
        manager.reportHRMissingDateIntervalOnce()
        XCTAssertTrue(manager.hrMissingDateIntervalLogged)
    }

    /// A missing date interval must not affect HR itself — the direction
    /// stays "absent" (never trusted), same as any other unaccepted sample.
    func testReportingDoesNotAcceptOrAlterTheCurrentHeartRate() {
        var tunables = Tunables.default
        tunables.hrStaleAfterS = 30
        let manager = WorkoutManager(tunables: tunables)
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        manager.acceptHeartRate(HeartRateSample(value: 150, sampleAt: manager.startDate!))
        manager.performFusionTick(now: manager.startDate!.addingTimeInterval(1))
        XCTAssertEqual(manager.heartRate, 150)

        manager.reportHRMissingDateIntervalOnce()

        manager.performFusionTick(now: manager.startDate!.addingTimeInterval(2))
        XCTAssertEqual(manager.heartRate, 150, "reporting a missing-interval reading must not disturb an already-accepted fresh reading")
    }

    /// `start()` must reset the flag, or a real occurrence in workout N
    /// silently suppresses the diagnostic for every later workout too.
    func testStartResetsTheOneShotFlagForANewWorkout() async {
        let manager = makeAuthorizationFailingWorkoutManager()
        manager.reportHRMissingDateIntervalOnce()
        XCTAssertTrue(manager.hrMissingDateIntervalLogged)

        await manager.start() // injected auth fails after the unconditional reset block
        XCTAssertFalse(manager.hrMissingDateIntervalLogged, "a new workout must get its own one-shot report, not inherit the previous workout's")
    }
}

private enum WorkoutManagerAuthorizationFailure: Error {
    case unavailable
}

/// #529 slice-2 review R3: every manager in this file used to default to
/// `{ WatchSessionStore.shared.userId }` — the real, process-wide relayed
/// identity. Since `start()` now captures `ownerUserId` from that provider
/// and `flushPartial()`/its coalesced rerun gate on it, these tests were
/// silently depending on whatever another test in the same process left
/// signed in/out, rather than pinning a value of their own. An explicit
/// signed-out default matches what most of this file actually relies on —
/// several tests here never reach an ACCEPTED `start()` at all (`isRunning`
/// is set by hand), so `ownerUserId` stays nil and this must too, or
/// `flushPartial()`'s ownership guard silently skips every flush; ownership
/// tests below override it with their own mutable box to actually exercise
/// an account transition.
private func makeAuthorizationFailingWorkoutManager(
    userIdProvider: @escaping @Sendable () -> UUID? = { nil }
) -> WorkoutManager {
    let manager = WorkoutManager(userIdProvider: userIdProvider)
    manager.authorizationRequestOverride = {
        throw WorkoutManagerAuthorizationFailure.unavailable
    }
    return manager
}

/// A mutable, thread-safe box standing in for "whoever the phone currently
/// says is signed in" — local to this file since Swift's top-level `private`
/// is file-scoped (`WorkoutSavePathResetTests.swift` has its own copy).
private final class FlushOwnershipAccountBox: @unchecked Sendable {
    var current: UUID?
}

/// Actor-serialized event log for asserting cross-task ordering
/// deterministically (continuation-based — no sleeps, no polling, per this
/// work stream's flake policy).
private actor OrderLog {
    private var events: [String] = []
    private var target: Int?
    private var continuation: CheckedContinuation<[String], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var waitToken = 0

    func append(_ event: String) {
        events.append(event)
        if let target, events.count >= target {
            resumeWait()
        }
    }

    func snapshot() -> [String] { events }

    /// Event-driven — resumes the instant the nth event lands (no
    /// scheduling-turn count anywhere on the success path, so it cannot
    /// lose a race against a lower-QoS producer, the #501 flake) — but
    /// bounded by wall clock: if a REGRESSION means the event never arrives
    /// at all (a wedged drain, #501's subject), it resumes with whatever
    /// has arrived once `timeout` elapses, so the caller fails a clean
    /// assertion instead of hanging the suite — and, since #500, a paid
    /// macOS CI run — to `timeout-minutes` with no test report. There is
    /// deliberately NO unbounded variant to reach for.
    func waitUntilCount(_ n: Int, orTimeout timeout: Duration) async -> [String] {
        precondition(continuation == nil, "OrderLog supports one waiter at a time")
        if events.count >= n { return events }
        target = n
        // The token pins the timer to THIS wait: cancellation alone is not
        // enough, because a cancelled `Task.sleep` returns EARLY, so a
        // just-cancelled timer could still race `expireWait` into a LATER
        // wait on the same log and resume it with a partial list (a new
        // flake, or a false pass on a negative assertion).
        waitToken &+= 1
        let token = waitToken
        return await withCheckedContinuation { c in
            continuation = c
            timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                await self.expireWait(token)
            }
        }
    }

    private func expireWait(_ token: Int) {
        guard token == waitToken else { return } // stale timer from an earlier wait
        resumeWait()
    }

    /// Single resume path for both arms. Cancelling the timer here is
    /// hygiene (release the sleep now, not in 10s); the token above is what
    /// actually makes a stale timer harmless.
    private func resumeWait() {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let c = continuation else { return }
        continuation = nil
        target = nil
        c.resume(returning: events)
    }
}

/// A one-shot gate a fake uploader can block on, released explicitly by the
/// test once it has observed the state it needs — deterministic, no sleeps.
/// Supports multiple concurrent waiters (needed to reproduce the pre-#477
/// shape during verification, where a skipped flush ran as its own
/// concurrent upload instead of coalescing into one rerun).
private actor Gate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let waiters = continuations
        continuations = []
        for c in waiters { c.resume() }
    }
}

/// Issue #477, finding "detached partial upserts can overwrite the final
/// row". "Cancel-or-await" is struck (cancelling a `Task.detached` after its
/// request is on the wire cannot stop the server committing it) — `end()`
/// must AWAIT the in-flight partial. Proven via completion ORDER under a
/// deferred fake uploader, not a generation-counter compare, since the real
/// network isn't testable here.
///
/// Both tests below drive `stopRecordingAndAwaitInFlightPartial()` directly
/// rather than `end()` — `end()` can only reach that call after a guard
/// requiring a real `HKWorkoutSession`/`HKLiveWorkoutBuilder`/`startDate`,
/// and the first two cannot be constructed off-device (no HealthKit
/// entitlement in this test host). `end()`'s own body is a single
/// unconditional delegation to this method (`let endDate = await
/// stopRecordingAndAwaitInFlightPartial()`), so proving the method's
/// property proves `end()`'s by construction — there is no second code path
/// that could apply the ordering differently.
final class WorkoutManagerPartialFlushOrderingTests: XCTestCase {
    @MainActor
    func testStopRecordingAwaitsTheInFlightPartialBeforeReturning() async {
        // #529 slice-2 review R3: `start()` is never called in this test, so
        // `ownerUserId` stays nil — an explicit signed-out provider (rather
        // than the default's ambient `WatchSessionStore.shared.userId`)
        // makes `flushPartial()`'s ownership guard (`nil == nil`) pass for a
        // documented reason instead of by accident of whatever another test
        // in this process left signed in.
        let manager = WorkoutManager(userIdProvider: { nil })
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let order = OrderLog()
        let gate = Gate()

        manager.partialUploader = { _ in
            await order.append("partial-start")
            await gate.wait()
            await order.append("partial-committed")
        }

        manager.flushPartial() // starts the in-flight upload, blocked on the gate

        async let endDate: Date = manager.stopRecordingAndAwaitInFlightPartial()
        // Wait until the upload has demonstrably started — this is the
        // point at which unfixed code (no await before returning) would
        // already have raced ahead and returned.
        _ = await order.waitUntilCount(1, orTimeout: .seconds(10))
        await gate.release()
        _ = await endDate
        await order.append("stopRecording-returned")

        let events = await order.snapshot()
        XCTAssertEqual(
            events, ["partial-start", "partial-committed", "stopRecording-returned"],
            "stopRecordingAndAwaitInFlightPartial() must not return until the in-flight partial has actually completed"
        )
    }

    /// #477 review F2: a `Timer` on the main run loop is not paused by a
    /// suspended MainActor `async` function — so if teardown ran AFTER the
    /// await (the original #477 fix's mistake), `fusionTimer` would still be
    /// live and able to fire for as long as the partial upload takes.
    /// Reproduces exactly the shape the reviewer's probe found
    /// (`rowsBefore=0 rowsAfter=2`): drives a bounded number of scheduling
    /// turns — not wall-clock time — to give the in-flight call every
    /// reasonable chance to reach ITS OWN internal await before checking
    /// whether teardown already ran.
    @MainActor
    func testStopRecordingInvalidatesTheTimerBeforeAwaitingTheInFlightPartial() async {
        // #529 slice-2 review R3: `start()` is never called in this test, so
        // `ownerUserId` stays nil — an explicit signed-out provider (rather
        // than the default's ambient `WatchSessionStore.shared.userId`)
        // makes `flushPartial()`'s ownership guard (`nil == nil`) pass for a
        // documented reason instead of by accident of whatever another test
        // in this process left signed in.
        let manager = WorkoutManager(userIdProvider: { nil })
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        manager.startFusion()
        XCTAssertNotNil(manager.fusionTimer, "startFusion() should have created a live timer")

        let gate = Gate()
        manager.partialUploader = { _ in await gate.wait() }
        manager.flushPartial() // starts the in-flight upload, blocked on the gate

        async let endDate: Date = manager.stopRecordingAndAwaitInFlightPartial()

        // Bounded scheduling-turn loop, not a sleep: on fixed code, teardown
        // is entirely synchronous ahead of the one await in
        // `stopRecordingAndAwaitInFlightPartial()`, so it needs at most a
        // couple of turns once the child task is scheduled at all. On
        // broken code (await-then-teardown), the call is fully parked on
        // `gate.wait()` and never reaches teardown until the gate is
        // released below — `fusionTimer` stays non-nil through every
        // iteration and this loop exhausts without ever seeing it cleared.
        for _ in 0..<50 where manager.fusionTimer != nil {
            await Task.yield()
        }

        XCTAssertNil(
            manager.fusionTimer,
            "fusionTimer must be invalidated BEFORE awaiting the in-flight partial, or the run loop keeps firing it while the upload is stalled"
        )

        await gate.release()
        _ = await endDate
    }

    /// #477 finding 5: a skipped flush (one requested while another is
    /// in-flight) must COALESCE — run once more afterward with the LATEST
    /// snapshot — rather than being dropped (the #470 lost-window failure)
    /// or piling up as one run per request.
    @MainActor
    func testASkippedFlushCoalescesToOneRerunWithTheLatestSnapshot() async {
        // #529 slice-2 review R3: `start()` is never called in this test, so
        // `ownerUserId` stays nil — an explicit signed-out provider (rather
        // than the default's ambient `WatchSessionStore.shared.userId`)
        // makes `flushPartial()`'s ownership guard (`nil == nil`) pass for a
        // documented reason instead of by accident of whatever another test
        // in this process left signed in.
        let manager = WorkoutManager(userIdProvider: { nil })
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let order = OrderLog()
        let gate = Gate()

        manager.partialUploader = { partial in
            await order.append("start:\(partial.attemptsDetected)")
            await gate.wait()
            await order.append("commit:\(partial.attemptsDetected)")
        }

        manager.liveAttempts = 1
        manager.flushPartial() // starts, blocks on the gate

        manager.liveAttempts = 2
        manager.flushPartial() // in-flight already -> queued (must not start a second upload)

        manager.liveAttempts = 3
        manager.flushPartial() // still in-flight -> coalesces with the queued request above, not a third run

        await gate.release() // let the first pass, and the coalesced rerun, run to completion

        let events = await order.waitUntilCount(4, orTimeout: .seconds(10)) // start:1, commit:1, start:<rerun>, commit:<rerun>

        let starts = events.filter { $0.hasPrefix("start:") }
        XCTAssertEqual(starts.count, 2, "3 requests while one is in flight must coalesce into exactly 2 runs, not 3: \(events)")
        XCTAssertEqual(events.first, "start:1")
        // Optional access, not `events[1]`: assertion failures are non-fatal,
        // so on a regression that leaves `events` short a bare subscript
        // traps the whole test process here instead of finishing the run.
        XCTAssertEqual(events.dropFirst().first, "commit:1")
        XCTAssertEqual(
            starts.last, "start:3",
            "the coalesced rerun must snapshot state as of when it actually runs (3), not the moment of an earlier skipped request (2)"
        )
    }

    /// #477 review F3: the flush completion handler used to be unfenced —
    /// if it ran after a NEW `start()` had already installed a fresh
    /// `CoalescingDrain` for the workout that's running now, it would call
    /// `completePass()` on a drain it never `.request()`-ed against, which
    /// hits `CoalescingDrain`'s own `precondition(running, …)` and aborts
    /// the process. `start()` always bumps `startGuard`'s generation and
    /// resets `startDate`/partial-flush bookkeeping regardless of whether
    /// `requestAuthorization()` later succeeds (review finding F7 in this
    /// same file); the injected failure lets this test drive that reset without
    /// HealthKit.
    ///
    /// Reaching the final assertion at all — without the process crashing —
    /// is most of the proof; the assertion itself additionally confirms the
    /// NEW workout's own flushing still works normally afterward, i.e. the
    /// stale handler didn't leave anything wedged.
    @MainActor
    func testStalePartialFlushCompletionAfterANewStartDoesNotCorruptTheNextWorkoutsDrain() async {
        let manager = makeAuthorizationFailingWorkoutManager()

        // Get workout N running without HealthKit: start() resets startDate
        // to nil before authorization, then the injected failure unwinds
        // deterministically. Set startDate manually afterward to simulate a
        // workout that DID get going at whatever generation start() stamped.
        await manager.start()
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let workoutNGeneration = manager.acceptedStartCount

        let gate = Gate()
        manager.partialUploader = { _ in await gate.wait() }
        manager.flushPartial() // captures workoutNGeneration

        // Workout N ends and workout N+1 begins WHILE that flush is still
        // in flight — same reset block (#477) installs a fresh drain/task/
        // suspended state for N+1.
        await manager.start()
        manager.startDate = Date(timeIntervalSince1970: 1_700_001_000)
        XCTAssertEqual(manager.acceptedStartCount, workoutNGeneration + 1, "start() must have bumped the generation")

        // Let workout N's flush finally resolve — its completion handler
        // runs strictly after N+1 has already replaced the drain it was
        // tied to, and bails on the epoch fence WHENEVER it gets scheduled.
        // Nothing here waits for it: a yield-loop cannot advance a
        // `.background` detached chain from the MainActor anyway (the #501
        // flake), and the assertion below holds in both orders — N+1's
        // drain is fresh, so its flush starts regardless.
        await gate.release()

        // N+1's OWN flushing must still work normally — proves the stale
        // handler didn't leave partialFlushDrain/partialFlushTask wedged.
        let order = OrderLog()
        manager.partialUploader = { _ in await order.append("n-plus-1-flush-ran") }
        manager.flushPartial()
        let events = await order.waitUntilCount(1, orTimeout: .seconds(10))
        XCTAssertEqual(events, ["n-plus-1-flush-ran"])
    }

    /// #477 re-review R1: `start()`'s `guard let generation = startGuard.begin()
    /// else { return }` runs BEFORE its `guard !isRunning else { return }` —
    /// `begin()` bumps `startGuard.generation` and only THEN can the call be
    /// rejected for the workout already being live. A start() REJECTED this
    /// way (as opposed to workout N+1 being genuinely ACCEPTED, covered by
    /// `testStalePartialFlushCompletionAfterANewStartDoesNotCorruptTheNextWorkoutsDrain`
    /// above) runs nothing past that guard — `partialFlushDrain` is NOT
    /// replaced — but `startGuard.generation` alone would already disagree
    /// with the flush's stamped generation. Fencing on `startGuard.generation`
    /// (the pre-R1 shape) would make the completion handler bail WITHOUT
    /// calling `completePass()`, wedging the still-live drain `running`
    /// forever: every later `flushPartial()` on the SAME still-running
    /// workout would silently return `.queued` and do nothing — no crash, no
    /// error, just durable flushing quietly dead for the rest of the
    /// workout. `partialFlushEpoch` fixes this by only ever advancing in the
    /// same block that actually replaces the drain.
    ///
    /// No caller reaches this today (`WorkoutLiveView`'s Start button only
    /// renders when not running), so this simulates it directly: `isRunning`
    /// is set true by hand (no HealthKit needed), `start()` is then called
    /// again and must be rejected without disturbing anything, and the
    /// ORIGINAL still-running workout must still be able to flush afterward.
    @MainActor
    func testARejectedStartWithAFlushInFlightDoesNotWedgeDurableFlushingForTheStillRunningWorkout() async {
        let manager = makeAuthorizationFailingWorkoutManager()
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        manager.isRunning = true // workout N is live — no HealthKit needed for this

        let gate = Gate()
        manager.partialUploader = { _ in await gate.wait() }
        manager.flushPartial() // workout N's in-flight durability flush (SL-90)

        // Something calls start() again WHILE that flush is in flight. This
        // MUST be rejected by `guard !isRunning` (not accepted) — the
        // sequential-call case #476A's reviewer anticipated a future caller
        // reaching, distinct from WorkoutManagerDoubleStartTests' CONCURRENT
        // double-tap case.
        await manager.start()
        XCTAssertTrue(manager.isRunning, "a rejected start must not disturb the still-running workout")
        XCTAssertEqual(manager.startDate, Date(timeIntervalSince1970: 1_700_000_000), "a rejected start must not reset the live workout's startDate")

        // Let workout N's original in-flight flush resolve. Deliberately no
        // yield-loop here (the #501 flake): the uploader resumes on a
        // `.background`-priority detached task and its completion handler
        // then needs a MainActor hop — `Task.yield()` from the MainActor
        // neither runs nor priority-boosts either of those, so any
        // yield-counted wait on this chain is a scheduling race the test
        // lost ~half the time even on an idle machine. If the completion
        // handler hasn't run yet when the flush below is requested, the
        // drain answers `.queued` and coalesces it into the rerun — both
        // orders must deliver exactly one "later-flush-ran".
        await gate.release()

        // The load-bearing assertion: workout N (still the SAME, still-live
        // workout — never replaced) must still be able to flush afterward.
        // Bounded `waitUntilCount(_:orTimeout:)` rather than the unbounded
        // wait deliberately: a wedged drain means this event NEVER arrives,
        // and an unbounded continuation wait would hang the test (and any
        // future regression's CI run) forever — the timeout turns that into
        // a clean assertion failure instead, without putting a
        // scheduling-turn count back on the success path.
        let order = OrderLog()
        manager.partialUploader = { _ in await order.append("later-flush-ran") }
        manager.flushPartial()
        let events = await order.waitUntilCount(1, orTimeout: .seconds(10))
        XCTAssertEqual(
            events, ["later-flush-ran"],
            "durable flushing must not be wedged by a start() that was REJECTED (isRunning already true) — only an ACCEPTED start() actually replaces the drain"
        )
    }
}

/// #529 slice-2 review R2: the round-1 fix that closed the mid-workout flush
/// ownership leak (`flushPartial()`'s `guard userIdProvider() == ownerUserId`,
/// and `ClimbWorkoutPartialUpsert.userId`'s row-level stamp) shipped with no
/// dedicated test of its own — only the round-1 review comment described it.
/// These pin both halves directly against production entry points, plus the
/// slice-2 fix that closed the same gap in the coalesced-rerun branch (R1).
final class WorkoutManagerPartialFlushOwnershipTests: XCTestCase {
    @MainActor
    func testFlushPartialSkipsEntirelyOnceTheAccountNoLongerMatchesTheCapturedOwner() async {
        let box = FlushOwnershipAccountBox()
        let ownerA = UUID()
        box.current = ownerA
        let manager = makeAuthorizationFailingWorkoutManager(userIdProvider: { box.current })
        await manager.start()
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(manager.ownerUserId, ownerA)

        var uploadCount = 0
        manager.partialUploader = { _ in uploadCount += 1 }

        // A -> signed-out, then A -> B: neither may let the flush proceed.
        box.current = nil
        manager.flushPartial()
        XCTAssertEqual(uploadCount, 0, "flushPartial() must skip once the run's owner has signed out (#529 F1)")

        box.current = UUID()
        manager.flushPartial()
        XCTAssertEqual(uploadCount, 0, "flushPartial() must skip once a DIFFERENT account is active — never silently rebind to B")
    }

    /// The other half of F1/F6: the row this DOES send when ownership still
    /// matches carries the immutable owner as row-level defense-in-depth,
    /// not whatever `auth.uid()` the request happens to ride under.
    @MainActor
    func testFlushPartialStampsTheCapturedOwnerOnThePartialUpsertRow() async {
        let ownerA = UUID()
        let manager = makeAuthorizationFailingWorkoutManager(userIdProvider: { ownerA })
        await manager.start()
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)

        let order = OrderLog()
        manager.partialUploader = { partial in
            await order.append(partial.userId?.uuidString ?? "nil")
        }
        manager.flushPartial()

        let events = await order.waitUntilCount(1, orTimeout: .seconds(10))
        XCTAssertEqual(
            events, [ownerA.uuidString],
            "the SL-90 partial upsert must carry the run's captured owner as a row-level RLS stamp (#529 F1/F6)"
        )
    }

    /// #529 slice-2 review R1: `flushPartial()`'s own guard only protects the
    /// request that arrives WHILE a flush is already in flight — the account
    /// can just as well change during that in-flight network call itself,
    /// and the coalesced-rerun branch used to call `runPartialFlush()`
    /// directly with no guard of its own. Verifies the fix that closed it.
    @MainActor
    func testCoalescedRerunSkipsWhenTheAccountChangesWhileTheFirstPassIsInFlight() async {
        let box = FlushOwnershipAccountBox()
        let ownerA = UUID()
        box.current = ownerA
        let manager = makeAuthorizationFailingWorkoutManager(userIdProvider: { box.current })
        await manager.start()
        manager.startDate = Date(timeIntervalSince1970: 1_700_000_000)

        let order = OrderLog()
        let gate = Gate()
        manager.partialUploader = { _ in
            await order.append("start")
            await gate.wait()
            await order.append("committed")
        }

        manager.flushPartial() // first pass starts, blocks on the gate
        _ = await order.waitUntilCount(1, orTimeout: .seconds(10))
        manager.flushPartial() // a second request while in flight -> coalesces into a rerun

        // The account changes WHILE the first pass is still parked on the
        // gate — exactly the window `flushPartial()`'s own guard cannot see,
        // since it only checks before a NEW request is dispatched.
        box.current = UUID()
        await gate.release()

        // Give the completion handler every reasonable chance to run (and,
        // on a regression, start the coalesced rerun) before asserting.
        try? await Task.sleep(for: .milliseconds(100))

        let events = await order.snapshot()
        XCTAssertEqual(
            events, ["start", "committed"],
            "a coalesced rerun must not fire once the active account no longer matches the run's captured owner"
        )

        // #529 slice-2 review F3: a skipped rerun must resolve the drain
        // (`CoalescingDrain.running` back to false), not merely decline to
        // fire — otherwise this assertion above would also pass on the
        // wedged, pre-fix code, since a wedged drain never starts a rerun
        // either. Prove the drain is actually usable again: restore the
        // owner and request one more flush; it must actually run.
        box.current = ownerA
        manager.flushPartial()
        let finalEvents = await order.waitUntilCount(4, orTimeout: .seconds(10)) // start, committed, start, committed
        XCTAssertEqual(
            finalEvents, ["start", "committed", "start", "committed"],
            "durable flushing must not be wedged by a coalesced rerun that declined to run — a later flush on the SAME workout must still work"
        )
    }
}
