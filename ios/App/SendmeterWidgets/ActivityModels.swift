import ActivityKit
import Foundation

// KEEP IN SYNC with
// native-plugins/sendlog-live-activity/ios/Sources/SendLogLiveActivity/ActivityModels.swift
// ActivityKit matches the app's activity to this widget by unqualified type
// name + Codable shape — struct names, field names and field types must
// match exactly (the plugin copy adds `public` + explicit inits, which
// doesn't affect the shape), or the lock-screen card renders as a
// placeholder. Guarded by src/lib/iosKeepInSyncInvariants.test.ts.

/// Phone (or watch-mirrored) workout on the lock screen: CLIMBING count-up /
/// RESTING countdown, boulder count, Boulder/Stop buttons.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "climbing" | "resting" | "ended"
        var phase: String
        /// When the current phase began — timers render natively from this.
        var phaseStartedAt: Date
        /// Rest countdown target (seconds); nil hides the countdown cap.
        var restTargetS: Int?
        var boulderCount: Int
    }

    /// Workout start (static for the activity's lifetime).
    var startedAt: Date
}

/// Tindeq guided protocol / free hold: the CURRENT segment only (the full
/// schedule stays in the app process — content state must stay ≤4 KB).
struct TindeqActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "prepare" | "hold" | "switch" | "rest" | "setRest" | "done"
        var segPhase: String
        /// "left" | "right" | nil
        var side: String?
        var rep: Int
        var set: Int
        /// Absolute window of the current segment — countdown renders natively.
        var segStart: Date
        var segEnd: Date
        var peakKg: Double?
    }

    /// e.g. "Repeaters 7:3 · FDP" or "Free hold · FDP"
    var title: String
    var targetKg: Double?
}
