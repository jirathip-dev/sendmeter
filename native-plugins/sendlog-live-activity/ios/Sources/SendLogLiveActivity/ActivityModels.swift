import ActivityKit
import Foundation

// KEEP IN SYNC with ios/App/SendmeterWidgets/ActivityModels.swift.
// ActivityKit matches the app's activity to the widget by unqualified type
// name + Codable shape — field names/types must match exactly (this copy
// adds `public` + explicit inits, which doesn't affect the Codable shape).

/// Phone (or watch-mirrored) workout on the lock screen.
public struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// "climbing" | "resting" | "ended"
        public var phase: String
        public var phaseStartedAt: Date
        public var restTargetS: Int?
        public var boulderCount: Int

        public init(phase: String, phaseStartedAt: Date, restTargetS: Int?, boulderCount: Int) {
            self.phase = phase
            self.phaseStartedAt = phaseStartedAt
            self.restTargetS = restTargetS
            self.boulderCount = boulderCount
        }
    }

    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}

/// Tindeq guided protocol / free hold — CURRENT segment only (≤4 KB rule).
public struct TindeqActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// "prepare" | "hold" | "switch" | "rest" | "setRest" | "done"
        public var segPhase: String
        public var side: String?
        public var rep: Int
        public var set: Int
        public var segStart: Date
        public var segEnd: Date
        public var peakKg: Double?

        public init(segPhase: String, side: String?, rep: Int, set: Int, segStart: Date, segEnd: Date, peakKg: Double?) {
            self.segPhase = segPhase
            self.side = side
            self.rep = rep
            self.set = set
            self.segStart = segStart
            self.segEnd = segEnd
            self.peakKg = peakKg
        }
    }

    public var title: String
    public var targetKg: Double?

    public init(title: String, targetKg: Double?) {
        self.title = title
        self.targetKg = targetKg
    }
}
