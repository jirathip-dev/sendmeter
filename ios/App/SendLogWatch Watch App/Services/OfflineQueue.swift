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
    private var drainState = CoalescingDrain()

    init(
        uploader: WorkoutBundleUploading = RepoBundleUploader(),
        clock: QueueClock = SystemQueueClock(),
        baseDir: URL? = nil
    ) {
        self.uploader = uploader
        self.clock = clock
        self.baseDir = baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
        repeat {
            await drainPass()
        } while drainState.completePass() == .rerun
    }

    private func drainPass() async {
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
                    break filesLoop
                case .retry:
                    // #475 F11: likewise, only count this failure toward the
                    // stuck-retry budget if the SERVER actually returned
                    // something identifiable — a transport failure
                    // (`UploadFailure()`, everything nil: no network, a
                    // timeout, a dropped connection) reached no server at
                    // all and is equally not evidence about the bundle.
                    let failure = classification.failure
                    guard failure.postgrestCode != nil || failure.httpStatus != nil else {
                        break filesLoop // transport-only: no verdict was reached, ledger untouched
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
}
