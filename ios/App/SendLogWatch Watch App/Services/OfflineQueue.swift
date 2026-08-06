import Foundation
import SendLogWatchCore
import Supabase

/// Minimal offline queue for gym basements: every workout save is first
/// serialized to Documents/pending/<uuid>.json, then uploaded and deleted on
/// success. Drained serially (oldest first) on launch / foreground. Replays
/// are safe because uploads are idempotent upserts on client UUIDs.
///
/// `uploader`/`clock`/`baseDir` are the #475 injectable seam:
/// `OfflineQueue.shared` uses the real Supabase-backed uploader, the wall
/// clock, and the app's real Documents directory; tests construct their own
/// instance with a scripted uploader and a scratch directory so the real
/// `drainPass` control flow — not a reimplementation of it — is what gets
/// exercised.
actor OfflineQueue {
    static let shared = OfflineQueue()

    private let uploader: WorkoutBundleUploading
    private let clock: QueueClock
    private let baseDir: URL
    private let sessionRelay: SessionRelayRequesting
    private let scheduler: DrainScheduling
    private var drainState = CoalescingDrain()
    /// #472b: consecutive drain PASSES that stopped early (a `.retry` or
    /// `.needsAuthRelay` break) with nothing in between that fully cleared
    /// the eligible queue. Feeds `QueueRetrySchedule.delay` — see that type's
    /// doc comment for why this counter only affects the DELAY and never
    /// causes retrying to stop.
    private var consecutiveStalls = 0
    /// At most one backoff retry in flight at a time — `drain()` is already
    /// re-triggered independently by enqueue/foreground/relay, and letting
    /// those pile up additional scheduled timers would just mean several
    /// fire in a row for no benefit.
    private var backoffScheduled = false

    init(
        uploader: WorkoutBundleUploading = RepoBundleUploader(),
        clock: QueueClock = SystemQueueClock(),
        baseDir: URL? = nil,
        sessionRelay: SessionRelayRequesting = AuthManagerRelayRequester(),
        scheduler: DrainScheduling = TaskDrainScheduler()
    ) {
        self.uploader = uploader
        self.clock = clock
        self.baseDir = baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.sessionRelay = sessionRelay
        self.scheduler = scheduler
    }

    private var pendingDir: URL {
        let dir = baseDir.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Count of items pending for the currently signed-in account, PLUS any
    /// item stranded while nobody is signed in (issue #189) — otherwise
    /// Account B would see a permanently-stuck "N pending" badge for items
    /// stranded under Account A (#158), AND a workout saved while signed out
    /// would show 0 pending forever, since `shouldDrain` always returns
    /// false with `currentUserId == nil`. `drain()`'s own guard is untouched
    /// (it still never uploads a mismatched or signed-out item) — widening
    /// this count is display-only.
    ///
    /// Quarantined items (#475) live alongside these under a different
    /// extension, so they're never counted here — see `quarantinedCount()`.
    func pendingCount() -> Int {
        let currentUserId = WatchSessionStore.shared.userId
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        let count = files.filter { file in
            guard
                let data = try? Data(contentsOf: file),
                let bundle = try? decoder.decode(WorkoutSaveBundle.self, from: data)
            else { return true } // unreadable: retained and reported until a later build can decode it
            return shouldDrain(itemUserId: bundle.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
        }.count
        // Publish for the sync-readable stamp (#21): reading this actor is an
        // await, which the WatchConnectivity send paths can't do.
        PendingSyncCache.shared.record(count, for: .workouts)
        return count
    }

    /// Count of items `drainPass` has taken off the ordinary drain path
    /// (#475) — a specific DB constraint rejected them, or they failed
    /// enough consecutive SERVER-EVALUATED passes to be treated as stuck
    /// (F3/F11), so no ordinary retry will land them (though a
    /// `.stuckRetrying` one may still land itself via the F12 backoff —
    /// see `quarantinedStuckCount`, below). Reported through a cache slot
    /// separate from `total` (never "pending", never "will sync" — CLAUDE.md
    /// #264) and, since #475 F1, surfaced to the phone over the same
    /// #21/#228 channel as `pendingCount()` — see `WatchBuild.stamp`.
    ///
    /// Account-scoped the SAME way as `pendingCount()` (#475 F4, reversing
    /// the original PR's "stuck is stuck regardless of who's signed in"
    /// call — review found that once this count is actually surfaced,
    /// unscoped it re-opens #158: Account A's stuck workout would show up
    /// as "could not be uploaded" on Account B's phone, for data B can't see
    /// or act on). An unreadable/undecodable `.quarantine` file is retained
    /// and counted, same policy as an unreadable pending file — and counted
    /// as `.schemaRejection`-like (the cautious default) since its `reason`
    /// can't be read.
    @discardableResult
    func quarantinedCount() -> Int {
        let currentUserId = WatchSessionStore.shared.userId
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == quarantineExtension } ?? []
        var total = 0
        var stuck = 0
        for file in files {
            guard
                let data = try? Data(contentsOf: file),
                let record = try? decoder.decode(QuarantinedUpload.self, from: data)
            else {
                total += 1 // unreadable: retained and reported, same as pendingCount()
                continue
            }
            guard shouldDrain(itemUserId: record.bundle.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
            else { continue }
            total += 1
            if record.reason == .stuckRetrying { stuck += 1 }
        }
        PendingSyncCache.shared.recordQuarantined(total)
        PendingSyncCache.shared.recordQuarantinedStuck(stuck)
        return total
    }

    /// Persist the bundle and return as soon as it's on disk — the upload runs
    /// in the background (the queue retries until it lands). If persistence
    /// fails, keep the in-memory bundle alive long enough to attempt the
    /// idempotent upload directly; only failure of both paths is `.lost`.
    func enqueue(_ bundle: WorkoutSaveBundle) async -> QueuePersistOutcome {
        var bundle = bundle
        // Stamp which account is signed in right now (issue #158) — the
        // relayed access token's `sub` claim, read synchronously from the
        // Keychain cache (#265). Checked back in drain().
        bundle.enqueuedUserId = WatchSessionStore.shared.userId

        switch PendingQueuePolicy.actionAfterPersist(persist(bundle)) {
        case .drainQueued:
            Task { await drain() }
            return .queued
        case .uploadDirect:
            do {
                try await uploader.upload(bundle)
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: true)
            } catch {
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: false)
            }
        }
    }

    private func persist(_ bundle: WorkoutSaveBundle) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(bundle.workout.id.uuidString).json")
        let persisted: Bool
        do {
            let data = try encoder.encode(bundle)
            try data.write(to: url, options: .atomic)
            persisted = true
        } catch {
            persisted = false
        }
        _ = pendingCount() // refresh the reported depth (#21)
        Task { @MainActor in WatchBuild.reportQueueStatus() }
        return persisted
    }

    func drain() async {
        guard drainState.request() == .start else { return }
        // request() marks the actor as running before this first suspension.
        var stalled = false
        repeat {
            stalled = await drainPass()
        } while drainState.completePass() == .rerun
        // #472b: only the LAST pass's outcome decides whether to (re)schedule
        // — a pass that stalls and is then immediately superseded by a
        // `.rerun` (a fresh enqueue/relay arrived mid-drain) is not the
        // queue's final word for this `drain()` call.
        if stalled {
            scheduleBackoffRetry()
        } else {
            consecutiveStalls = 0
        }
    }

    /// Schedules a follow-up `drain()` after `QueueRetrySchedule`'s backoff
    /// (#472b) — the fallback for a lost relay answer, not the primary
    /// recovery path (that's `sessionRelay.requestSessionRelay()`, called
    /// directly from `drainPass` on `.needsAuthRelay`). Deliberately has no
    /// give-up state: every stall reschedules, indefinitely — see
    /// `QueueRetrySchedule`'s doc comment for why a bounded ATTEMPT count
    /// would recreate the #472 defect this exists to fix.
    private func scheduleBackoffRetry() {
        guard !backoffScheduled else { return }
        consecutiveStalls += 1
        backoffScheduled = true
        let delay = QueueRetrySchedule.delay(forConsecutiveStalls: consecutiveStalls)
        scheduler.scheduleRetry(after: delay, RetryAction { [self] in
            await self.retryAfterBackoff()
        })
    }

    private func retryAfterBackoff() async {
        backoffScheduled = false
        await drain()
    }

    /// Returns whether the pass stalled — stopped early on a `.retry` or
    /// `.needsAuthRelay` break rather than running to the end of the
    /// eligible files — so `drain()` knows whether to arm the backoff timer.
    @discardableResult
    private func drainPass() async -> Bool {
        resurrectDueStuckRetries() // #475 F12 — give a self-healed bet another chance
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: [.creationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l < r
            }

        var stalled = false
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        filesLoop: for file in files {
            guard
                let data = try? Data(contentsOf: file),
                let bundle = try? decoder.decode(WorkoutSaveBundle.self, from: data)
            else {
                // Never delete an unreadable or undecodable value (#287).
                // It stays counted/published through PendingSyncCache and a
                // later compatible build gets another chance to recover it.
                continue
            }
            // Read fresh right before each file's check, not once before the
            // loop (issue #158) — this is a non-@MainActor actor and `await`
            // below is a suspension point, so a concurrent account switch
            // could otherwise go unnoticed for the rest of the pass and let
            // a file queued under Account A upload under Account B.
            let currentUserId = WatchSessionStore.shared.userId
            guard shouldDrain(itemUserId: bundle.enqueuedUserId, currentUserId: currentUserId) else {
                // Queued under a different account (or nobody's signed in):
                // leave the file on disk untouched and keep checking the
                // rest — this is not a network/auth error, so don't `break`.
                continue
            }
            do {
                try await uploader.upload(bundle)
                try? FileManager.default.removeItem(at: file)
                clearRetryLedger(for: bundle) // a previously-struggling item finally landed
                recordSuccessfulSync(at: clock.now()) // #472b — the "have we synced lately" signal
            } catch {
                // #475: a generic "stop on any error" treated a permanent
                // DB rejection exactly like a network outage, and because
                // the queue drains oldest-first, the poisoned file was
                // retried first on every pass forever — blocking every
                // healthy item behind it. Classify before deciding: only
                // the one specific check-constraint violation this bundle
                // actually exhibits (#475 F5) quarantines immediately;
                // everything else stops the pass so a real outage doesn't
                // burn through the rest of the queue out of order — UNLESS
                // this exact item has now been rejected by the SERVER
                // (not merely failed) `QueueRetryPolicy.maxConsecutiveFailures`
                // times in a row with no success in between, in which case
                // it is quarantined too (reason `.stuckRetrying`, #475 F3)
                // rather than left to block the queue forever on an error
                // this classifier doesn't specifically recognize.
                let classification = UploadFailureMapping.classify(error, bundle: bundle)
                switch classification.outcome {
                case .quarantine:
                    quarantine(
                        bundle: bundle,
                        originalFile: file,
                        reason: .schemaRejection,
                        stage: classification.stage,
                        failure: classification.failure,
                        attemptCount: nil
                    )
                    clearRetryLedger(for: bundle)
                    continue filesLoop
                case .needsAuthRelay:
                    // #475 F11: a stale token means the request was never
                    // evaluated under a valid credential — it is NOT
                    // evidence about this bundle, so it must never advance
                    // the stuck-retry counter. Shipping this counting every
                    // failure (including this one) let a sustained #472-style
                    // stale-relay storm quarantine — and thereby permanently
                    // abandon — a completely healthy workout. Pure break,
                    // ledger untouched.
                    //
                    // #472b — THE core fix this issue was filed for: classifying
                    // the failure was never enough on its own, since nothing
                    // then asked the phone for the token that would actually
                    // unblock the queue. A later drain with the same expired
                    // token just 401s again. `sessionRelay` already throttles
                    // on `SessionRelay.shouldRequestRelay`/`lastRequestAt`
                    // (5s), so this can be called on every stale-token pass
                    // with no second throttle needed here.
                    await sessionRelay.requestSessionRelay()
                    stalled = true
                    break filesLoop
                case .retry:
                    // #475 F11: likewise, only count this failure toward the
                    // stuck-retry budget if the SERVER actually returned
                    // something identifiable — a transport failure
                    // (`UploadFailure()`, everything nil: no network, a
                    // timeout, a dropped connection) reached no server at
                    // all and is equally not evidence about the bundle.
                    //
                    // #475 F17: nor does a 5xx that arrives as a non-JSON
                    // body (`HTTPError`, e.g. a gateway's HTML error page
                    // during a Supabase incident) — the taxonomy's own doc
                    // comment already calls 5xx/408/429 transient; the
                    // ledger must agree. A sustained outage shaped this way
                    // must not quarantine a healthy workout any more than a
                    // transport failure or a stale token does.
                    let failure = classification.failure
                    let transientHTTP = failure.httpStatus.map { $0 >= 500 || $0 == 408 || $0 == 429 } ?? false
                    guard !transientHTTP, failure.postgrestCode != nil || failure.httpStatus != nil else {
                        stalled = true
                        break filesLoop // transport-only or an outage body: no verdict was reached, ledger untouched
                    }
                    let previous = readRetryLedger(for: bundle)?.consecutiveFailures ?? 0
                    switch QueueRetryPolicy.afterFailedAttempt(previousConsecutiveFailures: previous) {
                    case .retryLater(let attempts):
                        writeRetryLedger(
                            RetryLedgerEntry(
                                consecutiveFailures: attempts,
                                lastErrorMessage: failure.message,
                                lastAttemptAt: clock.now()
                            ),
                            for: bundle
                        )
                        stalled = true
                        break filesLoop // a real rejection, but not one we recognize — stop, retry next drain
                    case .stuck(let attempts):
                        quarantine(
                            bundle: bundle,
                            originalFile: file,
                            reason: .stuckRetrying,
                            stage: classification.stage,
                            failure: failure,
                            attemptCount: attempts
                        )
                        clearRetryLedger(for: bundle)
                        continue filesLoop
                    }
                }
            }
        }
        _ = pendingCount() // refresh the reported depth (#21)
        _ = quarantinedCount()
        await MainActor.run { WatchBuild.reportQueueStatus() }
        return stalled
    }

    private let quarantineExtension = "quarantine"
    private let retryLedgerExtension = "retry"

    /// Replaces the original pending file with a `QuarantinedUpload` record
    /// carrying the original bundle plus the failing stage/error/reason
    /// (#475). The original bytes are preserved verbatim inside the new
    /// file, not lost — this is a rename-with-metadata, not a delete. If the
    /// durable write itself fails, the original `<uuid>.json` is left
    /// exactly where it was: it keeps retrying (and keeps failing the same
    /// way) rather than risking the data on an unconfirmed write (#264).
    private func quarantine(
        bundle: WorkoutSaveBundle,
        originalFile: URL,
        reason: QuarantineReason,
        stage: UploadStage?,
        failure: UploadFailure,
        attemptCount: Int?
    ) {
        let record = QuarantinedUpload(
            bundle: bundle,
            reason: reason,
            stage: stage,
            httpStatus: failure.httpStatus,
            postgrestCode: failure.postgrestCode,
            errorMessage: failure.message,
            attemptCount: attemptCount,
            quarantinedAt: clock.now()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let quarantineURL = pendingDir
            .appendingPathComponent(bundle.workout.id.uuidString)
            .appendingPathExtension(quarantineExtension)
        do {
            let data = try encoder.encode(record)
            try data.write(to: quarantineURL, options: .atomic)
            try? FileManager.default.removeItem(at: originalFile)
        } catch {
            // Left in place; see the doc comment above.
        }
    }

    /// #475 F12: `.stuckRetrying` is a bet, not a proof — give any that are
    /// old enough (`QueueRetryPolicy.stuckRetryBackoffS`) exactly one more
    /// chance by restoring them to the ordinary pending rotation with a
    /// fresh retry budget (no ledger — a resurrected item starts counting
    /// from zero, same as a brand-new one). `.schemaRejection` is untouched:
    /// it is the one case actually proven permanent, per the #287 precedent
    /// this only applies to the unproven bet. If it fails again for the same
    /// unrecognized reason, it simply re-earns another `.stuckRetrying`
    /// quarantine after another full budget — this is not a special case,
    /// it's the same `drainPass` logic acting on a file that looks pending
    /// again. Runs at the top of every `drainPass` so a resurrected item is
    /// eligible in the SAME pass, not just the next one.
    private func resurrectDueStuckRetries() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == quarantineExtension } ?? []
        let now = clock.now()
        for file in files {
            guard
                let data = try? Data(contentsOf: file),
                let record = try? decoder.decode(QuarantinedUpload.self, from: data),
                record.reason == .stuckRetrying,
                QueueRetryPolicy.isStuckRetryDue(quarantinedAt: record.quarantinedAt, now: now)
            else { continue }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let bundleData = try? encoder.encode(record.bundle) else { continue }
            let pendingURL = pendingDir.appendingPathComponent("\(record.bundle.workout.id.uuidString).json")
            do {
                try bundleData.write(to: pendingURL, options: .atomic)
                try? FileManager.default.removeItem(at: file)
            } catch {
                // Left quarantined; eligible again next time isStuckRetryDue is checked.
            }
        }
    }

    // MARK: #475 F3 — per-item retry ledger

    private func retryLedgerURL(for bundle: WorkoutSaveBundle) -> URL {
        pendingDir
            .appendingPathComponent(bundle.workout.id.uuidString)
            .appendingPathExtension(retryLedgerExtension)
    }

    private func readRetryLedger(for bundle: WorkoutSaveBundle) -> RetryLedgerEntry? {
        guard let data = try? Data(contentsOf: retryLedgerURL(for: bundle)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RetryLedgerEntry.self, from: data)
    }

    private func writeRetryLedger(_ entry: RetryLedgerEntry, for bundle: WorkoutSaveBundle) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: retryLedgerURL(for: bundle), options: .atomic)
    }

    private func clearRetryLedger(for bundle: WorkoutSaveBundle) {
        try? FileManager.default.removeItem(at: retryLedgerURL(for: bundle))
    }

    // MARK: #472b — "have we synced in a while", surfaced honestly

    /// Sits next to (not inside) `pendingDir`: that directory's listing is
    /// filtered by extension already, but any stray `.json` file dropped
    /// there would be mis-decoded as a `WorkoutSaveBundle` and reported as a
    /// permanently-unreadable pending item (see `pendingCount()`'s "unreadable:
    /// retained and reported" branch) — this marker must never risk that.
    private var lastSyncURL: URL {
        baseDir.appendingPathComponent("last-successful-sync.json")
    }

    private func recordSuccessfulSync(at date: Date) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(LastSyncMarker(syncedAt: date)) else { return }
        try? data.write(to: lastSyncURL, options: .atomic)
    }

    /// When an upload last actually landed, for `SyncFreshnessPolicy` — nil
    /// means "never", not "just now": callers must not default a missing
    /// value to the current time, or a queue that has never synced would
    /// read as freshly synced.
    func lastSuccessfulSyncAt() -> Date? {
        guard let data = try? Data(contentsOf: lastSyncURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LastSyncMarker.self, from: data))?.syncedAt
    }
}
