import Foundation

// MARK: - Issue #475 — upload error taxonomy

/// Which of `uploadBundle`'s three sequential upserts an error came from.
/// Order is fixed by FK dependency — `climb_attempts.workout_id` and
/// `climb_workouts.session_id` are both non-null references, so
/// sessions → climb_workouts → climb_attempts is the only legal order (see
/// the #475 correction comment) — this only labels where the sequence
/// stopped, for quarantine reporting; it never changes the sequence itself.
public enum UploadStage: String, Sendable, Codable, CaseIterable {
    case session
    case climbWorkout
    case climbAttempts
}

/// What `OfflineQueue`'s drain loop should do with a failed upload.
public enum UploadErrorOutcome: Sendable, Equatable {
    /// Transient (network / timeout / 5xx / 408 / 429) or ambiguous (403 —
    /// could be stale auth or RLS; 409 — could be an ordering conflict, not
    /// poison): stop this drain pass and retry the whole bundle next time.
    case retry
    /// 401 — the relayed access token is stale. Kept distinct from `.retry`
    /// so a future build can request a fresh relay instead of just spinning;
    /// today it behaves the same as `.retry` (stop, try again next drain).
    case needsAuthRelay
    /// The bundle itself violates a DB constraint that no retry will fix.
    /// Take it off the drain path but keep it on disk, reported truthfully —
    /// never delete it (that stays reserved for user sign-out, #273).
    case quarantine
}

/// The minimal shape of an upload failure the classifier needs, independent
/// of any specific HTTP/Postgrest error type — keeps this file (and its
/// classifier) Foundation-networking-free and testable on Linux.
public struct UploadFailure: Sendable, Equatable {
    /// The HTTP status code, when the failure surfaced as one (some
    /// transport-layer failures — a timeout, a dropped connection — never
    /// get one).
    public var httpStatus: Int?
    /// PostgREST's decoded error `code` field: a Postgres SQLSTATE for a
    /// DB-level rejection (e.g. "23514" = check_violation), or a
    /// PostgREST-specific code (e.g. "PGRST301") for its own errors.
    /// PostgREST surfaces DB errors by SQLSTATE, not a clean HTTP status
    /// bucket — this is why classification keys off `code`, not only
    /// `httpStatus`.
    public var postgrestCode: String?
    /// PostgREST's decoded error `message` — for a check_violation this
    /// names the constraint, which is the only way to tell "the one check
    /// this PR exists to catch" apart from any other check on the table.
    public var message: String?

    public init(httpStatus: Int? = nil, postgrestCode: String? = nil, message: String? = nil) {
        self.httpStatus = httpStatus
        self.postgrestCode = postgrestCode
        self.message = message
    }
}

/// Classifies an upload failure into a drain-loop action. Deliberately
/// conservative: quarantine is reserved for the ONE named check-constraint
/// violation, and anything this function doesn't specifically recognize —
/// including 403/409, which are ambiguous rather than safely permanent —
/// defaults to `.retry`. A blanket "4xx is permanent" rule would quarantine
/// recoverable work (stale auth, a real RLS edge case, an ordering
/// conflict); see the #475 correction comment.
public enum UploadErrorClassifier {
    /// SQLSTATE class 23 (integrity constraint violation) → check_violation.
    private static let checkViolationSQLState = "23514"
    /// Postgres's default name for an unnamed inline check constraint is
    /// `<table>_<column>_check`. `climb_attempts` has exactly one check
    /// constraint (`duration_s > 0`), so this is the only name it can have —
    /// verified against
    /// `supabase/migrations/20260711120000_watch_workouts.sql`.
    private static let durationCheckConstraintName = "climb_attempts_duration_s_check"

    public static func classify(_ failure: UploadFailure) -> UploadErrorOutcome {
        if failure.httpStatus == 401 { return .needsAuthRelay }
        if failure.postgrestCode == checkViolationSQLState,
           let message = failure.message,
           message.contains(durationCheckConstraintName) {
            return .quarantine
        }
        return .retry
    }
}
