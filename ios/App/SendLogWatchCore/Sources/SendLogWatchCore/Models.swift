import Foundation

// MARK: - Detection domain

public struct MotionSample: Sendable {
    public let t: TimeInterval        // seconds since workout start
    public let altitude: Double       // relative altitude (m)
    public let motionRMS: Double      // |userAcceleration| RMS over trailing window (g)
    public let hr: Double?            // bpm, may lag

    public init(t: TimeInterval, altitude: Double, motionRMS: Double, hr: Double?) {
        self.t = t
        self.altitude = altitude
        self.motionRMS = motionRMS
        self.hr = hr
    }
}

/// Stable, multi-reader view of the detector. Callers compare snapshots before
/// and after ingesting a sample; no consumable transition event can be lost.
public struct AttemptDetectorSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case resting
        case autoClimbing
        case manualClimbing
    }

    public let state: State
    public let phaseStartedAt: Date?
    /// Non-negative height above the attempt's recent local resting floor.
    public let localHeightM: Double

    public init(state: State, phaseStartedAt: Date?, localHeightM: Double) {
        self.state = state
        self.phaseStartedAt = phaseStartedAt
        self.localHeightM = localHeightM
    }

    public var isClimbing: Bool { state != .resting }
    public var isManual: Bool { state == .manualClimbing }
}

public enum AttemptSource: String, Codable, Sendable {
    case auto    // altimeter/motion state machine
    case manual  // logged via the Boulder/Stop button
}

public struct Attempt: Sendable {
    public let startedAt: Date
    public let durationS: Double
    public let elevationGainM: Double
    public let avgHR: Double?
    public let peakHR: Double?
    public let motionIntensity: Double
    public let effortScore: Double
    public let source: AttemptSource
    /// #473: true when this attempt closed by hitting a duration cap
    /// (`maxAttemptS`, `unestablishedMaxS` or `establishedDriftMaxS`) rather
    /// than a genuine end signal (returned-to-floor or the HR+quiet
    /// fallback). Hitting a cap always means detection was wrong about
    /// something — surfaced here rather than silently clamped, so a caller
    /// can report/log it instead of it reading as an ordinary attempt.
    public let hitCap: Bool

    public init(
        startedAt: Date,
        durationS: Double,
        elevationGainM: Double,
        avgHR: Double?,
        peakHR: Double?,
        motionIntensity: Double,
        effortScore: Double,
        source: AttemptSource,
        hitCap: Bool = false
    ) {
        self.startedAt = startedAt
        self.durationS = durationS
        self.elevationGainM = elevationGainM
        self.avgHR = avgHR
        self.peakHR = peakHR
        self.motionIntensity = motionIntensity
        self.effortScore = effortScore
        self.source = source
        self.hitCap = hitCap
    }
}

// MARK: - Database rows (snake_case matches PostgREST)

public nonisolated struct SessionLoadRow: Codable {
    public var date: String
    public var load: Int?

    public init(date: String, load: Int?) {
        self.date = date
        self.load = load
    }
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
public nonisolated struct PendingTindeqSession: Codable, Sendable {
    public var id: UUID
    public var date: String           // YYYY-MM-DD, captured at enqueue time
    public var durationMin: Int
    public var rpe: Double
    /// #114's column, for the session row this becomes. `false` for the #280
    /// W'-depletion prediction the watch now logs without asking (or its
    /// fallback) — nobody reviewed that number. `nil` ONLY for legacy on-disk
    /// items enqueued by a build whose finish sheet still asked the user for
    /// an RPE: those were typed by a human, so a drain reads nil as confirmed.
    public var rpeConfirmed: Bool?
    public var note: String
    public var groupId: UUID          // Tindeq gauge session link — must survive the upload
    /// Which account was signed in when this session was persisted to disk
    /// (issue #158), checked by `drain()` so a session queued under one
    /// account can't silently upload under whichever account happens to be
    /// signed in when the queue next drains — see `shouldDrain`. Stamped by
    /// `TindeqManager` on the same synchronous MainActor turn `build(...)`
    /// runs on (#529 slice 2 — the immutable owner captured at the session's
    /// first rep, held fixed through a later account transition), not read
    /// lazily afterward.
    ///
    /// Deliberately has NO default on the memberwise init (#529 slice 2,
    /// mirrors `WorkoutSaveBundle.enqueuedUserId` / `PendingTindeqRecording
    /// .enqueuedUserId`): every production constructor must pass this
    /// explicitly, so a future call site cannot forget to stamp an owner and
    /// silently fall back to `UploadQueueEngine.enqueue`'s nil→current-user
    /// stamp, which is reserved for genuinely legacy on-disk files. `nil`
    /// remains a legal VALUE here (a legacy file, or a session logged while
    /// nobody was signed in).
    public var enqueuedUserId: UUID?

    public init(
        id: UUID,
        date: String,
        durationMin: Int,
        rpe: Double,
        rpeConfirmed: Bool? = nil,
        note: String,
        groupId: UUID,
        enqueuedUserId: UUID?
    ) {
        self.id = id
        self.date = date
        self.durationMin = durationMin
        self.rpe = rpe
        self.rpeConfirmed = rpeConfirmed
        self.note = note
        self.groupId = groupId
        self.enqueuedUserId = enqueuedUserId
    }

    /// Builds the "Log Session" payload as a pure function, so
    /// SendLogWatchTests can exercise it without a live TindeqManager/View.
    /// `now` defaults to the real clock but is injectable for tests.
    /// Duration is clamped to 1-600 min, matching `SessionInsert`/
    /// `WorkoutSaveBundle`'s bound (the DB's date-sanity constraints assume
    /// it); `date` is the session's START day, matching the convention
    /// `Repo.makeSaveBundle` uses for workouts (`summary.startedAt`), not the
    /// moment it happened to be logged.
    /// `rpeConfirmed` defaults to false because since #280 the watch never
    /// asks: every session it logs carries a predicted (or fallback) RPE.
    /// `enqueuedUserId` has no default (#529 slice 2) — the caller must pass
    /// the account this session's ownership was captured under, not leave it
    /// to a later post-hoc assignment a future call site could forget.
    public static func build(
        sessionStartedAt: Date?,
        now: Date = Date(),
        recordingCount: Int,
        rpe: Double,
        rpeConfirmed: Bool = false,
        groupId: UUID,
        enqueuedUserId: UUID?
    ) -> PendingTindeqSession {
        let started = sessionStartedAt ?? now
        let rawMinutes = Int((now.timeIntervalSince(started) / 60).rounded())
        let note = "\(recordingCount) recording\(recordingCount == 1 ? "" : "s")"
        return PendingTindeqSession(
            id: UUID(),
            date: started.localDateString,
            durationMin: max(1, min(600, rawMinutes)),
            rpe: rpe,
            rpeConfirmed: rpeConfirmed,
            note: note,
            groupId: groupId,
            enqueuedUserId: enqueuedUserId
        )
    }
}

extension Calendar {
    /// Always Gregorian, regardless of the device's Region/Calendar setting.
    /// A Thai Region, for example, defaults to the Buddhist calendar
    /// (Gregorian year + 543) — `Calendar.current` silently follows that,
    /// which corrupted every date the watch wrote. Every date computed for
    /// storage or comparison against the database must go through this.
    public static var gregorianLocal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }
}

extension Date {
    /// Local calendar date as YYYY-MM-DD (mirrors web src/lib/dates.ts).
    /// Forces the Gregorian calendar AND en_US_POSIX locale so the year is
    /// always AD, never a locale-specific era — see Calendar.gregorianLocal.
    public var localDateString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}
