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
/// host (no HealthKit entitlement — `requestAuthorization()` throws before
/// `start()` ever reaches `startFusion()`/HealthKit's delegate, same
/// limitation `WorkoutManagerDoubleStartTests` documents). Both fixes add a
/// small, deliberate seam instead: `performFusionTick(now:)` /
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
        let manager = WorkoutManager()
        manager.reportHRMissingDateIntervalOnce()
        XCTAssertTrue(manager.hrMissingDateIntervalLogged)

        await manager.start() // fails at HK auth in this host, but the reset block runs unconditionally first
        XCTAssertFalse(manager.hrMissingDateIntervalLogged, "a new workout must get its own one-shot report, not inherit the previous workout's")
    }
}

/// Actor-serialized event log for asserting cross-task ordering
/// deterministically (continuation-based — no sleeps, no polling, per this
/// work stream's flake policy).
private actor OrderLog {
    private var events: [String] = []
    private var target: Int?
    private var continuation: CheckedContinuation<[String], Never>?

    func append(_ event: String) {
        events.append(event)
        if let target, events.count >= target {
            continuation?.resume(returning: events)
            continuation = nil
            self.target = nil
        }
    }

    func snapshot() -> [String] { events }

    func waitUntilCount(_ n: Int) async -> [String] {
        if events.count >= n { return events }
        target = n
        return await withCheckedContinuation { continuation = $0 }
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
        let manager = WorkoutManager()
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
        _ = await order.waitUntilCount(1)
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
        let manager = WorkoutManager()
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
        let manager = WorkoutManager()
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

        let events = await order.waitUntilCount(4) // start:1, commit:1, start:<rerun>, commit:<rerun>

        let starts = events.filter { $0.hasPrefix("start:") }
        XCTAssertEqual(starts.count, 2, "3 requests while one is in flight must coalesce into exactly 2 runs, not 3: \(events)")
        XCTAssertEqual(events.first, "start:1")
        XCTAssertEqual(events[1], "commit:1")
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
    /// same file), which is exactly what this test host can drive without a
    /// HealthKit entitlement.
    ///
    /// Reaching the final assertion at all — without the process crashing —
    /// is most of the proof; the assertion itself additionally confirms the
    /// NEW workout's own flushing still works normally afterward, i.e. the
    /// stale handler didn't leave anything wedged.
    @MainActor
    func testStalePartialFlushCompletionAfterANewStartDoesNotCorruptTheNextWorkoutsDrain() async {
        let manager = WorkoutManager()

        // Get workout N running (without HealthKit): start() resets
        // startDate to nil unconditionally before HK setup even attempts,
        // then always fails at requestAuthorization() in this host — set
        // startDate manually afterward to simulate a workout that DID get
        // going at whatever generation start() just stamped.
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
        // tied to.
        await gate.release()
        for _ in 0..<50 { await Task.yield() } // let the completion handler run

        // N+1's OWN flushing must still work normally — proves the stale
        // handler didn't leave partialFlushDrain/partialFlushTask wedged.
        let order = OrderLog()
        manager.partialUploader = { _ in await order.append("n-plus-1-flush-ran") }
        manager.flushPartial()
        let events = await order.waitUntilCount(1)
        XCTAssertEqual(events, ["n-plus-1-flush-ran"])
    }
}
