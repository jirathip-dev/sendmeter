import Foundation

/// Which screen `WorkoutLiveView` should show. Kept as a pure Core decision
/// table (rather than an inline `if/else if` in the view body) so the
/// ownership rules are unit-testable — see issue #476 review finding F1.
public enum WorkoutScreen: Equatable, Sendable {
    case live
    case saved
    case start
}

/// Issue #476, review finding F1: once `WorkoutManager` is App-scoped, its
/// save-outcome fields (`justSaved`, `failedBundle`) outlive any single
/// workout. The pre-review version of the hoist checked them BEFORE
/// `isRunning`, and `start()` never reset them — so a save outcome from
/// workout N could render *over* a running workout N+1 (no End control:
/// exactly the bug #476 exists to fix), and a `.lost` `failedBundle` made
/// Start permanently unreachable for the rest of the app session.
///
/// Two rules fix both, and this function is where they're enforced:
/// 1. **A running workout always wins the render.** `isRunning` is checked
///    first — nothing from a previous workout's save can ever cover a live
///    one.
/// 2. **A failed save can never block Start.** `failedBundle` is not a
///    parameter here at all — structurally, this function cannot gate a
///    screen on it. `WorkoutLiveView` still surfaces a failed bundle (the
///    #287 last in-memory copy of a workout that couldn't be saved) — as a
///    banner INSIDE `.start`'s content, not as a competing exclusive screen.
public enum WorkoutScreenSelection {
    public static func screen(isRunning: Bool, justSaved: Bool) -> WorkoutScreen {
        if isRunning { return .live }
        if justSaved { return .saved }
        return .start
    }
}
