import Foundation

// MARK: - Detection domain

struct MotionSample {
    let t: TimeInterval        // seconds since workout start
    let altitude: Double       // relative altitude (m)
    let motionRMS: Double      // |userAcceleration| RMS over trailing window (g)
    let hr: Double?            // bpm, may lag
}

enum AttemptSource: String, Codable {
    case auto    // altimeter/motion state machine
    case manual  // logged via the Boulder/Stop button
}

struct Attempt {
    let startedAt: Date
    let durationS: Double
    let elevationGainM: Double
    let avgHR: Double?
    let peakHR: Double?
    let motionIntensity: Double
    let effortScore: Double
    let source: AttemptSource
}

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
    var note: String
    var phase: String
    var groupId: UUID?         // Tindeq gauge session link
    var workoutSource: String? // immutable provenance badge (SL-43): "watch" for auto workouts, nil otherwise

    enum CodingKeys: String, CodingKey {
        case id, date, type, rpe, note, phase
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

/// SL-94: a row from the `tindeq_tags` registry (SL-92) selected `hidden`.
nonisolated struct HiddenTagRow: Codable {
    var name: String
}

nonisolated struct UserSettingsRow: Codable {
    var currentPhase: String

    enum CodingKeys: String, CodingKey {
        case currentPhase = "current_phase"
    }
}

nonisolated struct SessionLoadRow: Codable {
    var date: String
    var load: Int?
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
}

/// A gauge session queued for upload by `PendingSessionQueue` (issue #144):
/// "Log Session" used to await the network insert directly, right when the
/// user lowers their wrist — watchOS then suspends the app and freezes the
/// in-flight request, so the session row (and its group_id) could land
/// minutes to hours later, if at all. `id` is minted client-side at enqueue
/// time so the eventual insert is an idempotent upsert (safe to retry/replay,
/// same pattern as `WorkoutSaveBundle`). `date`/`durationMin`/`note` are
/// captured synchronously at tap time so a delayed drain still logs the
/// session against the moment it actually finished.
nonisolated struct PendingTindeqSession: Codable {
    var id: UUID
    var date: String           // YYYY-MM-DD, captured at enqueue time
    var durationMin: Int
    var rpe: Double
    var note: String
    var groupId: UUID          // Tindeq gauge session link — must survive the upload

    /// Builds the "Log Session" payload as a pure function, so
    /// SendLogWatchTests can exercise it without a live TindeqManager/View.
    /// `now` defaults to the real clock but is injectable for tests.
    /// Duration is clamped to 1-600 min, matching `SessionInsert`/
    /// `WorkoutSaveBundle`'s bound (the DB's date-sanity constraints assume
    /// it); `date` is the session's START day, matching the convention
    /// `Repo.makeSaveBundle` uses for workouts (`summary.startedAt`), not the
    /// moment it happened to be logged.
    static func build(
        sessionStartedAt: Date?,
        now: Date = Date(),
        recordingCount: Int,
        rpe: Double,
        groupId: UUID
    ) -> PendingTindeqSession {
        let started = sessionStartedAt ?? now
        let rawMinutes = Int((now.timeIntervalSince(started) / 60).rounded())
        let note = "\(recordingCount) recording\(recordingCount == 1 ? "" : "s")"
        return PendingTindeqSession(
            id: UUID(),
            date: started.localDateString,
            durationMin: max(1, min(600, rawMinutes)),
            rpe: rpe,
            note: note,
            groupId: groupId
        )
    }
}

extension Calendar {
    /// Always Gregorian, regardless of the device's Region/Calendar setting.
    /// A Thai Region, for example, defaults to the Buddhist calendar
    /// (Gregorian year + 543) — `Calendar.current` silently follows that,
    /// which corrupted every date the watch wrote. Every date computed for
    /// storage or comparison against the database must go through this.
    static var gregorianLocal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }
}

extension Date {
    /// Local calendar date as YYYY-MM-DD (mirrors web src/lib/dates.ts).
    /// Forces the Gregorian calendar AND en_US_POSIX locale so the year is
    /// always AD, never a locale-specific era — see Calendar.gregorianLocal.
    var localDateString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}
