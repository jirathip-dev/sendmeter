import Foundation

/// Navigation destinations reachable from the home list — also the targets
/// the quick-launch complications deep-link to. Kept in Core (rather than
/// only as a SwiftUI `NavigationStack` path element) so the guard below is
/// unit-testable without a simulator.
public enum WatchDest: Hashable, Sendable {
    case force
    case workout
}

/// The complication/quick-launch deep link hosts (`sendmeter://<host>`).
public enum WatchDeepLinkHost: String, Sendable {
    case status
    case force
    case workout
}

/// Resolves a deep link into the `NavigationStack` path it should produce.
///
/// Issue #476: a Force (or status) complication tap used to replace the path
/// unconditionally, popping a running workout off screen with no way back to
/// its End control short of re-navigating from Home. `WorkoutManager` being
/// hoisted to App scope means the workout's *data* now survives that — but a
/// popped screen still leaves the user looking at a gauge with a workout
/// running invisibly behind it. When a workout is running, this keeps
/// `.workout` as the base of the path for any other pushed destination, so
/// the running workout — and its End button — stay one back-tap away.
///
/// `status` targets the stack ROOT (it's a home page, not a pushed
/// destination) and can't carry a base the same way; the workout stays
/// reachable from Home's always-visible "Climb Workout" link instead.
public enum WatchNavigation {
    public static func resolvedPath(for host: WatchDeepLinkHost, workoutRunning: Bool) -> [WatchDest] {
        switch host {
        case .status:
            return []
        case .workout:
            return [.workout]
        case .force:
            return workoutRunning ? [.workout, .force] : [.force]
        }
    }
}
