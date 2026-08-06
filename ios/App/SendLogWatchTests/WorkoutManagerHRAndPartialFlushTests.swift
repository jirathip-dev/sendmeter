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
final class WorkoutManagerPartialFlushOrderingTests: XCTestCase {
    @MainActor
    func testEndAwaitsTheInFlightPartialBeforeReturning() async {
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

        async let summary: WorkoutSummary? = manager.end()
        // Wait until the upload has demonstrably started — this is the
        // point at which unfixed code (no await in end()) would already
        // have raced ahead and returned.
        _ = await order.waitUntilCount(1)
        await gate.release()
        _ = await summary
        await order.append("end-returned")

        let events = await order.snapshot()
        XCTAssertEqual(
            events, ["partial-start", "partial-committed", "end-returned"],
            "end() must not return until the in-flight partial has actually completed"
        )
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
}
