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
/// `UploadFailureMapping.classify(_:)`) rather than inventing a second
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

    /// Consecutive failed retry attempts since the last success — feeds
    /// `QueueRetrySchedule.delay`, same growth/reset rule as #472b.
    private var consecutiveFailures = 0
    /// At most one backoff timer armed at a time, same rationale as
    /// `UploadQueueEngine.backoffScheduled`.
    private var backoffScheduled = false
    /// Guards `retryNow()` against overlapping callers (foreground + relay +
    /// a fired backoff landing at once) issuing a second concurrent upsert
    /// for the same row.
    private var retrying = false

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
        fileIO: QueueFileIO = RealQueueFileIO()
    ) {
        self.upload = upload
        self.baseDir = baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileName = fileName
        self.sessionRelay = sessionRelay
        self.scheduler = scheduler
        self.fileIO = fileIO
    }

    private var fileURL: URL { baseDir.appendingPathComponent(fileName) }

    /// Persist the failed terminal row durably and report it once to
    /// monitoring (#531: no `try?` may discard this failure silently), then
    /// attempt it immediately — the common case (a transient blip) recovers
    /// with no further trigger needed. The immediate attempt runs from the
    /// row handed in, not a re-read off disk: a disk write can itself fail
    /// (quota, storage disabled), and that must not ALSO cancel the one
    /// in-memory attempt this call was already going to make.
    func handOff(_ row: LiveWorkoutUpsert, error: Error) async {
        let persisted = persist(row)
        Self.log.error(
            "terminal live_workouts upsert failed, queued for durable retry (persisted to disk: \(persisted, privacy: .public), run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
        )
        await attempt(row)
    }

    /// Attempt whatever row is currently persisted, if any. Safe to call
    /// with nothing queued (no-op) and safe to call from multiple triggers
    /// at once (`retrying` coalesces to a single in-flight attempt).
    func retryNow() async {
        guard let row = readPersisted() else { return }
        await attempt(row)
    }

    /// Whether a row is currently waiting on a retry — test/diagnostic seam.
    func hasPendingRetry() -> Bool { readPersisted() != nil }

    private func attempt(_ row: LiveWorkoutUpsert) async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
        do {
            try await upload(row)
            clearPersisted()
            if consecutiveFailures > 0 {
                Self.log.info(
                    "terminal live_workouts retry landed (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)) after \(self.consecutiveFailures) failed attempt(s)"
                )
            }
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            Self.log.error(
                "terminal live_workouts retry failed (attempt \(self.consecutiveFailures), run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
            )
            let classification = UploadFailureMapping.classify(error)
            if classification.outcome == .needsAuthRelay {
                await sessionRelay.requestSessionRelay()
            }
            scheduleBackoffRetry()
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

    private func clearPersisted() {
        try? fileIO.removeItem(at: fileURL)
    }
}
