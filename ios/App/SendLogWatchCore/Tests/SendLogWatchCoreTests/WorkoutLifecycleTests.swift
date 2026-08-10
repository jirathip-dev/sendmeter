import Foundation
import XCTest
@testable import SendLogWatchCore

final class WorkoutStartGuardTests: XCTestCase {
    /// Two "taps" racing before the first suspension point: only the first
    /// should get a generation stamp back, exactly like `WorkoutManager
    /// .start()` needs — the second must be told to no-op rather than stand
    /// up a second HealthKit session/timer.
    func testSecondBeginWhileFirstInFlightIsRejected() {
        var g = WorkoutStartGuard()
        let first = g.begin()
        XCTAssertNotNil(first)
        let second = g.begin()
        XCTAssertNil(second, "a start already in flight must reject a concurrent start")
    }

    func testBeginSucceedsAgainAfterFinish() {
        var g = WorkoutStartGuard()
        XCTAssertNotNil(g.begin())
        g.finish()
        XCTAssertNotNil(g.begin(), "finishing the in-flight start must allow a fresh one")
    }

    func testGenerationAdvancesPerAcceptedStart() {
        var g = WorkoutStartGuard()
        let gen1 = g.begin()
        g.finish()
        let gen2 = g.begin()
        XCTAssertNotEqual(gen1, gen2)
    }

    /// The scenario hoisting makes real: workout A's phase-fetch is still in
    /// flight when workout B starts. A's stamp must no longer read as
    /// current once B has begun — a stale write from A must not land on B.
    func testStaleGenerationIsNotCurrentAfterANewStartBegins() {
        var g = WorkoutStartGuard()
        guard let workoutAGeneration = g.begin() else { return XCTFail("expected a generation") }
        g.finish()
        XCTAssertTrue(g.isCurrent(workoutAGeneration))

        guard let workoutBGeneration = g.begin() else { return XCTFail("expected a generation") }
        XCTAssertFalse(g.isCurrent(workoutAGeneration), "workout A's stamp must go stale once B starts")
        XCTAssertTrue(g.isCurrent(workoutBGeneration))
    }
}

final class WidgetCountSyncTests: XCTestCase {
    func testNoPushWhenNeitherStateNorCountChanged() {
        XCTAssertFalse(WidgetCountSync.shouldPush(stateChanged: false, countBefore: 2, countAfter: 2))
    }

    func testPushOnStateChangeAlone() {
        XCTAssertTrue(WidgetCountSync.shouldPush(stateChanged: true, countBefore: 2, countAfter: 2))
    }

    /// The bug this exists to fix: the boulder count can cross
    /// `AttemptDetector`'s post-filter threshold mid-attempt, with the phase
    /// staying `.autoClimbing` throughout (see
    /// `AttemptDetectorTests.testLiveAttemptCountCanChangeWithoutStateTransition`
    /// for the detector-level proof this really happens).
    func testPushOnCountChangeWithNoStateChange() {
        XCTAssertTrue(WidgetCountSync.shouldPush(stateChanged: false, countBefore: 0, countAfter: 1))
    }
}

/// #480: proves the four-step choreography `WorkoutManager.start()` wires to
/// its real `HKWorkoutSession`/`HKLiveWorkoutBuilder` — a `beginCollection`
/// failure must end/discard the pair it JUST started (and detach both
/// delegates first) before rethrowing, never leaving that cleanup for the
/// caller. A spy stands in for the two HealthKit objects; this test host
/// cannot construct real ones (no entitlement, same reason
/// `WorkoutManagerHRAndPartialFlushTests` gives for its own HealthKit-shaped
/// seams).
final class WorkoutSessionActivationTests: XCTestCase {
    private final class Spy {
        var startActivityCalled = false
        var beginCollectionCalled = false
        var delegatesDetached = false
        var sessionEnded = false
        var builderDiscarded = false
        var callOrder: [String] = []
    }

    private enum ActivationFailure: Error {
        case beginCollectionFailed
    }

    private func run(spy: Spy, beginCollectionThrows: Bool) async throws {
        try await WorkoutSessionActivation.run(
            startActivity: {
                spy.startActivityCalled = true
                spy.callOrder.append("startActivity")
            },
            beginCollection: {
                spy.beginCollectionCalled = true
                spy.callOrder.append("beginCollection")
                if beginCollectionThrows { throw ActivationFailure.beginCollectionFailed }
            },
            detachDelegates: {
                spy.delegatesDetached = true
                spy.callOrder.append("detach")
            },
            endSession: {
                spy.sessionEnded = true
                spy.callOrder.append("end")
            },
            discardBuilder: {
                spy.builderDiscarded = true
                spy.callOrder.append("discard")
            }
        )
    }

    func testSuccessCallsStartAndBeginCollectionOnlyWithNoCleanup() async throws {
        let spy = Spy()
        try await run(spy: spy, beginCollectionThrows: false)

        XCTAssertEqual(spy.callOrder, ["startActivity", "beginCollection"])
        XCTAssertFalse(spy.delegatesDetached)
        XCTAssertFalse(spy.sessionEnded, "a successful activation must never end the session it just started")
        XCTAssertFalse(spy.builderDiscarded)
    }

    /// The issue's own defect: `startActivity` makes the session live in
    /// HealthKit immediately, so a `beginCollection` failure must end/discard
    /// the pair it JUST started — the injected session/builder receiving
    /// `end()`/`discardWorkout()` is exactly what frees watchOS's one-active-
    /// session slot for the retry the user is about to make.
    func testBeginCollectionFailureEndsAndDiscardsTheJustStartedPairAndRethrows() async {
        let spy = Spy()
        do {
            try await run(spy: spy, beginCollectionThrows: true)
            XCTFail("expected the beginCollection failure to propagate")
        } catch ActivationFailure.beginCollectionFailed {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(spy.startActivityCalled, "startActivity must still run before the failing beginCollection")
        XCTAssertTrue(spy.sessionEnded, "the injected session must receive end() so watchOS's one-active-session slot is freed")
        XCTAssertTrue(spy.builderDiscarded, "the injected builder must receive discardWorkout()")
        XCTAssertTrue(spy.delegatesDetached, "delegates must be detached, or a callback already in flight can still land on this dead pair")
    }

    /// Detach must run BEFORE end()/discardWorkout() — the whole point is to
    /// stop HealthKit targeting this pair before tearing it down, not after.
    func testCleanupOrderIsDetachThenEndThenDiscard() async {
        let spy = Spy()
        _ = try? await run(spy: spy, beginCollectionThrows: true)

        XCTAssertEqual(
            spy.callOrder, ["startActivity", "beginCollection", "detach", "end", "discard"],
            "cleanup must detach, then end, then discard, in that order"
        )
    }

    /// The issue's other stated acceptance criterion: a failed activation
    /// followed by a retry (a fresh session/builder pair — production never
    /// reuses a discarded one) must succeed cleanly. Nothing here is
    /// stateful across calls, so a second run on a fresh pair must behave
    /// exactly like a first, with none of the first attempt's cleanup calls
    /// leaking onto it.
    func testAFailedActivationFollowedByARetryOnAFreshPairSucceeds() async throws {
        let failedSpy = Spy()
        do {
            try await run(spy: failedSpy, beginCollectionThrows: true)
            XCTFail("expected the first attempt to fail")
        } catch {
            // expected
        }
        XCTAssertTrue(failedSpy.sessionEnded)

        let retrySpy = Spy()
        try await run(spy: retrySpy, beginCollectionThrows: false)

        XCTAssertEqual(
            retrySpy.callOrder, ["startActivity", "beginCollection"],
            "the retry must run cleanly with no leftover state from the failed attempt"
        )
        XCTAssertFalse(retrySpy.sessionEnded, "a successful retry's own session must never be ended")
        XCTAssertFalse(retrySpy.builderDiscarded, "a successful retry's own builder must never be discarded")
    }
}

/// Review finding X1: this used to be proven only by driving the real
/// `WorkoutManager.save()`, which needs live network + disk I/O to reach its
/// success path — two tests that each took ~15.9s and made the whole
/// `SendLogWatchTests` target intermittently fail (~40% of runs measured by
/// the reviewer). The comparison itself is pure; testing it here is
/// microseconds and runs in CI (`package-tests`, unlike `SendLogWatchTests`,
/// which needs a `TEST_HOST` and isn't in `ios-ci.yml` per CLAUDE.md).
final class FailedBundleClearTests: XCTestCase {
    func testClearsWhenTheSavedBundleIsTheOneThatFailed() {
        let id = UUID()
        XCTAssertTrue(FailedBundleClear.shouldClear(failedId: id, savedId: id))
    }

    /// The exact regression R1 fixed: an unrelated earlier failure must
    /// survive a later, different workout's successful save.
    func testDoesNotClearAnUnrelatedFailedBundle() {
        XCTAssertFalse(FailedBundleClear.shouldClear(failedId: UUID(), savedId: UUID()))
    }

    func testNoFailedBundleNeedsNoClearing() {
        XCTAssertFalse(FailedBundleClear.shouldClear(failedId: nil, savedId: UUID()))
    }
}

final class WatchNavigationTests: XCTestCase {
    func testWorkoutTargetIsAlwaysJustWorkout() {
        XCTAssertEqual(WatchNavigation.resolvedPath(for: .workout, workoutRunning: true), [.workout])
        XCTAssertEqual(WatchNavigation.resolvedPath(for: .workout, workoutRunning: false), [.workout])
    }

    func testForceReplacesPathWhenNoWorkoutIsRunning() {
        XCTAssertEqual(WatchNavigation.resolvedPath(for: .force, workoutRunning: false), [.force])
    }

    /// The exact regression this guards: a Force complication deep link must
    /// not pop a running workout off the stack with no way back to End.
    func testForceKeepsWorkoutReachableWhenRunning() {
        XCTAssertEqual(WatchNavigation.resolvedPath(for: .force, workoutRunning: true), [.workout, .force])
    }

    func testStatusAlwaysClearsToTheStackRoot() {
        XCTAssertEqual(WatchNavigation.resolvedPath(for: .status, workoutRunning: true), [])
        XCTAssertEqual(WatchNavigation.resolvedPath(for: .status, workoutRunning: false), [])
    }
}
