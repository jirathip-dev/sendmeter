import Foundation
import SendLogWatchCore
import XCTest
@testable import SendLogWatch_Watch_App

/// Issue #476, Part A: `WorkoutManager` used to be `@State` inside
/// `WorkoutLiveView`, a `navigationDestination` — it died whenever that view
/// was popped (a Force/status complication deep link) or the whole
/// `NavigationStack` was swapped out from under it (a `signedOut` auth relay
/// mid-workout). The fix is structural: neither view may own its own
/// `WorkoutManager` any more — both must read the single App-scoped instance
/// via `@Environment`.
///
/// A `WorkoutManager` owned by `@State` gets recreated with a fresh
/// `workoutId = UUID()` and `startDate = nil` every time its owning view is;
/// reading it from the environment instead is exactly what makes "the same
/// workout ID and start date survive [navigation]" true — there is only ever
/// one instance, so there is nothing to lose. These Mirror-based checks prove
/// the ownership model directly rather than trying to drive a real
/// `HKWorkoutSession` through a simulator's NavigationStack from a unit test,
/// which this test host cannot do — see HANDOFF.md's manual/device matrix for
/// the parts of this fix that stay simulator/device-only.
@MainActor
final class WorkoutOwnershipTests: XCTestCase {
    /// Fails to compile on the pre-#476 code: `_workout` was `State<WorkoutManager>`
    /// there (a private `@State private var workout = WorkoutManager()`), and
    /// `WorkoutLiveView()`'s synthesized init took no path through the environment
    /// at all — this test exists specifically to catch that shape coming back.
    func testWorkoutLiveViewReadsWorkoutManagerFromEnvironmentNotState() throws {
        let view = WorkoutLiveView()
        let mirror = Mirror(reflecting: view)
        guard let child = mirror.children.first(where: { $0.label == "_workout" }) else {
            return XCTFail("expected WorkoutLiveView to declare a `workout` property")
        }
        let typeName = String(describing: type(of: child.value))
        XCTAssertTrue(
            typeName.hasPrefix("Environment<"),
            "WorkoutLiveView.workout must be @Environment-sourced (found \(typeName)) — " +
            "an @State-owned WorkoutManager is recreated every time this view is pushed, " +
            "losing the running workout and its in-flight save (issue #476)"
        )
    }

    /// `RootView.body` switches on `auth.state`: a `signedOut` relay mid-workout
    /// swaps the entire `NavigationStack` (and anything pushed on it, including
    /// a live WorkoutLiveView) for `WaitingForPhoneView`. Hoisting fixes this
    /// specifically because the manager lives ABOVE that switch, in
    /// SendLogWatchApp — but only if RootView doesn't shadow it with a
    /// view-local copy of its own.
    func testRootViewReadsWorkoutManagerFromEnvironmentNotState() throws {
        let view = RootView()
        let mirror = Mirror(reflecting: view)
        guard let child = mirror.children.first(where: { $0.label == "_workout" }) else {
            return XCTFail("expected RootView to declare a `workout` property")
        }
        let typeName = String(describing: type(of: child.value))
        XCTAssertTrue(
            typeName.hasPrefix("Environment<"),
            "RootView.workout must be @Environment-sourced (found \(typeName)) — a view-local " +
            "copy here would be destroyed by the exact signedOut NavigationStack swap this guards against"
        )
    }

    /// Re-review finding R3a: `WorkoutScreenSelection.screen(isRunning:justSaved:)`
    /// structurally can't take `failedBundle` as input (Core, tested in
    /// `WorkoutScreenSelectionTests`). This test pins that same guarantee
    /// through `WorkoutLiveView.screen(for:)` — the exact function `body`
    /// currently switches on, not a parallel copy of the decision — so it
    /// catches a regression in that function itself, or in what `body`
    /// switches on today.
    ///
    /// **What this does NOT catch (final-pass finding X2, verified by
    /// actually doing it):** wrapping `body`'s switch in a brand-new
    /// `if workout.failedBundle != nil { … } else { switch Self.screen(for:
    /// workout) { … } }` — i.e. a regression that bypasses `screen(for:)`
    /// entirely instead of changing what it returns — leaves this test
    /// passing. `screen(for:)` itself would still (correctly) say `.start`;
    /// nothing here reads what `body` actually renders. There is no
    /// ViewInspector or hosting-controller seam in this project to assert on
    /// the rendered `body` directly, so that gap is real and currently open
    /// — see HANDOFF.md.
    func testFailedBundleNeverGatesTheScreen() {
        let manager = WorkoutManager()
        manager.failedBundle = sampleFailedBundle()

        XCTAssertEqual(
            WorkoutLiveView.screen(for: manager), .start,
            "a failed bundle from a previous workout must never block Start"
        )

        manager.isRunning = true
        XCTAssertEqual(
            WorkoutLiveView.screen(for: manager), .live,
            "a running workout must render live even with a failed bundle present"
        )
    }

    private func sampleFailedBundle() -> WorkoutSaveBundle {
        let workoutId = UUID()
        let sessionId = UUID()
        return WorkoutSaveBundle(
            session: SessionInsert(
                id: sessionId, date: "2026-08-06", type: "bouldering", typeLabel: "Bouldering",
                durationMin: 12, rpe: 5.0, note: "", phase: "capacity"
            ),
            workout: ClimbWorkoutInsert(
                id: workoutId, startedAt: Date(), endedAt: Date(),
                elevationGainM: 1, attemptsDetected: 1, attemptsConfirmed: 1,
                rpePredicted: 5, rpeConfirmed: 5, meanEffort: 5, attemptsPer10min: 1,
                sessionId: sessionId
            ),
            attempts: []
        )
    }
}

/// Issue #476: `start()` had no in-flight guard before its first suspension
/// point and only set `isRunning` after the HealthKit `await`s inside it, so
/// two taps on Start both proceeded — the second `startFusion()` call
/// overwrote `fusionTimer` without invalidating the first, orphaning a timer
/// the run loop kept firing. `WorkoutStartGuardTests` (SendLogWatchCore)
/// proves the guard mechanism in isolation; this proves `WorkoutManager.start()`
/// actually wires it in on the production entry point. It doesn't assert on
/// `fusionTimer`/HealthKit directly: the concurrent test gates its injected
/// authorization failure and the restart test throws immediately, so the
/// accepted-start count exercises the guard without depending on host
/// entitlements or an OS authorization prompt.
@MainActor
final class WorkoutManagerDoubleStartTests: XCTestCase {
    func testConcurrentDoubleStartIsAcceptedExactlyOnce() async throws {
        let gate = AuthorizationGate()
        let manager = makeAuthorizationFailingManager(gate: gate)
        async let first: Void = manager.start()

        // Do not rely on async-let scheduling or a timing yield: the first
        // authorization call must be known to be inside its suspension before
        // the second start is invoked.
        await gate.waitUntilEntered()
        await manager.start()
        await gate.release()
        _ = await first

        XCTAssertEqual(
            manager.acceptedStartCount, 1,
            "a concurrent double-tap on Start must pass the start guard exactly once"
        )
    }

    /// A start that fully completes (or fails and unwinds) must release the
    /// guard so a legitimate NEXT start — not a racing double-tap — still works.
    func testStartGuardReleasesAfterCompletionForALegitimateRestart() async throws {
        let manager = makeAuthorizationFailingManager()
        await manager.start()
        await manager.start()
        XCTAssertEqual(manager.acceptedStartCount, 2)
    }

    private func makeAuthorizationFailingManager(gate: AuthorizationGate? = nil) -> WorkoutManager {
        let manager = WorkoutManager()
        if let gate {
            manager.authorizationRequestOverride = {
                await gate.enter()
                await gate.waitUntilReleased()
                throw AuthorizationFailure.unavailable
            }
        } else {
            manager.authorizationRequestOverride = {
                // Immediate deterministic failure; this never touches HealthKit.
                throw AuthorizationFailure.unavailable
            }
        }
        return manager
    }

    private enum AuthorizationFailure: Error {
        case unavailable
    }
}

/// A test-only async barrier for holding the first authorization call exactly
/// across the second `start()` invocation. It has no production counterpart.
private actor AuthorizationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Issue #476: the fusion timer used to be invalidated only in `end()` — any
/// other path to deallocation (skipping an explicit stop) left it registered
/// on the run loop, which retains it and keeps firing into a `[weak self]`
/// that's already nil.
final class WorkoutManagerDeinitTests: XCTestCase {
    @MainActor
    func testFusionTimerIsInvalidatedWhenTheManagerDeinits() {
        var manager: WorkoutManager? = WorkoutManager()
        manager?.startFusion()
        let timer = manager?.fusionTimer
        XCTAssertEqual(timer?.isValid, true, "startFusion() should have created a live timer")
        manager = nil
        XCTAssertEqual(
            timer?.isValid, false,
            "deinit must invalidate fusionTimer, or the run loop keeps firing it forever"
        )
    }
}
