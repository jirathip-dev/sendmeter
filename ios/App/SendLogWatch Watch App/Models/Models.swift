import Foundation
import SendLogWatchCore

// MARK: - Detection domain

struct WorkoutSummary {
    let workoutId: UUID    // generated at start; matches live_workouts + the final row
    let startedAt: Date
    let endedAt: Date
    let avgHR: Double?
    let maxHR: Double?
    let activeKcal: Double?
    let elevationGainM: Double
    let attempts: [Attempt]
    let predictedRPE: Double
    let rawTrace: [[Double?]]  // 1Hz [t_s, alt_m, motion_rms, hr]
}

struct StoppedRecording {
    let durationMs: Int
    let peakKg: Double
    let avgKg: Double
    let samples: [(t: Double, kg: Double)]
}

// MARK: - Database rows (snake_case matches PostgREST)

nonisolated struct SessionInsert: Codable {
    var id: UUID
    var date: String           // YYYY-MM-DD
    var type: String
    var typeLabel: String
    var durationMin: Int
    var rpe: Double            // decimal (SL-89): 0.5-step manual entry, or 0.1-precision auto-tracked (#107); DB column is numeric(3,1)
    /// #114: false for an RPE nobody reviewed — the #280 W'-depletion
    /// prediction the gauge session logs on its own. Defaults to true, which
    /// is what an auto-tracked workout's user-confirmed RPE is.
    var rpeConfirmed: Bool = true
    var note: String
    var phase: String
    var groupId: UUID?         // Tindeq gauge session link
    var workoutSource: String? // immutable provenance badge (SL-43): "watch" for auto workouts, nil otherwise

    enum CodingKeys: String, CodingKey {
        case id, date, type, rpe, note, phase
        case rpeConfirmed = "rpe_confirmed"
        case typeLabel = "type_label"
        case durationMin = "duration_min"
        case groupId = "group_id"
        case workoutSource = "workout_source"
    }
}

nonisolated struct ClimbWorkoutInsert: Codable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var avgHr: Double?
    var maxHr: Double?
    var activeKcal: Double?
    var elevationGainM: Double
    var attemptsDetected: Int
    var attemptsConfirmed: Int
    var rpePredicted: Double
    var rpeConfirmed: Double
    var meanEffort: Double
    var attemptsPer10min: Double
    var sessionId: UUID
    var raw: [[Double?]]?

    enum CodingKeys: String, CodingKey {
        case id, raw
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case avgHr = "avg_hr"
        case maxHr = "max_hr"
        case activeKcal = "active_kcal"
        case elevationGainM = "elevation_gain_m"
        case attemptsDetected = "attempts_detected"
        case attemptsConfirmed = "attempts_confirmed"
        case rpePredicted = "rpe_predicted"
        case rpeConfirmed = "rpe_confirmed"
        case meanEffort = "mean_effort"
        case attemptsPer10min = "attempts_per_10min"
        case sessionId = "session_id"
    }
}

/// SL-90: mid-workout durable flush — every ~2 min the watch upserts the
/// in-progress climb_workouts row (trace + counts so far) so a dead battery
/// or crash doesn't lose hours of data. Only the fields known mid-workout;
/// the final WorkoutSaveBundle merge-upserts the full row over it. ended_at
/// is a provisional "data through here" mark (the column is NOT NULL).
nonisolated struct ClimbWorkoutPartialUpsert: Codable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var elevationGainM: Double
    var attemptsDetected: Int
    var attemptsConfirmed: Int
    var raw: [[Double?]]?

    enum CodingKeys: String, CodingKey {
        case id, raw
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case elevationGainM = "elevation_gain_m"
        case attemptsDetected = "attempts_detected"
        case attemptsConfirmed = "attempts_confirmed"
    }
}

nonisolated struct LabeledWorkoutRow: Codable {
    var avgHr: Double?
    var meanEffort: Double?
    var attemptsPer10min: Double?
    var rpeConfirmed: Double?

    enum CodingKeys: String, CodingKey {
        case avgHr = "avg_hr"
        case meanEffort = "mean_effort"
        case attemptsPer10min = "attempts_per_10min"
        case rpeConfirmed = "rpe_confirmed"
    }
}

nonisolated struct ClimbAttemptInsert: Codable {
    var id: UUID
    var workoutId: UUID
    var startedAt: Date
    var durationS: Double
    var elevationGainM: Double
    var avgHr: Double?
    var peakHr: Double?
    var motionIntensity: Double
    var effortScore: Double
    var source: String         // "auto" | "manual"

    enum CodingKeys: String, CodingKey {
        case id, source
        case workoutId = "workout_id"
        case startedAt = "started_at"
        case durationS = "duration_s"
        case elevationGainM = "elevation_gain_m"
        case avgHr = "avg_hr"
        case peakHr = "peak_hr"
        case motionIntensity = "motion_intensity"
        case effortScore = "effort_score"
    }
}

nonisolated struct TindeqRecordingInsert: Codable {
    var durationMs: Int
    var peakKg: Double
    var avgKg: Double
    var sampleCount: Int
    var note: String
    var tag: String
    var side: String           // "", "left", "right", "both"
    var groupId: UUID?         // gauge session
    var samples: [[Double]]

    enum CodingKeys: String, CodingKey {
        case note, samples, tag, side
        case durationMs = "duration_ms"
        case peakKg = "peak_kg"
        case avgKg = "avg_kg"
        case sampleCount = "sample_count"
        case groupId = "group_id"
    }
}

nonisolated struct TindeqTagRow: Codable {
    var tag: String
}

/// A row of the `tindeq_tags` registry (SL-92): the hidden flag SL-94 filters
/// on, plus the force-curve params the phone banks there (#280) so the watch
/// can predict a session's RPE from W' depletion. Both curve columns are null
/// until that tag has enough long holds for the phone to fit a curve.
nonisolated struct TagRegistryRow: Codable {
    var name: String
    var hidden: Bool
    var cfKg: Double?
    var wPrimeKgs: Double?

    enum CodingKeys: String, CodingKey {
        case name, hidden
        case cfKg = "cf_kg"
        case wPrimeKgs = "w_prime_kgs"
    }
}

/// A visible tag as the Force screen needs it: the name for the picker, plus
/// its persisted curve for the #280 RPE prediction (nil until fitted).
nonisolated struct TindeqTagInfo: Sendable, Equatable {
    var name: String
    var cf: Double?
    var wPrime: Double?
}

nonisolated struct UserSettingsRow: Codable {
    var currentPhase: String

    enum CodingKeys: String, CodingKey {
        case currentPhase = "current_phase"
    }
}

/// Read-only projection of the latest health_metrics row — the iPhone writes
/// the full row; the watch only reads the score/zone back for display.
nonisolated struct HealthMetricRow: Codable {
    var date: String
    var readiness: Int?
    var zone: String?
}

/// Live workout heartbeat (SL-41). One row per user (PK user_id), upserted
/// every ~5s while a workout runs so the web Workout tab can mirror it.
nonisolated struct LiveWorkoutUpsert: Codable {
    var userId: UUID
    var workoutId: UUID
    var status: String         // "live" | "ended"
    var startedAt: Date
    var hr: Double?
    var attemptCount: Int
    var activeKcal: Double?
    var elevationGainM: Double?
    var climbing: Bool
    // Phase timestamps so the phone mirror can render exact timers:
    // climbing → climbingSince set; resting → restStartedAt (+ restTargetS).
    var climbingSince: Date?
    var restStartedAt: Date?
    var restTargetS: Int?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case status, hr, climbing
        case userId = "user_id"
        case workoutId = "workout_id"
        case startedAt = "started_at"
        case attemptCount = "attempt_count"
        case activeKcal = "active_kcal"
        case elevationGainM = "elevation_gain_m"
        case climbingSince = "climbing_since"
        case restStartedAt = "rest_started_at"
        case restTargetS = "rest_target_s"
        case updatedAt = "updated_at"
    }

    // #477 review F1: Swift's synthesized `Encodable` uses `encodeIfPresent`
    // for every `Optional` property, which OMITS the key entirely when the
    // value is nil. `upsert(row, onConflict: "user_id")` sends this straight
    // to PostgREST, which only overwrites columns present in the payload —
    // an omitted `hr` key therefore leaves `live_workouts.hr` at its last
    // non-nil value FOREVER, not absent. That is the exact "stale reading
    // survives as if live" bug #477 exists to close, just moved onto the
    // wire instead of fixed. `hr` must encode an explicit JSON `null` when
    // absent, so this type needs a hand-written `encode(to:)`.
    //
    // Every OTHER optional here deliberately keeps the omit-when-nil
    // default: `markEnded()` passes nil for `activeKcal`/`elevationGainM`/
    // `climbingSince`/`restStartedAt`/`restTargetS` specifically so that
    // final upsert does not stomp those columns with null. This is a
    // per-field decision, not a blanket switch to explicit nulls — do not
    // "simplify" the other fields to match `hr` without checking their
    // callers first.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(workoutId, forKey: .workoutId)
        try container.encode(status, forKey: .status)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(hr, forKey: .hr) // explicit null, not omitted, when nil
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encodeIfPresent(activeKcal, forKey: .activeKcal)
        try container.encodeIfPresent(elevationGainM, forKey: .elevationGainM)
        try container.encode(climbing, forKey: .climbing)
        try container.encodeIfPresent(climbingSince, forKey: .climbingSince)
        try container.encodeIfPresent(restStartedAt, forKey: .restStartedAt)
        try container.encodeIfPresent(restTargetS, forKey: .restTargetS)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// One confirmed workout = three idempotent upserts, bundled for the offline queue.
nonisolated struct WorkoutSaveBundle: Codable {
    var session: SessionInsert
    var workout: ClimbWorkoutInsert
    var attempts: [ClimbAttemptInsert]
    /// Which account was signed in when this bundle was persisted to disk
    /// (issue #158) — stamped by `OfflineQueue.persist`, checked by `drain()`
    /// so an item queued under one account can't silently upload under
    /// whichever account happens to be signed in when the queue next drains.
    /// `nil` only for items written before this field existed (legacy
    /// on-disk files); see `shouldDrain`.
    var enqueuedUserId: UUID? = nil
}
