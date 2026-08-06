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
