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

/// Why a bundle was quarantined (#475 F3) — kept distinct because the two
/// cases carry different confidence: one is a proven-permanent DB rejection,
/// the other is a bet that a bundle failing this many times in a row is not
/// coming back.
nonisolated enum QuarantineReason: String, Codable {
    /// `UploadErrorClassifier` positively identified the bundle as violating
    /// the one check constraint this PR set out to catch — quarantined on
    /// the very first attempt.
    case schemaRejection
    /// The bundle failed `QueueRetryPolicy.maxConsecutiveFailures` consecutive
    /// drain passes without the classifier ever recognizing why. Not
    /// provably permanent — but bounded, so an unrecognized permanent error
    /// (a different check constraint, a persistently invalid account, …)
    /// can't park the rest of the queue behind it forever either.
    case stuckRetrying
}

/// A bundle `OfflineQueue.drainPass` gave up retrying (#475) — either
/// `uploadBundle` rejected it with a specific, permanent DB error (today:
/// only the `climb_attempts.duration_s > 0` check violation), or it failed
/// too many consecutive drain passes for an unrecognized reason (`reason`
/// distinguishes the two — see `QuarantineReason`). Written once, atomically,
/// in place of the original `<uuid>.json` file it replaces — the original
/// `bundle` is preserved verbatim inside it (never lost, never silently
/// dropped, per CLAUDE.md #264/#273) alongside which of the three upserts
/// failed and why, for truthful reporting and for a possible future repair
/// pass (#287 precedent).
///
/// Never read back into a normal drain pass; only user sign-out may delete
/// it (#273) — and today NOTHING does even that (the watch has no sign-out
/// queue purge equivalent to the web's `discardQueueOnUserSignOut`), so a
/// `.quarantine` file is effectively permanent on-device storage. Quarantine
/// is expected to be rare, but `bundle.workout.raw` is the 1Hz debug trace
/// (hundreds of KB for a long workout when `keepRawTrace` is on), so this is
/// unbounded growth in the pathological case, not a fixed-size record (#475
/// F8) — a future build could reasonably prune `raw` before quarantining,
/// or add a purge path, without losing the fields that matter for support.
nonisolated struct QuarantinedUpload: Codable {
    var bundle: WorkoutSaveBundle
    var reason: QuarantineReason
    var stage: UploadStage?
    var httpStatus: Int?
    var postgrestCode: String?
    var errorMessage: String?
    /// Set only for `reason == .stuckRetrying` — how many consecutive
    /// passes it failed before being given up on, for auditability.
    var attemptCount: Int?
    var quarantinedAt: Date
}

/// #475 F3's per-item retry counter, persisted on disk (`<uuid>.retry`)
/// alongside the pending bundle so it survives relaunch — an in-memory
/// counter would reset every time the watch app is killed, which is exactly
/// when a stuck item has the most passes to accumulate against.
nonisolated struct RetryLedgerEntry: Codable {
    var consecutiveFailures: Int
    /// Human-readable context for the most recent failure, kept only for
    /// on-device debugging — never part of the classification decision.
    var lastErrorMessage: String?
    var lastAttemptAt: Date
}

/// #472b: when an upload last actually landed, persisted so it survives
/// relaunch — an in-memory-only timestamp would read as "never synced" every
/// time the watch app is killed and relaunched, which is exactly when a
/// stuck queue has been silent the longest. Feeds `SyncFreshnessPolicy` (in
/// `SendLogWatchCore`) for the watch's own "have we synced in a while" UI
/// signal — distinct from `WatchBuildReport`'s quarantine/pending counts,
/// which describe what the PHONE was last told, not what the watch
/// currently knows about itself.
///
/// `userId` (review F20): unlike `pendingCount()`/`quarantinedCount()`,
/// which re-derive account-scoping from each on-disk item's own
/// `enqueuedUserId` on every read, this is a SINGLE global file — without
/// its own account stamp it would silently describe whichever account last
/// wrote it, forever, even after the phone switches accounts. `OfflineQueue.
/// lastSuccessfulSyncAt()` refuses to return a stored value whose `userId`
/// doesn't match who's signed in now.
nonisolated struct LastSyncMarker: Codable {
    var syncedAt: Date
    var userId: UUID?
}
