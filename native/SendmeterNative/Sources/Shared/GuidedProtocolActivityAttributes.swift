import ActivityKit
import Foundation

/// ActivityKit wire type for the guided-protocol Live Activity (#674).
///
/// Compiled into BOTH the app target (which starts/updates/ends the activity
/// through `GuidedProtocolActivityManager`) and the widget extension target
/// (which renders it) from this single source file — the two targets share one
/// XcodeGen project, so there is no duplicated copy to drift (unlike the web,
/// where `ActivityModels.swift` is duplicated across its widget and plugin
/// targets with a KEEP-IN-SYNC comment). ActivityKit matches an activity to
/// its rendering widget by type name + Codable shape, so this must stay a
/// plain wire type: no logic, no references to app-only code.
///
/// What is shared is EXACTLY this file. The widget extension target has no
/// SendmeterCore dependency and never imports `GuidedActivityContent` — the
/// app-side manager renders the ContentState from Core and pushes it; the
/// widget only renders the pushed state. Keep the two targets' use of the
/// `phase` token and the `progress` field in step (the manager produces them,
/// the widget renders them), and never let the widget start importing Core.
public struct GuidedProtocolActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        /// Machine token for the current segment: "prepare" | "work" |
        /// "switch" | "rest" | "setRest" | "complete". The widget's color
        /// mapping keys off this, so label text can change without breaking
        /// the card's rendering.
        public var phase: String
        public var phaseLabel: String
        public var detailLabel: String
        /// Absolute window of the current segment — the lock screen renders
        /// its countdown natively from these (`Text(timerInterval:)`), so the
        /// app only speaks on state transitions, never on a tick.
        public var segmentStart: Date
        public var segmentEnd: Date
        public var progress: Double
        public var peakKilograms: Double?
        public var targetKilograms: Double?
    }

    public var presetID: UUID
    public var runID: UUID
}
