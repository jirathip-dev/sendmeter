import Foundation

/// #615: the compact `workoutCompleted` notification the watch sends to the
/// phone AFTER its save bundle is durably queued. Only safe canonical summary
/// fields + the stable ids ride the wire — no raw trace, no health values —
/// and the phone renders it as a PENDING session that realtime/server data
/// reconciles by `session_id`. This payload NEVER inserts a durable session
/// on the phone; idempotent replay by session id is the whole design.
public enum WorkoutCompletedReport {
    public static let kind = "workoutCompleted"
    public static let sessionIdKey = "session_id"
    public static let workoutIdKey = "workout_id"
    public static let startedAtKey = "started_at"
    public static let endedAtKey = "ended_at"
    public static let attemptCountKey = "attempt_count"
    public static let durationMinKey = "duration_min"
    public static let rpeKey = "rpe"
    public static let phaseKey = "phase"
    public static let typeKey = "type"
    public static let typeLabelKey = "type_label"
    public static let noteKey = "note"
    public static let rpeConfirmedKey = "rpe_confirmed"

    /// The canonical summary fields a completed workout notification may
    /// carry. Built from the save bundle at send time (the same values the
    /// bundle will upload), so the pending row on the phone matches the
    /// eventual server row field for field.
    public struct Summary: Sendable, Equatable {
        public let sessionId: UUID
        public let workoutId: UUID
        public let startedAt: Date
        public let endedAt: Date
        public let attemptCount: Int
        public let durationMin: Int
        public let rpe: Double
        public let phase: String
        public let type: String
        public let typeLabel: String
        public let note: String
        public let rpeConfirmed: Bool

        public init(
            sessionId: UUID,
            workoutId: UUID,
            startedAt: Date,
            endedAt: Date,
            attemptCount: Int,
            durationMin: Int,
            rpe: Double,
            phase: String,
            type: String,
            typeLabel: String,
            note: String,
            rpeConfirmed: Bool
        ) {
            self.sessionId = sessionId
            self.workoutId = workoutId
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.attemptCount = attemptCount
            self.durationMin = durationMin
            self.rpe = rpe
            self.phase = phase
            self.type = type
            self.typeLabel = typeLabel
            self.note = note
            self.rpeConfirmed = rpeConfirmed
        }
    }

    /// Builds the wire payload. Dates are epoch SECONDS — the same clock the
    /// live-workout beat uses. The caller adds the ownership stamp
    /// (`LiveMirrorOwnership.stamped`) and the build/queue report keys
    /// (`WatchBuild.stamp`); the phone plugin strips those back off before
    /// forwarding, so the WebView sees exactly this shape.
    public static func payload(summary: Summary) -> [String: Any] {
        [
            "kind": kind,
            sessionIdKey: summary.sessionId.uuidString,
            workoutIdKey: summary.workoutId.uuidString,
            startedAtKey: summary.startedAt.timeIntervalSince1970,
            endedAtKey: summary.endedAt.timeIntervalSince1970,
            attemptCountKey: summary.attemptCount,
            durationMinKey: summary.durationMin,
            rpeKey: summary.rpe,
            phaseKey: summary.phase,
            typeKey: summary.type,
            typeLabelKey: summary.typeLabel,
            noteKey: summary.note,
            rpeConfirmedKey: summary.rpeConfirmed,
        ]
    }

    /// Parses a payload back into the canonical summary (the phone-side
    /// consumer). nil when a required field is missing or malformed — a
    /// mixed-version payload must be skipped, never half-read.
    public static func summary(in payload: [String: Any]) -> Summary? {
        guard
            let sessionId = (payload[sessionIdKey] as? String).flatMap(UUID.init(uuidString:)),
            let workoutId = (payload[workoutIdKey] as? String).flatMap(UUID.init(uuidString:)),
            let startedAt = payload[startedAtKey] as? Double,
            let endedAt = payload[endedAtKey] as? Double,
            let attemptCount = payload[attemptCountKey] as? Int,
            let durationMin = payload[durationMinKey] as? Int,
            let rpe = payload[rpeKey] as? Double,
            let phase = payload[phaseKey] as? String,
            let type = payload[typeKey] as? String,
            let typeLabel = payload[typeLabelKey] as? String,
            let note = payload[noteKey] as? String,
            let rpeConfirmed = payload[rpeConfirmedKey] as? Bool
        else {
            return nil
        }
        return Summary(
            sessionId: sessionId,
            workoutId: workoutId,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: endedAt),
            attemptCount: attemptCount,
            durationMin: durationMin,
            rpe: rpe,
            phase: phase,
            type: type,
            typeLabel: typeLabel,
            note: note,
            rpeConfirmed: rpeConfirmed
        )
    }

    /// Removes the report keys before the payload is forwarded to the
    /// WebView — same contract as `WatchBuildReport.stripped` (the phone
    /// plugin already calls that), kept here for symmetry and for any
    /// consumer that handles the payload without the plugin layer.
    public static func stripped(_ payload: [String: Any]) -> [String: Any] {
        var out = payload
        out.removeValue(forKey: "kind")
        return out
    }
}

/// #615: the notification is only sent after the save bundle is DURABLY
/// handled — `.queued` (atomically on disk) or `.uploadedDirect` (uploaded
/// while persisting failed). `.lost` means nothing durable exists, so the
/// phone must NOT see a pending row that could never reconcile — the watch
/// shows its own failure/retry surface instead. Pure so the durable-before-
/// notify ordering is testable on Linux CI.
public enum WorkoutCompletedNotify {
    public static func shouldNotify(after outcome: QueuePersistOutcome) -> Bool {
        outcome != .lost
    }
}
