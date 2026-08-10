import Foundation
import OSLog
import SendLogWatchCore
import Supabase

// MARK: - Issue #531 — durable retry for a failed terminal live_workouts upsert

/// The seam `LiveWorkoutSync` hands a terminal row to once its own upsert
/// attempt fails. A protocol (not a concrete type) so `LiveWorkoutSync`'s
/// tests can inject a recording double instead of touching the filesystem or
/// `LiveWorkoutTerminalRetry.shared`.
protocol LiveWorkoutTerminalRetrying: Sendable {
    func handOff(_ row: LiveWorkoutUpsert, error: Error) async
}

/// Durable fallback for a live_workouts terminal (End) row whose upsert
/// failed. `LiveWorkoutSync` is a per-workout actor that `WorkoutManager.end()`
/// drops (`liveSync = nil`) right after `markEnded()` returns — and once
/// `terminalQueued` is set, `beat()`/`markEnded()` both refuse every later
/// sequence, so no future beat will ever arrive to carry a replacement.
/// Without a durable owner, a failed terminal write is gone the moment that
/// actor is deallocated, leaving the server-side row `status='live'` forever
/// (#531).
///
/// This actor is that owner: a single failed row, persisted to disk the
/// moment it's handed off (so it survives the app being killed and
/// relaunched, not just backgrounded), and retried on launch / foreground /
/// an accepted auth relay / the #472b bounded backoff — the same triggers
/// `OfflineQueue` and friends already use, reusing their seams
/// (`SessionRelayRequesting`, `DrainScheduling`, `QueueRetrySchedule`,
/// `UploadFailureMapping.classify(_:)`, `CoalescingDrain`,
/// `shouldDrain(itemUserId:currentUserId:)`) rather than inventing a second
/// policy.
///
/// A retry is a blind resend of the exact same typed row (run_id/sequence/
/// event/terminal). That's safe and idempotent by construction, not by
/// anything this actor tracks: `guard_live_workout_order()`
/// (supabase/migrations/20260809090000_live_mirror_ordering.sql,
/// 20260809130000_live_mirror_legacy_upsert.sql) rejects the retry as a
/// no-op whenever it would either reopen a run a newer one has superseded
/// (compared by `started_at`) or replay a sequence the server already has
/// (`new.sequence <= old.sequence`) — including the case where the ORIGINAL
/// request actually landed and only its response was lost. This actor never
/// needs to distinguish those cases; it just keeps offering the same row
/// until an attempt succeeds.
///
/// #531 review (this repo's #1 recurring defect class — a decision made from
/// state captured before an `await`): a NEWER hand-off can arrive and
/// overwrite the on-disk row while an OLDER attempt is still suspended
/// inside `upload`. Two things follow, and both are handled by
/// `drainPass()`/`retryNow()` together, not by a single in-flight guard:
/// 1. The older attempt must not blindly delete whatever is on disk when it
///    finishes — it may no longer be the row it sent. `clearPersistedIfMatches`
///    re-reads and compares identity before deleting.
/// 2. The newer hand-off, finding an attempt already in flight, must not
///    just give up — nothing else would ever come back for it (no more
///    beats, no `pending` in `LiveWorkoutSync`, and `WorkoutManager` already
///    dropped that actor). `CoalescingDrain` is what turns "an attempt was
///    requested while one was already running" into a guaranteed rerun of
///    the pass once the current one completes, so the newer row on disk gets
///    its own attempt with no missed wake-up — even when the in-flight one
///    SUCCEEDED, which would otherwise reset `consecutiveFailures` and skip
///    scheduling backoff entirely.
actor LiveWorkoutTerminalRetry: LiveWorkoutTerminalRetrying {
    static let shared = LiveWorkoutTerminalRetry()

    private static let log = Logger(
        subsystem: "com.jirathip.sendlog.watchkitapp", category: "liveWorkoutRetry"
    )

    private let upload: @Sendable (LiveWorkoutUpsert) async throws -> Void
    private let baseDir: URL
    private let fileName: String
    private let sessionRelay: SessionRelayRequesting
    private let scheduler: DrainScheduling
    private let fileIO: QueueFileIO
    /// The relayed session's `sub` claim (#265), same source
    /// `LiveWorkoutSync.resolveUserId()` reads — injected so tests can
    /// script an account without touching the real `WatchSessionStore`
    /// singleton.
    private let currentUserId: @Sendable () -> UUID?

    /// Consecutive failed retry attempts since the last success — feeds
    /// `QueueRetrySchedule.delay`, same growth/reset rule as #472b.
    private var consecutiveFailures = 0
    /// At most one backoff timer armed at a time, same rationale as
    /// `UploadQueueEngine.backoffScheduled`.
    private var backoffScheduled = false
    /// Coalesces overlapping retry triggers (foreground + relay + a fired
    /// backoff, or a newer hand-off arriving mid-attempt) into a rerun of
    /// `drainPass()` once the current one finishes — see the type doc for
    /// why a bare in-flight guard is not sufficient here.
    private var drainState = CoalescingDrain()

    init(
        upload: @escaping @Sendable (LiveWorkoutUpsert) async throws -> Void = { row in
            try await SupabaseService
                .from("live_workouts")
                .upsert(row, onConflict: "user_id")
                .execute()
        },
        baseDir: URL? = nil,
        fileName: String = "live-workout-terminal-retry.json",
        sessionRelay: SessionRelayRequesting = AuthManagerRelayRequester(),
        scheduler: DrainScheduling = TaskDrainScheduler(),
        fileIO: QueueFileIO = RealQueueFileIO(),
        currentUserId: @escaping @Sendable () -> UUID? = { WatchSessionStore.shared.userId }
    ) {
        self.upload = upload
        self.baseDir = baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileName = fileName
        self.sessionRelay = sessionRelay
        self.scheduler = scheduler
        self.fileIO = fileIO
        self.currentUserId = currentUserId
    }

    private var fileURL: URL { baseDir.appendingPathComponent(fileName) }

    /// Persist the failed terminal row durably and report it once to
    /// monitoring (#531: no `try?` may discard this failure silently), then
    /// attempt it — the common case (a transient blip) recovers with no
    /// further trigger needed.
    ///
    /// If the disk write itself fails (quota, storage disabled), there is
    /// nothing durable for `drainPass()` to re-read, so the coalescing loop
    /// would find nothing and silently do nothing. This is the one path that
    /// falls back to a single direct, in-memory attempt instead — if that
    /// also fails, the row is genuinely unrecoverable (no copy survives this
    /// call), and that is reported loudly rather than swallowed.
    func handOff(_ row: LiveWorkoutUpsert, error: Error) async {
        let persisted = persist(row)
        Self.log.error(
            "terminal live_workouts upsert failed, queued for durable retry (persisted to disk: \(persisted, privacy: .public), run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
        )
        guard persisted else {
            await attemptUnpersistable(row)
            return
        }
        await retryNow()
    }

    /// Attempt whatever row is currently persisted, if any, re-checking it
    /// fresh on every pass. Safe to call with nothing queued (no-op) and safe
    /// to call from multiple triggers at once — `drainState` coalesces
    /// overlapping calls into a guaranteed rerun rather than dropping them.
    func retryNow() async {
        guard drainState.request() == .start else { return }
        var stalled = false
        repeat {
            stalled = await drainPass()
        } while drainState.completePass() == .rerun
        if stalled {
            scheduleBackoffRetry()
        } else {
            consecutiveFailures = 0
        }
    }

    /// Whether a row is currently waiting on a retry FOR THE SIGNED-IN
    /// ACCOUNT — test/diagnostic seam. A row stamped for a different account
    /// reads as absent, the same "treated as if it weren't there" rule
    /// `UploadQueueEngine.lastSuccessfulSyncAt()` applies to its own
    /// single-file marker (#158/#475-F4): it is not this account's business,
    /// even though the file itself is still on disk, kept for whenever that
    /// account is signed in again.
    func hasPendingRetry() -> Bool {
        guard let row = readPersisted() else { return false }
        return shouldDrain(itemUserId: row.userId, currentUserId: currentUserId())
    }

    /// One pass: re-reads whatever is currently on disk — never a row
    /// captured before this call — so a hand-off that replaced it while the
    /// previous pass's `upload` was suspended is exactly what this pass (or
    /// the coalesced rerun after it) sends next.
    private func drainPass() async -> Bool {
        guard let row = readPersisted() else { return false }
        // #158/#475-F4: re-read the signed-in account fresh on every pass,
        // not once before the loop — a concurrent account switch must not go
        // unnoticed for the rest of this call. A mismatch (or nobody signed
        // in) is not a network/auth error: leave the row on disk untouched
        // and don't stall — it becomes eligible again the moment its own
        // account's relay lands (`AuthManager` calls `retryNow()` on every
        // accepted relay).
        guard shouldDrain(itemUserId: row.userId, currentUserId: currentUserId()) else {
            return false
        }
        do {
            try await upload(row)
            // #531 review finding 1: compare-and-clear, not a blind clear —
            // a newer hand-off can have overwritten this file while `upload`
            // was suspended. Deleting unconditionally here would destroy
            // that newer row; the coalescing rerun this pass's caller is
            // about to run (or has already queued) is what actually sends it.
            clearPersistedIfMatches(row)
            if consecutiveFailures > 0 {
                Self.log.info(
                    "terminal live_workouts retry landed (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)) after \(self.consecutiveFailures) failed attempt(s)"
                )
            }
            return false
        } catch {
            consecutiveFailures += 1
            Self.log.error(
                "terminal live_workouts retry failed (attempt \(self.consecutiveFailures), run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
            )
            let classification = UploadFailureMapping.classify(error)
            if classification.outcome == .needsAuthRelay {
                await sessionRelay.requestSessionRelay()
            }
            return true
        }
    }

    /// The disk-write-failure fallback: one direct attempt from the in-memory
    /// row, since there is no durable copy for `drainPass()` to find.
    private func attemptUnpersistable(_ row: LiveWorkoutUpsert) async {
        guard shouldDrain(itemUserId: row.userId, currentUserId: currentUserId()) else { return }
        do {
            try await upload(row)
        } catch {
            Self.log.fault(
                "terminal live_workouts row could not be persisted to disk AND its direct retry failed — this write is now unrecoverable (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func scheduleBackoffRetry() {
        guard !backoffScheduled else { return }
        backoffScheduled = true
        let delay = QueueRetrySchedule.delay(forConsecutiveStalls: consecutiveFailures)
        scheduler.scheduleRetry(after: delay, RetryAction { [self] in
            await self.retryAfterBackoff()
        })
    }

    private func retryAfterBackoff() async {
        backoffScheduled = false
        await retryNow()
    }

    @discardableResult
    private func persist(_ row: LiveWorkoutUpsert) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(row) else { return false }
        do {
            try fileIO.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    private func readPersisted() -> LiveWorkoutUpsert? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveWorkoutUpsert.self, from: data)
    }

    /// Delete the persisted row only if it is still the exact row just
    /// uploaded (same run + sequence) — see the type doc's finding-1 note.
    private func clearPersistedIfMatches(_ row: LiveWorkoutUpsert) {
        guard let current = readPersisted() else { return }
        guard current.runId == row.runId, current.sequence == row.sequence else { return }
        try? fileIO.removeItem(at: fileURL)
    }
}
