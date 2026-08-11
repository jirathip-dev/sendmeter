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

/// Read seam for this actor's single persisted file, kept separate from
/// `UploadQueueEngine`'s `QueueFileIO` — that protocol's own doc deliberately
/// keeps reads off the injectable seam for the many-file directory queues
/// ("only mutations need scripting"). This actor's `readPersisted()` needs a
/// scriptable read too, so an undecodable/unreadable row can be exercised
/// from a test instead of only through the real filesystem (#549 finding 5).
protocol TerminalRetryFileIO: QueueFileIO {
    func read(from url: URL) throws -> Data
}

extension RealQueueFileIO: TerminalRetryFileIO {
    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// The #264 loss-report seam for this actor — same rationale as
/// `EvictionReporting` (`UploadQueueEngine.swift`): a protocol rather than
/// `Logger` output alone, because `Logger`/OSLog output isn't independently
/// observable from a unit test (see `WorkoutManagerHRMissingDateIntervalTests`'s
/// note), so without this seam the one behavioral delta a "reported, not
/// swallowed" fix makes is untestable (#549 F4) — and issue #549 itself named
/// "no monitoring surface beyond OSLog" as one of the seven residuals; only
/// the *pending* case got one (via `PendingSyncCache`) until this seam.
protocol TerminalLossReporting: Sendable {
    /// A row could not be persisted to disk AND the signed-in account no
    /// longer matches it — no durable copy exists anywhere, so this is a
    /// genuine, permanent loss (unlike `drainPass()`'s own mismatch arm,
    /// whose row stays safely on disk for its own account to retry later).
    func reportAccountMismatchLoss(runId: UUID, sequence: Int)
    /// A row could not be persisted to disk AND its one direct retry attempt
    /// also failed — genuine, permanent loss; nothing durable remains for
    /// any later trigger to retry.
    func reportUnrecoverableUploadFailure(runId: UUID, sequence: Int, error: Error)
    /// A persisted row failed to decode. NOT necessarily a permanent loss —
    /// #287: the file is retained, not deleted, so a later compatible build
    /// can still recover it — but worth surfacing since it silently occupies
    /// the queue slot in the meantime (#549 F5).
    func reportUndecodableRow(error: Error)
}

/// Production default: `Self.log.fault(...)` at each call site is already
/// the loud OSLog channel; this is a no-op until the watch target has a real
/// monitoring surface to wire up (unlike the web app, there's no
/// Sentry-equivalent here yet — see CLAUDE.md's `src/lib/monitoring.ts`
/// note). The seam exists now so a real reporter can be dropped in later
/// without touching call sites, and so it's independently testable today.
struct NoOpTerminalLossReporter: TerminalLossReporting {
    func reportAccountMismatchLoss(runId: UUID, sequence: Int) {}
    func reportUnrecoverableUploadFailure(runId: UUID, sequence: Int, error: Error) {}
    func reportUndecodableRow(error: Error) {}
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
///
/// #549 review of the above (this actor's disk-write-failure fallback):
/// `attemptUnpersistable` now requests the SAME `drainState` slot as
/// `drainPass()` before it uploads, so it can never run concurrently with an
/// in-flight pass — but unlike a persisted row, there is no durable copy for
/// a coalesced rerun to pick back up (`drainPass()` reads disk, which never
/// contained this row). A round-1 review of that fix (F1) caught the obvious
/// trap: simply skipping a coalesced request would DISCARD the row with zero
/// upload attempts ever made — strictly worse than the harmless idempotent
/// race it replaced (`guard_live_workout_order()` makes a genuine double-send
/// a no-op; a genuine double-loss is not recoverable). So a coalesced request
/// instead stashes itself in `deferredUnpersistable` — a single in-memory
/// slot the slot's current owner drains, via `finishDrainState`, once its own
/// coalesced-rerun loop goes idle. The row still gets exactly one real
/// upload attempt; only the true dead ends (account mismatch with nothing
/// durable anywhere, or a direct attempt that itself fails) are reported as
/// unrecoverable.
actor LiveWorkoutTerminalRetry: LiveWorkoutTerminalRetrying {
    static let shared = LiveWorkoutTerminalRetry()

    private static let log = Logger(
        subsystem: "com.jirathip.sendlog.watchkitapp", category: "liveWorkoutRetry"
    )

    /// #549 finding 7: encodes with fractional-seconds ISO8601 so
    /// `started_at` — the field `guard_live_workout_order()` compares to
    /// order runs — round-trips through this on-disk cache at full
    /// precision; a plain-seconds truncation could make a persisted-and-
    /// retried row compare differently than the original send would have.
    /// A fresh `ISO8601DateFormatter` per call, matching every other date
    /// formatter in this target (`Repo.swift`, `LiveActivityManager.swift`)
    /// — none of them are stored as shared statics, since the type is a
    /// mutable, non-`Sendable` class.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    /// Decode tries the fractional form first, then falls back to the plain
    /// one a PRE-#549 build would have written — the encoder above always
    /// writes fractional now, but decode must keep accepting the plain form,
    /// or this change would itself manufacture finding 5's undecodable-row
    /// failure on every device that upgrades with a row already queued.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO8601 date string (with or without fractional seconds), got \(string)"
            )
        }
        return decoder
    }

    private let upload: @Sendable (LiveWorkoutUpsert) async throws -> Void
    private let baseDir: URL
    private let fileName: String
    private let sessionRelay: SessionRelayRequesting
    private let scheduler: DrainScheduling
    private let fileIO: TerminalRetryFileIO
    private let lossReporter: TerminalLossReporting
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
    /// why a bare in-flight guard is not sufficient here. Also now the one
    /// gate `attemptUnpersistable` requests through (#549 finding 3).
    private var drainState = CoalescingDrain()
    /// #549 F1: at most one unpersistable row waiting for the `drainState`
    /// owner to service it, set only when `attemptUnpersistable` loses the
    /// slot race — see `finishDrainState` and the type doc.
    private var deferredUnpersistable: LiveWorkoutUpsert?

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
        fileIO: TerminalRetryFileIO = RealQueueFileIO(),
        lossReporter: TerminalLossReporting = NoOpTerminalLossReporter(),
        currentUserId: @escaping @Sendable () -> UUID? = { WatchSessionStore.shared.userId }
    ) {
        self.upload = upload
        self.baseDir = baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileName = fileName
        self.sessionRelay = sessionRelay
        self.scheduler = scheduler
        self.fileIO = fileIO
        self.lossReporter = lossReporter
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
        if persisted {
            // #549 finding 2: only this branch may say "queued for durable
            // retry" — a row IS sitting on disk for `retryNow()`/backoff/
            // relay to keep finding.
            Self.log.error(
                "terminal live_workouts upsert failed, queued for durable retry (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
            )
            await retryNow()
        } else {
            // #264/#549 finding 2: nothing is holding this row — saying
            // "queued" here would be a lie. `attemptUnpersistable` makes it
            // exactly one direct in-memory attempt (possibly deferred a
            // moment behind an in-flight retry, #549 F1) before it's
            // genuinely gone.
            Self.log.error(
                "terminal live_workouts upsert failed AND could not be persisted to disk — no durable backup, attempting a direct retry (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
            )
            await attemptUnpersistable(row)
        }
    }

    /// Attempt whatever row is currently persisted, if any, re-checking it
    /// fresh on every pass. Safe to call with nothing queued (no-op) and safe
    /// to call from multiple triggers at once — `drainState` coalesces
    /// overlapping calls into a guaranteed rerun rather than dropping them.
    func retryNow() async {
        guard drainState.request() == .start else { return }
        let stalled = await drainPass()
        await finishDrainState(initialStalled: stalled)
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
    ///
    /// #549 finding 3: requests the same `drainState` slot `retryNow()` does
    /// before uploading, so this can never run concurrently with an in-
    /// flight `drainPass()`. Unlike a persisted row, there is nothing on disk
    /// for a coalesced rerun to pick back up if this request loses the race
    /// (arrives while a pass is already running) — #549 F1 review: simply
    /// skipping in that case would discard the row with zero upload attempts
    /// ever made, which is worse than the harmless idempotent race this
    /// serialization replaced. So a losing request stashes itself in
    /// `deferredUnpersistable` instead, and the slot's current owner drains
    /// it (via `finishDrainState`) once its own coalesced-rerun loop goes
    /// idle — deferred, not lost. Only a row that still can't be sent once it
    /// actually gets its attempt (account mismatch, or the attempt itself
    /// fails) is reported as unrecoverable.
    private func attemptUnpersistable(_ row: LiveWorkoutUpsert) async {
        guard drainState.request() == .start else {
            deferredUnpersistable = row
            Self.log.error(
                "terminal live_workouts row could not be persisted to disk — its direct retry is deferred (in-memory only) behind an in-flight retry, not lost, and will be attempted as soon as that retry finishes (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence))"
            )
            return
        }
        await sendDirectly(row)
        await finishDrainState(initialStalled: false)
    }

    /// The actual single direct upload attempt, shared by `attemptUnpersistable`
    /// (the initial caller, already holding the `drainState` slot) and
    /// `finishDrainState` (draining a deferred row once it reacquires the
    /// slot for itself).
    private func sendDirectly(_ row: LiveWorkoutUpsert) async {
        guard shouldDrain(itemUserId: row.userId, currentUserId: currentUserId()) else {
            // #549 finding 1: unlike `drainPass()`'s mismatch arm (whose row
            // stays safely on disk for its own account to retry later), this
            // row has no durable copy anywhere — a mismatch here is a real,
            // permanent loss, not a deferral, and must say so.
            Self.log.fault(
                "terminal live_workouts row could not be persisted to disk and the signed-in account no longer matches it — this write is now unrecoverable (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence))"
            )
            lossReporter.reportAccountMismatchLoss(runId: row.runId, sequence: row.sequence)
            return
        }
        do {
            try await upload(row)
        } catch {
            Self.log.fault(
                "terminal live_workouts row could not be persisted to disk AND its direct retry failed — this write is now unrecoverable (run \(row.runId.uuidString, privacy: .public) seq \(row.sequence)): \(String(describing: error), privacy: .public)"
            )
            lossReporter.reportUnrecoverableUploadFailure(runId: row.runId, sequence: row.sequence, error: error)
        }
    }

    /// Closes out a `drainState` request this actor's owner (`retryNow()` or
    /// `attemptUnpersistable`) already won — looping the ordinary disk-
    /// reading `drainPass()` for as long as further requests keep coalescing
    /// onto this one, exactly `retryNow()`'s original loop. Factored out so
    /// both entry points share one one-attempt-in-flight implementation
    /// (#549 finding 3) instead of two copies that could drift.
    ///
    /// #549 F1: once that loop goes idle, service any row a coalesced
    /// `attemptUnpersistable` call deferred onto this owner — it never had a
    /// disk copy for the loop above to pick up, so without this it would get
    /// zero upload attempts. Draining it can itself trigger further
    /// coalescing (another hand-off arrives while THIS attempt is in
    /// flight), which is exactly what re-requesting `drainState` and
    /// recursing back through `attemptUnpersistable` handles — the recursion
    /// terminates because each level clears `deferredUnpersistable` before
    /// acting on it.
    private func finishDrainState(initialStalled: Bool) async {
        var stalled = initialStalled
        while drainState.completePass() == .rerun {
            stalled = await drainPass()
        }
        if stalled {
            scheduleBackoffRetry()
        } else {
            consecutiveFailures = 0
        }
        if let row = deferredUnpersistable {
            deferredUnpersistable = nil
            await attemptUnpersistable(row)
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
        guard let data = try? Self.makeEncoder().encode(row) else {
            pendingCount()
            return false
        }
        do {
            try fileIO.write(data, to: fileURL)
            pendingCount()
            // #549 F3: an authoritative push, not just a cache update — the
            // engine's `persist()` does the same (`UploadQueueEngine.swift`)
            // because piggyback-only reporting would leave a stale value on
            // the phone until the next stamped message. Terminal hand-off is
            // the WORST case for that: it's also the moment the live-workout
            // beat stream stops, so there is no later beat to piggyback on —
            // without this push the phone wouldn't hear about a stuck row
            // until the watch app's next launch or foreground.
            Task { @MainActor in WatchBuild.reportQueueStatus() }
            return true
        } catch {
            pendingCount()
            return false
        }
    }

    /// #549 finding 5: reads through the injected `fileIO` seam (so a test
    /// can script a read failure) and, on an undecodable row, reports it
    /// loudly instead of the previous `try?`, which silently discarded the
    /// row from every future pass while leaving it stuck on disk forever
    /// with `hasPendingRetry()` reading false and nobody the wiser. Per the
    /// #287 precedent this codebase otherwise follows: never delete or
    /// rewrite what can't be read — the file is deliberately RETAINED so a
    /// later compatible build gets another chance to decode it.
    private func readPersisted() -> LiveWorkoutUpsert? {
        guard let data = try? fileIO.read(from: fileURL) else { return nil }
        do {
            return try Self.makeDecoder().decode(LiveWorkoutUpsert.self, from: data)
        } catch {
            Self.log.fault(
                "persisted terminal live_workouts row is undecodable — retaining it on disk (#287) rather than silently discarding it from every future retry pass: \(String(describing: error), privacy: .public)"
            )
            lossReporter.reportUndecodableRow(error: error)
            return nil
        }
    }

    /// Delete the persisted row only if it is still the exact row just
    /// uploaded (same run + sequence) — see the type doc's finding-1 note.
    private func clearPersistedIfMatches(_ row: LiveWorkoutUpsert) {
        defer {
            pendingCount()
            // #549 F3: same authoritative push as `persist()` — landing the
            // row must clear a stale nonzero badge just as promptly as a new
            // failure sets one.
            Task { @MainActor in WatchBuild.reportQueueStatus() }
        }
        guard let current = readPersisted() else { return }
        guard current.runId == row.runId, current.sequence == row.sequence else { return }
        try? fileIO.removeItem(at: fileURL)
    }

    // MARK: - #549 finding 6: PendingSyncCache publication

    /// This queue's depth is 0 or 1 (it holds at most one row) — published
    /// whenever a mutation could have changed it, same rule as the other
    /// queues ("whenever it counts, enqueues, or drains", `PendingSyncCache`'s
    /// own doc), and returned so it doubles as the accessor the watch's own
    /// Home/WaitingForPhone pending-uploads badges sum alongside the other
    /// three queues (#549 F2) — without this, those badges kept summing only
    /// three queues while the phone-reported total (which DOES include this
    /// one) moved on, so the watch's own screen and the phone's Account sheet
    /// could show two different numbers for the same stuck row.
    ///
    /// Scoped to the signed-in account the same way
    /// `UploadQueueEngine.pendingCount()` is: a row stamped for a different
    /// CURRENT account reads as absent (its own account reports it once it's
    /// current again), a row is always counted while nobody is signed in
    /// (#158), and an undecodable row is always counted too — same #287
    /// "retained and reported" rule `readPersisted()` follows, since its
    /// account can't be determined without decoding it. #549 F5: unlike the
    /// other queues' quarantine path, there is no aging or purge for an
    /// undecodable row here — it reads as pending indefinitely on a build
    /// that can't decode it. Accepted, same as `UploadQueueEngine`'s own
    /// "unreadable: retained and reported" precedent; a compatible build
    /// (or #549's own backward-compatible decode) is what actually clears it.
    @discardableResult
    func pendingCount() -> Int {
        let uid = currentUserId()
        let depth: Int
        if let data = try? fileIO.read(from: fileURL) {
            if let row = try? Self.makeDecoder().decode(LiveWorkoutUpsert.self, from: data) {
                depth = (shouldDrain(itemUserId: row.userId, currentUserId: uid) || uid == nil) ? 1 : 0
            } else {
                depth = 1
            }
        } else {
            depth = 0
        }
        PendingSyncCache.shared.record(depth, for: .liveWorkoutTerminal)
        // This queue never quarantines anything, but `quarantinedTotal`/
        // `quarantinedStuckTotal` stay nil until EVERY `PendingSyncQueue`
        // case has reported (`PendingSyncCache`'s own honest-states rule) —
        // so this slot must still report zero, every refresh, or those two
        // totals would regress to permanently nil the moment this case
        // exists.
        PendingSyncCache.shared.recordQuarantined(0, for: .liveWorkoutTerminal)
        PendingSyncCache.shared.recordQuarantinedStuck(0, for: .liveWorkoutTerminal)
        return depth
    }
}

extension LiveWorkoutTerminalRetry: QueueDepthReporting {
    nonisolated var syncSlot: PendingSyncQueue { .liveWorkoutTerminal }
    func refreshReportedCounts() async { pendingCount() }
}
