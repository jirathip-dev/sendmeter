import ActivityKit
import Foundation

/// ActivityKit wire type for the manual workout Live Activity (#763).
///
/// Compiled into BOTH the app target (which starts/updates/ends the activity
/// through `ManualWorkoutActivityManager`) and the widget extension target
/// (which renders it) from this single source file — the same rule and
/// KEEP-IN-SYNC discipline as `GuidedProtocolActivityAttributes`. The widget
/// extension has no SendmeterCore dependency and never sees
/// `ManualWorkoutActivityContent`; it renders the wire `ContentState`
/// verbatim.
public struct ManualWorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// "climbing" | "resting" — `.restOver` collapses to "resting" to
        /// match the Capacitor `WorkoutLiveActivity` wire contract.
        public var phase: String
        /// When the current phase began — timers render natively from this.
        public var phaseStartedAt: Date
        /// Rest countdown target (seconds); nil hides the countdown cap.
        public var restTargetS: Int?
        public var boulderCount: Int

        public init(
            phase: String,
            phaseStartedAt: Date,
            restTargetS: Int?,
            boulderCount: Int
        ) {
            self.phase = phase
            self.phaseStartedAt = phaseStartedAt
            self.restTargetS = restTargetS
            self.boulderCount = boulderCount
        }
    }

    /// Workout start (static for the activity's lifetime).
    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
