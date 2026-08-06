import Foundation
import XCTest
@testable import SendLogWatch_Watch_App

/// Review finding F1 (#476): once `WorkoutManager` is App-scoped, its
/// save-outcome fields outlive any single workout. `start()` must decide the
/// fate of each of them explicitly — clearing the per-save transients, but
/// deliberately preserving `failedBundle` (the #287 last in-memory copy of a
/// workout that couldn't be saved) so it's never silently discarded.
///
/// This is the production entry point (`WorkoutManager.start()`), not a
/// parallel copy of the reset logic — a regression here is a regression in
/// exactly what ships.
@MainActor
final class WorkoutSavePathResetTests: XCTestCase {
    private func sampleBundle() -> WorkoutSaveBundle {
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

    /// Review finding F1, the reset half of the fix: a stale `justSaved` /
    /// `stillQueued` / `ending` from workout N used to survive untouched into
    /// N+1's `start()` — harmless for `ending` only by luck (every path
    /// happened to reset it), but `justSaved` covering a running N+1 with a
    /// "Saved ✓" flash (no End control) was scenario C of the review.
    func testStartClearsPerSaveTransientsFromAPreviousWorkout() async {
        let manager = WorkoutManager()
        manager.justSaved = true
        manager.stillQueued = true
        manager.ending = true

        await manager.start()

        XCTAssertFalse(manager.justSaved, "a stale justSaved from a previous workout must not survive into the next one's render")
        XCTAssertFalse(manager.stillQueued)
        XCTAssertFalse(manager.ending)
    }

    /// Review finding F1, scenario B: a `.lost` `failedBundle` used to make
    /// `start()` unreachable from the UI forever (no navigation cleared it
    /// any more, post-hoist). The fix is at the view layer (Start is always
    /// offered, per `WorkoutScreenSelection`), but `start()` itself must
    /// never treat a stale `failedBundle` as a reason to bail, and must not
    /// discard it either — it's the only in-memory copy of that workout's
    /// unsaved data.
    func testStartSucceedsWithAStaleFailedBundlePresentAndPreservesIt() async {
        let manager = WorkoutManager()
        let stale = sampleBundle()
        manager.failedBundle = stale

        await manager.start()

        XCTAssertEqual(manager.acceptedStartCount, 1, "a stale failedBundle from a previous workout must not block start()")
        XCTAssertNotNil(manager.failedBundle, "the previous workout's failed bundle must survive — it's the only in-memory copy of unsaved data (#287)")
        XCTAssertEqual(manager.failedBundle?.workout.id, stale.workout.id, "start() must not replace it with something else, either")
    }

    // Re-review finding R1's id-matched `failedBundle` clear used to be
    // tested here, directly against `save()`. Review finding X1: driving
    // `save()` from a unit test requires it to reach a real
    // `OfflineQueue.enqueue` (disk I/O) and `WidgetBridge.refreshStatus()`
    // (live network) — each of those two tests took ~15.9s, and together
    // they made this whole target fail intermittently (measured by the
    // reviewer at ~40% of runs) with no cleanup of the `pending/<uuid>.json`
    // files they left behind. The comparison itself is pure and is now
    // tested fast, deterministically, and CI-covered as
    // `FailedBundleClearTests` in `SendLogWatchCoreTests`. `save()` is
    // `private` again; its one line wiring `FailedBundleClear.shouldClear`
    // is verified by inspection, not by reproducing the network path here.
}
