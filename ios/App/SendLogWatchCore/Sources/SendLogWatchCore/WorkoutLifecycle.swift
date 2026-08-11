import Foundation

/// Guards `WorkoutManager.start()` against a double tap reaching HealthKit
/// setup twice, and gives each accepted start a generation stamp so a stale
/// async task from a PREVIOUS start (the cached-phase fetch) can detect it is
/// stale and no-op instead of overwriting state for the CURRENT workout.
///
/// Issue #476: once `WorkoutManager` is hoisted to App scope it outlives any
/// single workout, so both hazards below are real (they weren't while the
/// manager died with the view):
/// - `start()` has no in-flight guard before its first suspension point and
///   only flips its "running" flag after the `await`s inside it — two taps
///   before that point both proceed, each standing up its own HealthKit
///   session and fusion timer.
/// - the background phase-fetch `Task` started inside `start()` can resolve
///   after a LATER `start()` has already begun, and unguarded would stomp the
///   new workout's `cachedPhase` with the old one's answer.
public struct WorkoutStartGuard: Sendable {
    public private(set) var starting = false
    public private(set) var generation = 0

    public init() {}

    /// Call synchronously, before any `await` in the guarded function.
    /// Returns the generation stamp for this start, or `nil` if a start is
    /// already in flight — the caller must drop the call rather than proceed.
    public mutating func begin() -> Int? {
        guard !starting else { return nil }
        starting = true
        generation += 1
        return generation
    }

    /// Call unconditionally when the guarded function returns (success or
    /// failure), but only on the call that successfully `begin()`'d.
    public mutating func finish() {
        starting = false
    }

    /// Whether `generation` is still the most recently accepted start — i.e.
    /// whether async work stamped with it is still safe to apply.
    public func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }
}

/// Decides whether the live-workout widget snapshot needs a push this tick.
///
/// Issue #476: `AttemptDetector.liveAttemptCount` re-applies the post-filter
/// (minimum duration / minimum active-motion ticks) on every read, so a
/// boulder can cross that filter — and the visible count jump from 0 to 1 —
/// while the detector's phase stays `.autoClimbing` the whole time (no
/// resting/climbing transition happens). Pushing to the widget only on phase
/// transitions leaves its boulder count stuck at the pre-filter value until
/// the attempt later ends.
public enum WidgetCountSync {
    public static func shouldPush(stateChanged: Bool, countBefore: Int, countAfter: Int) -> Bool {
        stateChanged || countBefore != countAfter
    }
}

/// Orchestrates `HKWorkoutSession.startActivity` + `HKLiveWorkoutBuilder
/// .beginCollection`. `startActivity` makes watchOS treat the session as THE
/// one active session immediately; if `beginCollection` then throws, that
/// session is live but nothing has referenced it outside this call yet — a
/// caller that only assigns its own `session`/`builder` handle on success
/// (as `WorkoutManager.start()` does) can never reach it again through
/// `end()`'s `guard let session`. Left alone, that orphans the session: it
/// keeps HealthKit collecting in the background and blocks every later
/// `HKWorkoutSession` from starting (watchOS permits only one) until the
/// watch app is force-quit (#480).
///
/// On failure this detaches both delegates, then ends the session and
/// discards the builder, before rethrowing — detach first, because Apple
/// doesn't document `delegate = nil` as synchronously cancelling a callback
/// HealthKit already dispatched, so `WorkoutManager`'s own delegate methods
/// additionally guard by identity (`=== self.session` / `=== self.builder`)
/// as the real backstop. Never touches anything beyond the five closures
/// passed in (`startActivity`, `beginCollection`, `detachDelegates`,
/// `endSession`, `discardBuilder`) — in particular, it never assigns a
/// caller's own state, so a long-lived manager spanning many workouts
/// (#476A) can't have this failure path leave a stale handle for the next
/// `start()` to clean up.
///
/// `@MainActor`: `WorkoutManager.start()` (the one caller) is itself
/// `@MainActor`, and every one of these five calls ran on the main thread
/// pre-extraction, serialized with every other mutation this class makes to
/// the session/builder pair — `detachDelegates` in particular is the fix's
/// first line of defence against a HealthKit callback racing the teardown
/// (see above), so it must keep running on the same actor as the rest of
/// `start()`, not hop to the cooperative pool the way a plain `nonisolated
/// async` function would (SE-0338: a nonisolated async function does not
/// inherit its caller's actor). Isolating here, not by making the closures
/// `@MainActor` individually, keeps the call site a plain `await` with no
/// extra annotations.
///
/// Pure control flow, no HealthKit dependency otherwise: `startActivity`/
/// `beginCollection`/`end`/`discardWorkout` are closures the caller wires to
/// its real session/builder, so this is covered by `swift test` — a real
/// `HKWorkoutSession` needs the HealthKit entitlement, which neither this
/// package's test host nor the unsigned `SendLogWatchTests` app-target host
/// has.
@MainActor
public enum WorkoutSessionActivation {
    public static func run(
        startActivity: () -> Void,
        beginCollection: () async throws -> Void,
        detachDelegates: () -> Void,
        endSession: () -> Void,
        discardBuilder: () -> Void
    ) async throws {
        startActivity()
        do {
            try await beginCollection()
        } catch {
            detachDelegates()
            endSession()
            discardBuilder()
            throw error
        }
    }
}

/// Whether a successful save should clear `WorkoutManager.failedBundle`.
///
/// Review finding R1: `save()`'s success path used to clear `failedBundle`
/// unconditionally, on ANY successful save — reachable once F1 correctly
/// unblocked Start: workout N fails `.lost` (`failedBundle = bundleN`), the
/// user starts and successfully saves workout N+1 instead of retrying, and
/// the unconditional clear silently discarded bundleN's last in-memory copy
/// while rendering "Saved". CLAUDE.md #264 requires unsaved data to be
/// reported, never swallowed. The fix is an id match — an unrelated failed
/// bundle must survive a different workout's successful save.
///
/// Kept as a pure Core comparison (review finding X1) rather than exercised
/// only through the real `save()`, which needs live network
/// (`WidgetBridge.refreshStatus()`) and `OfflineQueue` disk I/O to reach its
/// success path from a test — that made the two tests that drove it directly
/// ~160x slower than the rest of the suite and intermittently timing-flaky.
/// `WorkoutManager.save()` (`private`) is the one production call site;
/// verify the wiring by inspection there, not by reproducing the network
/// path in a test here.
public enum FailedBundleClear {
    public static func shouldClear(failedId: UUID?, savedId: UUID) -> Bool {
        failedId == savedId
    }
}
