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
    /// #529 F6: explicit row-level ownership stamp, set only by
    /// `Repo.makeSaveBundle` (the auto-tracked workout path) from the run's
    /// immutable `ownerUserId`. Every other caller (manual Tindeq sessions)
    /// leaves this `nil`, which the Optional `Encodable` OMITS from the
    /// payload entirely — the column's `default auth.uid()`
    /// (`20260711000000_initial_schema.sql`) then behaves exactly as before
    /// this fix, so this is additive only for the workout path. When set,
    /// `with check (auth.uid() = user_id)` makes an insert/update sent under
    /// the WRONG account's currently-relayed token fail closed instead of
    /// silently landing under whichever account happens to be active at
    /// request time — defense-in-depth behind the client-side
    /// `shouldDrain`/`ownerUserId` guards, which only decide whether a
    /// request is attempted at all, never which account the resulting row
    /// actually belongs to.
    var userId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, date, type, rpe, note, phase
        case rpeConfirmed = "rpe_confirmed"
        case typeLabel = "type_label"
        case durationMin = "duration_min"
        case groupId = "group_id"
        case workoutSource = "workout_source"
        case userId = "user_id"
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
    /// #529 F6 — see `SessionInsert.userId`'s doc comment for the full
    /// rationale; same stamp, same `climb_workouts` RLS shape.
    var userId: UUID? = nil

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
        case userId = "user_id"
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
    /// #529 F1/F6 — see `SessionInsert.userId`'s doc comment. This is the
    /// row the mid-workout SL-90 flush writes with no client-side account
    /// guard of its own (`WorkoutManager.flushPartial()`), so the stamp here
    /// is the last line of defense if the active account changes during the
    /// network round trip, after that guard already passed.
    var userId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, raw
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case elevationGainM = "elevation_gain_m"
        case attemptsDetected = "attempts_detected"
        case attemptsConfirmed = "attempts_confirmed"
        case userId = "user_id"
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
    /// #529 F6 — see `SessionInsert.userId`'s doc comment. Same stamp, same
    /// `climb_attempts` RLS shape.
    var userId: UUID? = nil

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
        case userId = "user_id"
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
    var peakKg: Double?
    var avgKg: Double?
    var sampleCount: Int
    var note: String
    var tag: String
    var side: String           // "", "left", "right", "both"
    var groupId: UUID?         // gauge session
    var samples: [[Double]]

    // Guided-protocol provenance. Optional defaults preserve old free-hold
    // queue files; guided constructors fill every applicable database field.
    var protocolRunId: UUID? = nil
    var setNo: Int? = nil
    var repNo: Int? = nil
    var zone: String? = nil
    var source: String? = nil
    var outcome: String? = nil
    var plannedDurationMs: Int? = nil
    var actualDurationMs: Int? = nil
    var protocolMode: String? = nil
    var targetKg: Double? = nil
    var targetLowKg: Double? = nil
    var targetHighKg: Double? = nil
    var cadenceOutS: Double? = nil
    var cadenceReturnS: Double? = nil
    var cadenceMarkers: [WatchCadenceMarker]? = nil
    var setMetrics: MovementSetMetrics? = nil
    var setupNote: String? = nil
    var capacityEvidence: Bool? = nil
    var completedReps: Int? = nil
    var completionStatus: String? = nil
    /// #529 slice 2 — see `SessionInsert.userId`'s doc comment for the full
    /// rationale; same row-level defense-in-depth, same `tindeq_recordings`
    /// RLS shape. Stamped by `TindeqManager.persistPreparedRecording` from
    /// whichever owner (`persistenceOwnerUserId` for a guided run,
    /// `manualSessionOwnerUserId` for manual/hands-free) governs the save.
    var userId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, note, samples, tag, side, zone, source, outcome
        case durationMs = "duration_ms"
        case peakKg = "peak_kg"
        case avgKg = "avg_kg"
        case sampleCount = "sample_count"
        case groupId = "group_id"
        case protocolRunId = "protocol_run_id"
        case setNo = "set_no"
        case repNo = "rep_no"
        case plannedDurationMs = "planned_duration_ms"
        case actualDurationMs = "actual_duration_ms"
        case protocolMode = "protocol_mode"
        case targetKg = "target_kg"
        case targetLowKg = "target_low_kg"
        case targetHighKg = "target_high_kg"
        case cadenceOutS = "cadence_out_s"
        case cadenceReturnS = "cadence_return_s"
        case cadenceMarkers = "cadence_markers"
        case setMetrics = "set_metrics"
        case setupNote = "setup_note"
        case capacityEvidence = "capacity_evidence"
        case completedReps = "completed_reps"
        case completionStatus = "completion_status"
        case userId = "user_id"
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
    ///
    /// Deliberately has NO default (#529 slice 2, mirrors
    /// `WorkoutSaveBundle.enqueuedUserId`): every production constructor
    /// (`TindeqManager.persistPreparedRecording`) must pass this explicitly
    /// — captured at measurement start, not re-derived at save time — so a
    /// future call site cannot forget to stamp an owner and silently fall
    /// back to `UploadQueueEngine.enqueue`'s nil→current-user stamp, which
    /// is reserved for genuinely legacy on-disk files. `nil` remains a legal
    /// VALUE here (a legacy file, or a recording made while nobody was
    /// signed in); see `shouldDrain`.
    var enqueuedUserId: UUID?
}

nonisolated struct TindeqTagRow: Codable {
    var tag: String
}

/// A row of the `tindeq_tags` registry (SL-92): the hidden flag SL-94 filters
/// on, the force-curve params the phone banks there (#280) so the watch can
/// predict a session's RPE from W' depletion, and the per-exercise
/// side-applicability mode (#543 slice 3). Both curve columns are null until
/// that tag has enough long holds for the phone to fit a curve; `side_mode` is
/// NOT NULL with a default, but a legacy/unconfigured row that predates it
/// decodes as the default (`unilateral_or_bilateral`) via `init(from:)`.
nonisolated struct TagRegistryRow: Codable {
    var name: String
    var hidden: Bool
    var cfKg: Double?
    var wPrimeKgs: Double?
    var sideMode: String

    enum CodingKeys: String, CodingKey {
        case name, hidden
        case cfKg = "cf_kg"
        case wPrimeKgs = "w_prime_kgs"
        case sideMode = "side_mode"
    }

    init(
        name: String,
        hidden: Bool,
        cfKg: Double?,
        wPrimeKgs: Double?,
        sideMode: String = ForceSideMode.defaultMode.rawValue
    ) {
        self.name = name
        self.hidden = hidden
        self.cfKg = cfKg
        self.wPrimeKgs = wPrimeKgs
        self.sideMode = sideMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        hidden = try values.decode(Bool.self, forKey: .hidden)
        cfKg = try values.decodeIfPresent(Double.self, forKey: .cfKg)
        wPrimeKgs = try values.decodeIfPresent(Double.self, forKey: .wPrimeKgs)
        sideMode = try values.decodeIfPresent(String.self, forKey: .sideMode)
            ?? ForceSideMode.defaultMode.rawValue
    }
}

/// A visible tag as the Force screen needs it: the name for the picker, its
/// persisted curve for the #280 RPE prediction (nil until fitted), and its
/// side-applicability mode (#543). `sideMode` defaults so legacy constructions
/// (which predate the field) keep compiling.
nonisolated struct TindeqTagInfo: Sendable, Equatable {
    var name: String
    var cf: Double?
    var wPrime: Double?
    var sideMode: ForceSideMode

    init(
        name: String,
        cf: Double?,
        wPrime: Double?,
        sideMode: ForceSideMode = ForceSideMode.defaultMode
    ) {
        self.name = name
        self.cf = cf
        self.wPrime = wPrime
        self.sideMode = sideMode
    }
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
    /// Legacy terminal-retry rows may have no known owner. They remain
    /// separately visible as unscoped and are never drained under whichever
    /// account happens to be signed in.
    var userId: UUID? = nil
    var workoutId: UUID
    /// #521: both transport paths use the workout id as their run identity.
    /// Kept as a distinct field so the wire contract is explicit and can
    /// evolve independently of the database primary key.
    var runId: UUID
    /// Strictly increasing within runId. Gaps are valid when a telemetry beat
    /// is coalesced before transport.
    var sequence: Int = 1
    var event: String = "telemetry"
    var terminal: Bool = false
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
        case status, hr, climbing, sequence, event, terminal
        case userId = "user_id"
        case workoutId = "workout_id"
        case runId = "run_id"
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
        try container.encode(runId, forKey: .runId)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(event, forKey: .event)
        try container.encode(terminal, forKey: .terminal)
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
    /// The account that owned the run when `WorkoutManager.start()` accepted
    /// it (issue #529) — captured once, immutably, and carried through
    /// end/retry/offline-queue untouched, exactly like
    /// `GuidedForceRunner.ownerUserId`. Checked by `drain()`/`pendingCount()`
    /// (`shouldDrain`) so a bundle built under one account can't silently
    /// upload under whichever account happens to be signed in when the queue
    /// next drains or when the run is later ended.
    ///
    /// Deliberately has NO default: every *production* constructor
    /// (`Repo.makeSaveBundle`) must pass this explicitly, so a future call
    /// site cannot forget to stamp an owner and silently fall back to
    /// `UploadQueueEngine.enqueue`'s nil→current-user stamp — that fallback
    /// is reserved for genuinely legacy on-disk files written before this
    /// field existed. `nil` remains a legal value here (an unattributed
    /// legacy file, or a run that started while nobody was signed in); see
    /// `shouldDrain`.
    var enqueuedUserId: UUID?
}

/// Why a bundle was quarantined (#475 F3) — `QuarantineReason` now lives in
/// SendLogWatchCore (UploadErrorPolicy.swift), where the per-case copy and
/// retry decisions that differ between the two cases are unit-tested on
/// Linux; the on-disk raw values are part of the quarantine record's wire
/// shape and are pinned there by a decode-compat test.

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
/// Never read back into a normal drain pass. Nothing may DELETE a
/// `.quarantine` file outright (the data-loss rule, #273 — only user sign-out
/// may do that) — but two paths may TRANSFORM a `.stuckRetrying` record back
/// into a pending `<uuid>.json`, item preserved: the F12 backoff resurrection
/// (`UploadQueueEngine.resurrectDueStuckRetries`) and, since #600, the
/// user's manual "Retry stuck uploads" (`retryQuarantinedItems`). The watch
/// has no sign-out queue purge equivalent to the web's
/// `discardQueueOnUserSignOut`, so everything else is effectively permanent
/// on-device storage. Quarantine
/// is expected to be rare, but `bundle.workout.raw` is the 1Hz debug trace
/// (hundreds of KB for a long workout when `keepRawTrace` is on), so this was
/// unbounded growth in the pathological case, not a fixed-size record (#475
/// F8) — #481's named cheap win, pruning `raw` before quarantining, is now
/// done: see `UploadQueueEngine.stripsPayloadOnQuarantine` / `QueueUploadItem
/// .strippedOfHeavyPayload()` (#491), which generalized this workout-specific
/// type into `QueueQuarantineRecord<Item>`. `QuarantinedUpload` itself is
/// legacy now — kept only so tests can prove the new on-disk shape stays
/// byte-compatible with records quarantined by an older build. A purge path
/// (actually deleting an old `.quarantine` file, not just shrinking it) is
/// still unimplemented and would need real design, not a one-liner.
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
