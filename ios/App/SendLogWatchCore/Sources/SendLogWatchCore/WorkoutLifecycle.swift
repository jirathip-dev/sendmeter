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
