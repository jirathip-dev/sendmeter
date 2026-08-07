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
    /// Client-minted (#486) so a queued upload's retry is an idempotent
    /// UPSERT rather than a bare INSERT — without this, a drain that
    /// re-attempts after a response was lost (network flaked mid-round-trip,
    /// the server actually got it) would duplicate the recording. The column
    /// still defaults to `gen_random_uuid()`, matching the web app's
    /// `insertRecording` (#106): `id` is set here, not left to the default.
    var id: UUID
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
        case id, note, samples, tag, side
        case durationMs = "duration_ms"
        case peakKg = "peak_kg"
        case avgKg = "avg_kg"
        case sampleCount = "sample_count"
        case groupId = "group_id"
    }
}

/// A Tindeq force recording queued for upload by `PendingRecordingQueue`
/// (#486): "Stop" used to await the network insert directly, right when the
/// user has just finished a max-effort rep — watchOS can suspend the app and
/// freeze the in-flight request at exactly that moment, and unlike a saved
/// workout or gauge session there was NO on-disk fallback at all, so the rep
/// was gone. Mirrors `WorkoutSaveBundle`: the row to insert plus the account
/// stamp `shouldDrain` checks (#158).
nonisolated struct PendingTindeqRecording: Codable {
    var row: TindeqRecordingInsert
    /// Which account was signed in when this recording was persisted to disk
    /// (issue #158) — stamped by `PendingRecordingQueue.persist`, checked by
    /// `drain()` so a recording queued under one account can't silently
    /// upload under whichever account happens to be signed in when the queue
    /// next drains. `nil` only for items written before this field existed
    /// (there are none pre-#486, but the pattern is kept identical to the
    /// other two queues); see `shouldDrain`.
    var enqueuedUserId: UUID? = nil
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
