import XCTest
@testable import SendLogWatchCore

final class WorkoutScreenSelectionTests: XCTestCase {
    // MARK: Rule 1 — a running workout always wins the render.

    func testRunningWorkoutWinsOverAStaleJustSavedFlag() {
        // The exact race in review finding F1, scenario A/C: workout N's
        // save briefly sets `justSaved` at the same moment workout N+1 is
        // already running. N+1 must render, not N's stale outcome.
        XCTAssertEqual(WorkoutScreenSelection.screen(isRunning: true, justSaved: true), .live)
    }

    func testRunningWorkoutWinsWhenNothingElseIsSet() {
        XCTAssertEqual(WorkoutScreenSelection.screen(isRunning: true, justSaved: false), .live)
    }

    // MARK: Rule 2 — Start is always reachable when nothing is running.

    func testStartIsReachableWhenNotRunningAndNotJustSaved() {
        XCTAssertEqual(WorkoutScreenSelection.screen(isRunning: false, justSaved: false), .start)
    }

    func testJustSavedShowsOnlyWhileNotRunning() {
        XCTAssertEqual(WorkoutScreenSelection.screen(isRunning: false, justSaved: true), .saved)
    }

    // Note: `failedBundle` deliberately isn't a parameter of `screen(...)` —
    // see the type's doc comment. `WorkoutOwnershipTests
    // .testFailedBundleNeverGatesTheScreen` (SendLogWatchTests, app target)
    // is the fixture-level proof that this is enforced all the way through
    // `WorkoutLiveView.body` — it can't live here in Core, since it needs a
    // real `WorkoutManager`.
}

/// Review finding F1, re-review R3a: comparing the OLD decision shape (a
/// faithful, minimal copy of `WorkoutLiveView.body` as it stood on commit
/// 85764b3 — `git show 85764b3:"ios/App/SendLogWatch Watch App/Views/WorkoutLiveView.swift"`)
/// against the NEW one.
///
/// **Documentation only — NOT regression coverage.** `oldScreen` below is a
/// hand-written replica frozen at 85764b3; it doesn't call any production
/// code, so these tests cannot fail for a reason that reflects current
/// behavior (they'd only ever fail if `oldScreen` itself were edited, which
/// it must never be). Do not cite this suite as evidence a fix works — see
/// `WorkoutScreenSelectionTests` above and `WorkoutOwnershipTests
/// .testFailedBundleNeverGatesTheScreen` for tests that actually exercise
/// production code.
final class WorkoutScreenSelectionHistoricalFixtureTests: XCTestCase {
    private enum OldScreen: Equatable { case failedSave, saved, live, start }

    /// `WorkoutLiveView.body` on 85764b3:
    /// ```swift
    /// if workout.failedBundle != nil { failedSaveContent }
    /// else if workout.justSaved     { savedContent }
    /// else if workout.isRunning     { liveContent }
    /// else                          { startContent }
    /// ```
    /// and `start()` on that commit never reset `failedBundle` or `justSaved`.
    private func oldScreen(failedBundlePresent: Bool, justSaved: Bool, isRunning: Bool) -> OldScreen {
        if failedBundlePresent { return .failedSave }
        if justSaved { return .saved }
        if isRunning { return .live }
        return .start
    }

    /// Scenario A/C from the review: workout N's save outcome (either a
    /// `.lost` failure or a success flash) lands while workout N+1 is
    /// already running. The old order renders N's outcome OVER N+1 — no End
    /// control reachable, which is the exact bug #476 exists to fix.
    func testOldOrderRenderedAStaleFailureOverARunningWorkout() {
        XCTAssertEqual(
            oldScreen(failedBundlePresent: true, justSaved: false, isRunning: true), .failedSave,
            "pre-review: a stale failedBundle from N covered a running N+1 with no End control"
        )
    }

    func testOldOrderRenderedAStaleSuccessFlashOverARunningWorkout() {
        XCTAssertEqual(
            oldScreen(failedBundlePresent: false, justSaved: true, isRunning: true), .saved,
            "pre-review: a stale justSaved from N covered a running N+1 with no End control"
        )
    }

    /// Scenario B from the review: once a save is `.lost`, `failedBundle`
    /// stays set forever (only `retryFailedSave()` on success ever clears
    /// it), and the old order made `.start` unreachable whenever it was set
    /// — permanently locking the user out of starting a new workout.
    func testOldOrderMadeStartUnreachableWithAFailedBundlePresent() {
        for isRunning in [true, false] {
            for justSaved in [true, false] {
                XCTAssertNotEqual(
                    oldScreen(failedBundlePresent: true, justSaved: justSaved, isRunning: isRunning), .start,
                    "pre-review: a failed bundle made Start unreachable regardless of any other state"
                )
            }
        }
    }

    /// The fixed function has no `failedBundlePresent` parameter at all —
    /// this is the structural proof that the same lockout can't recur: Start
    /// is reachable whenever nothing is running and nothing was just saved,
    /// full stop.
    func testNewSelectionCannotBeBlockedByAFailedBundleByConstruction() {
        XCTAssertEqual(WorkoutScreenSelection.screen(isRunning: false, justSaved: false), .start)
    }
}
