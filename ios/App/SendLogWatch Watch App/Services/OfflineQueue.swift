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

    /// Count of items `drainPass` has permanently given up on (#475) — a
    /// specific DB constraint rejected them, or they failed enough
    /// consecutive passes to be treated as stuck (F3), so no ordinary retry
    /// will land them. Reported through a cache slot separate from `total`
    /// (never "pending", never "will sync" — CLAUDE.md #264) and, since
    /// #475 F1, surfaced to the phone over the same #21/#228 channel as
    /// `pendingCount()` — see `WatchBuild.stamp`.
    ///
    /// Account-scoped the SAME way as `pendingCount()` (#475 F4, reversing
    /// the original PR's "stuck is stuck regardless of who's signed in"
    /// call — review found that once this count is actually surfaced,
    /// unscoped it re-opens #158: Account A's stuck workout would show up
    /// as "could not be uploaded" on Account B's phone, for data B can't see
    /// or act on). An unreadable/undecodable `.quarantine` file is retained
    /// and counted, same policy as an unreadable pending file.
    func quarantinedCount() -> Int {
        let currentUserId = WatchSessionStore.shared.userId
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == quarantineExtension } ?? []
        let count = files.filter { file in
            guard
                let data = try? Data(contentsOf: file),
                let record = try? decoder.decode(QuarantinedUpload.self, from: data)
            else { return true } // unreadable: retained and reported, same as pendingCount()
            return shouldDrain(itemUserId: record.bundle.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
        }.count
        PendingSyncCache.shared.recordQuarantined(count)
        return count
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
                // everything else (including 401/PGRST301/302, which needs
                // a relay rather than a retry) stops the pass so a real
                // outage doesn't burn through the rest of the queue out of
                // order — UNLESS this exact item has now failed
                // `QueueRetryPolicy.maxConsecutiveFailures` passes in a row
                // with no success in between, in which case it is quarantined
                // too (reason `.stuckRetrying`, #475 F3) rather than left to
                // block the queue forever on an error this classifier
                // doesn't specifically recognize.
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
                case .retry, .needsAuthRelay:
                    let previous = readRetryLedger(for: bundle)?.consecutiveFailures ?? 0
                    switch QueueRetryPolicy.afterFailedAttempt(previousConsecutiveFailures: previous) {
                    case .retryLater(let attempts):
                        writeRetryLedger(
                            RetryLedgerEntry(
                                consecutiveFailures: attempts,
                                lastErrorMessage: classification.failure.message,
                                lastAttemptAt: clock.now()
                            ),
                            for: bundle
                        )
                        break filesLoop // no network (or auth) — stop, retry next drain
                    case .stuck(let attempts):
                        quarantine(
                            bundle: bundle,
                            originalFile: file,
                            reason: .stuckRetrying,
                            stage: classification.stage,
                            failure: classification.failure,
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
