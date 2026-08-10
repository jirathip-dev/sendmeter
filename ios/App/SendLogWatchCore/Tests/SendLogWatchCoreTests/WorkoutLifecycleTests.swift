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

/// #480: proves the five-closure choreography `WorkoutManager.start()` wires
/// to its real `HKWorkoutSession`/`HKLiveWorkoutBuilder` — a `beginCollection`
/// failure must end/discard the pair it JUST started (and detach both
/// delegates first) before rethrowing, never leaving that cleanup for the
/// caller. A spy stands in for the two HealthKit objects; this package's
/// test host cannot construct real ones (no HealthKit entitlement — same
/// reason `WorkoutManagerHRAndPartialFlushTests`, in the separate
/// `SendLogWatchTests` Xcode target, gives for its own HealthKit-shaped
/// seams there). `@MainActor`: `WorkoutSessionActivation.run` is isolated to
/// match its one production caller (`WorkoutManager.start()`, itself
/// `@MainActor` — see the type's doc comment in `WorkoutLifecycle.swift`),
/// so calling it from a test needs the same isolation.
///
/// This proves the ALGORITHM only. `WorkoutSessionActivationWiringTests`
/// (`SendLogWatchTests` — `WorkoutOwnershipTests.swift`) is what pins the
/// production call site actually wires these closures to the real
/// session/builder correctly; neither suite alone would catch a wiring
/// regression the other doesn't also cover (#480 review F2).
@MainActor
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

    // #480 review F3: a "failed activation followed by a retry on a fresh
    // pair succeeds" test used to live here. It could not fail:
    // `WorkoutSessionActivation.run` is a stateless `static func` with no
    // captured mutable state, so a second call on a brand-new `Spy` is
    // mechanically identical to `testSuccessCallsStartAndBeginCollectionOnlyWithNoCleanup`
    // above, whatever the first call did. That statelessness is real and
    // worth having — it's what rules out this function itself wedging a
    // retry — but asserting it added no coverage, and the comment claiming
    // it proved the issue's "failed start then retry succeeds" criterion
    // overclaimed. The parts of that criterion actually reachable off-device
    // are pinned at the `WorkoutManager` level instead: `WorkoutManagerDoubleStartTests
    // .testStartGuardReleasesAfterCompletionForALegitimateRestart` proves the
    // start guard releases after a failed `start()` so a second call is
    // accepted, and `WorkoutManagerOwnershipTests
    // .testStartRecapturesOwnerUserIdForASeparateSubsequentWorkoutUnderADifferentAccount`
    // proves the same for the reset block a retry re-runs (both in
    // `SendLogWatchTests`, injected via `authorizationRequestOverride` since
    // a real failure this far into `start()` can't be driven off-device
    // either). Whether a retry actually succeeds against real HealthKit — a
    // freed one-active-session slot — stays device-only; #504 tracks it.
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
