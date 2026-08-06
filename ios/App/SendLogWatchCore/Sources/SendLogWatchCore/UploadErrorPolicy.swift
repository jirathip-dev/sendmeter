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
    /// 401, or PostgREST's own JWT-rejection codes (PGRST301/302) — the
    /// relayed access token is stale. Kept distinct from `.retry` so a
    /// future build can request a fresh relay instead of just spinning;
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
    /// get one; a decoded `PostgrestError`, including a 401, never carries
    /// one either — see `UploadErrorClassifier`'s auth codes).
    public var httpStatus: Int?
    /// PostgREST's decoded error `code` field: a Postgres SQLSTATE for a
    /// DB-level rejection (e.g. "23514" = check_violation), or a
    /// PostgREST-specific code (e.g. "PGRST301") for its own errors.
    /// PostgREST surfaces DB errors by SQLSTATE, not a clean HTTP status
    /// bucket — this is why classification keys off `code`, not only
    /// `httpStatus`.
    public var postgrestCode: String?
    /// PostgREST's decoded error `message` — kept for auditing/reporting in
    /// the quarantine record, but NOT used to decide `.quarantine` (see the
    /// classifier's doc comment for why).
    public var message: String?

    public init(httpStatus: Int? = nil, postgrestCode: String? = nil, message: String? = nil) {
        self.httpStatus = httpStatus
        self.postgrestCode = postgrestCode
        self.message = message
    }
}

/// Classifies an upload failure into a drain-loop action.
///
/// **Quarantine does not trust the server's constraint-NAME string.** An
/// earlier version of this classifier matched the error `message` against
/// the literal `"climb_attempts_duration_s_check"`, justified by a comment
/// claiming `climb_attempts` has exactly one check constraint. Review found
/// that claim false — the table has two
/// (`climb_attempts_source_check`, added by
/// `supabase/migrations/20260716000000_workout_tab.sql`, is the other) — and
/// while the conclusion happened to survive (the two checks sit on different
/// columns), a future migration that adds a third check, or renames one, or
/// recreates the column (Postgres would then mint
/// `climb_attempts_duration_s_check1`), would silently stop quarantine from
/// ever firing again, with no test able to catch it — the original poison
/// bug back, unattributably.
///
/// Instead, quarantine requires three things that are each individually
/// necessary and — unlike the name string — jointly sufficient WITHOUT
/// reading the error message at all:
/// 1. SQLSTATE `23514` (check_violation) — cheap, stable, documented
///    Postgres behavior, not a Postgres implementation detail like a
///    constraint's auto-generated name.
/// 2. The failing upload stage was `.climbAttempts` — narrows "some check
///    failed on some table" down to this table specifically.
/// 3. The REJECTED BUNDLE ITSELF still contains a non-positive-duration
///    attempt. This is exact, not a heuristic: `AttemptDetector` (this same
///    package) now guarantees `durationS > 0` for every attempt it emits —
///    so any bundle reaching this classifier with a non-positive-duration
///    attempt was queued by a pre-#475 build, and IS provably the poison
///    this PR exists to catch, regardless of what Postgres happens to call
///    the constraint that rejected it.
///
/// A same-stage, same-SQLSTATE failure on a bundle whose attempts are all
/// positive-duration (e.g. a hypothetical `climb_attempts_source_check`
/// violation) correctly falls through to `.retry` — (3) alone rules it out.
/// 403/409 stay ambiguous (stale auth/RLS, or an ordering conflict, not
/// necessarily poison) and default to `.retry` as before.
public enum UploadErrorClassifier {
    private static let checkViolationSQLState = "23514"
    /// PostgREST's own codes for an undecodable/expired JWT. Verified against
    /// this project's production PostgREST (#475 F2): a bad bearer token
    /// returns HTTP 401 with a body that decodes cleanly as a
    /// `PostgrestError` — `{"code":"PGRST301","message":"No suitable key or
    /// wrong key type",...}` — so it NEVER reaches this classifier as an
    /// `HTTPError` with `httpStatus == 401`; `postgrestCode` is the only
    /// signal that actually arrives for this case in production.
    private static let authErrorCodes: Set<String> = ["PGRST301", "PGRST302"]

    public static func classify(
        _ failure: UploadFailure,
        stage: UploadStage?,
        bundleHasNonPositiveDurationAttempt: Bool
    ) -> UploadErrorOutcome {
        if failure.httpStatus == 401 { return .needsAuthRelay }
        if let code = failure.postgrestCode, authErrorCodes.contains(code) { return .needsAuthRelay }
        if failure.postgrestCode == checkViolationSQLState,
           stage == .climbAttempts,
           bundleHasNonPositiveDurationAttempt {
            return .quarantine
        }
        return .retry
    }
}

// MARK: - Issue #475 F3 — bounded retry, so an UNRECOGNIZED permanent error can't park the queue forever either

/// What happened after another failed drain attempt at the same item.
public enum QueueRetryDecision: Sendable, Equatable {
    /// Keep retrying — stop this pass as usual, try again next drain.
    case retryLater(consecutiveFailures: Int)
    /// This item has failed too many consecutive times without the
    /// classifier ever recognizing why. Not provably permanent the way a
    /// `.quarantine` verdict is — but bounded, so an error this classifier
    /// doesn't (yet) recognize, or a persistently-invalid account, cannot
    /// park every other item behind it forever either.
    case stuck(consecutiveFailures: Int)
}

/// `UploadErrorClassifier.classify` only recognizes ONE specific permanent
/// rejection; every other error — a different check constraint (see the
/// `climb_workouts_check` example in the #475 review), a date-bounds
/// violation, anything not yet seen — falls through to `.retry`, which
/// `OfflineQueue.drainPass` stops the pass on. Oldest-first draining means
/// that item is retried FIRST on every subsequent pass, so an unrecognized
/// permanent error reproduces the exact poison-queue symptom this issue was
/// filed for. This is the backstop: after enough CONSECUTIVE failed passes
/// at the same item (tracked and persisted per-item so it survives
/// relaunch — see `OfflineQueue`'s retry ledger), give up treating it as
/// transient and quarantine it under a distinct reason
/// (`QuarantineReason.stuckRetrying`, not `.schemaRejection`) so it stops
/// blocking the rest of the queue.
///
/// Because the drain loop stops the WHOLE pass on the first `.retry`/
/// `.needsAuthRelay` failure (oldest-first), an item's counter only ever
/// advances on a pass where THAT item was actually reached and attempted —
/// every item ahead of it in that same pass necessarily already succeeded
/// (or the loop would have stopped on one of them first), so this counter
/// is already "consecutive failures with nothing else in front of it
/// succeeding in between" by construction; no separate bookkeeping for that
/// is needed.
public enum QueueRetryPolicy {
    /// Chosen to comfortably outlast any real transient outage (a bad
    /// network stretch, a maintenance window) while still bounding the
    /// wait: the watch drains on launch/foreground, so this is on the order
    /// of weeks of normal use, not minutes.
    public static let maxConsecutiveFailures = 20

    public static func afterFailedAttempt(previousConsecutiveFailures: Int) -> QueueRetryDecision {
        let failures = previousConsecutiveFailures + 1
        return failures >= maxConsecutiveFailures
            ? .stuck(consecutiveFailures: failures)
            : .retryLater(consecutiveFailures: failures)
    }
}
