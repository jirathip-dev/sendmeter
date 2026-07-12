import Foundation

// MARK: - Detection domain

struct MotionSample {
    let t: TimeInterval        // seconds since workout start
    let altitude: Double       // relative altitude (m)
    let motionRMS: Double      // |userAcceleration| RMS over trailing window (g)
    let hr: Double?            // bpm, may lag
}

struct Attempt {
    let startedAt: Date
    let durationS: Double
    let elevationGainM: Double
    let avgHR: Double?
    let peakHR: Double?
    let motionIntensity: Double
    let effortScore: Double
}

struct WorkoutSummary {
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

struct SessionInsert: Codable {
    var id: UUID
    var date: String           // YYYY-MM-DD
    var type: String
    var typeLabel: String
    var durationMin: Int
    var rpe: Int
    var note: String
    var phase: String
    var groupId: UUID?         // Tindeq gauge session link

    enum CodingKeys: String, CodingKey {
        case id, date, type, rpe, note, phase
        case typeLabel = "type_label"
        case durationMin = "duration_min"
        case groupId = "group_id"
    }
}

struct ClimbWorkoutInsert: Codable {
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
    var rpeConfirmed: Int
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

struct LabeledWorkoutRow: Codable {
    var avgHr: Double?
    var meanEffort: Double?
    var attemptsPer10min: Double?
    var rpeConfirmed: Int?

    enum CodingKeys: String, CodingKey {
        case avgHr = "avg_hr"
        case meanEffort = "mean_effort"
        case attemptsPer10min = "attempts_per_10min"
        case rpeConfirmed = "rpe_confirmed"
    }
}

struct ClimbAttemptInsert: Codable {
    var id: UUID
    var workoutId: UUID
    var startedAt: Date
    var durationS: Double
    var elevationGainM: Double
    var avgHr: Double?
    var peakHr: Double?
    var motionIntensity: Double
    var effortScore: Double

    enum CodingKeys: String, CodingKey {
        case id
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

struct TindeqRecordingInsert: Codable {
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

struct TindeqTagRow: Codable {
    var tag: String
}

struct UserSettingsRow: Codable {
    var currentPhase: String

    enum CodingKeys: String, CodingKey {
        case currentPhase = "current_phase"
    }
}

struct SessionLoadRow: Codable {
    var date: String
    var load: Int?
}

struct HealthMetricsUpsert: Codable {
    var date: String // YYYY-MM-DD local
    var hrvSdnnMs: Double?
    var restingHr: Double?
    var sleepHours: Double?
    var bodyMassKg: Double?
    var readiness: Int?
    var zone: String?
    var computedAt: Date

    enum CodingKeys: String, CodingKey {
        case date, readiness, zone
        case hrvSdnnMs = "hrv_sdnn_ms"
        case restingHr = "resting_hr"
        case sleepHours = "sleep_hours"
        case bodyMassKg = "body_mass_kg"
        case computedAt = "computed_at"
    }
}

/// One confirmed workout = three idempotent upserts, bundled for the offline queue.
struct WorkoutSaveBundle: Codable {
    var session: SessionInsert
    var workout: ClimbWorkoutInsert
    var attempts: [ClimbAttemptInsert]
}

extension Date {
    /// Local calendar date as YYYY-MM-DD (mirrors web src/lib/dates.ts).
    var localDateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: self)
    }
}
