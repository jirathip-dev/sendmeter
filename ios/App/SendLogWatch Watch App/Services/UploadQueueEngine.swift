import Foundation
import SendLogWatchCore

// MARK: - Issue #491 — ONE persist-first upload queue, not three copies

/// What a value must provide to be queued by `UploadQueueEngine`. The id
/// names the on-disk file (`<uuid>.json`) and — because every upload is an
/// idempotent upsert on a client-minted id — makes replays safe; the user
/// stamp is issue #158's account guard, written by `enqueue` and checked by
/// every drain via `shouldDrain`.
protocol QueueUploadItem: Codable, Sendable {
    var queueFileId: UUID { get }
    var enqueuedUserId: UUID? { get set }

    /// #491 review F1 / #481: a copy of this item with its heavy payload
    /// removed (the recordings sample array, the workout 1Hz raw trace), or
    /// nil when there is nothing separable left to drop — used to keep
    /// quarantine from growing without bound (workouts strip at quarantine
    /// time, #481's named cheap win) and, for the recordings queue, as the
    /// disk-full LAST resort: reclaiming a long-rejected recording's samples
    /// beats destroying the brand-new rep the user just pulled (the same
    /// "the new recording wins" hierarchy `recordingQueue.ts` decided under
    /// CLAUDE.md #264 — a quarantined entry has already been rejected 20+
    /// times). The stripped copy must still identify the item and survive a
    /// re-attempt (ids, stats, provenance intact).
    func strippedOfHeavyPayload() -> Self?
}

/// What `UploadFailureMapping` decides about a failed upload — see that type
/// (OfflineQueueSeams.swift) for how an `Error` becomes one of these.
typealias UploadClassification = (stage: UploadStage?, outcome: UploadErrorOutcome, failure: UploadFailure)

/// The engine's two mutating filesystem operations, injectable so tests can
/// script a REFUSED write (#495 R3 — a full disk is not reproducible on a
/// test host's real filesystem, and both real defects the #486 re-review
/// found lived on exactly that path). Reads and directory listings stay on
/// `FileManager` directly: only mutations need scripting, and the rule
/// "every write/remove goes through `fileIO`" is simpler to audit than a
/// per-call-site choice.
protocol QueueFileIO: Sendable {
    func write(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
}

struct RealQueueFileIO: QueueFileIO {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// The #264 reporting seam for the eviction path: destroying a queued entry
/// to make room is a real loss and must surface (a durable one-shot notice —
/// `RecordingLossNotice` in production), never pass as housekeeping. A
/// protocol rather than a bare closure for the same cross-target isolation
/// reason as `RetryAction` (see OfflineQueueSeams.swift): tests in
/// `SendLogWatchTests` supply a recording stub.
protocol EvictionReporting: Sendable {
    func recordEviction()
}

/// A quarantined item's on-disk record (#475, generalized by #491) — written
/// in place of the original `<uuid>.json`, preserving the item verbatim
/// (never lost, never silently dropped, per CLAUDE.md #264/#273) alongside
/// which stage failed and why, for truthful reporting and a possible future
/// repair pass (#287 precedent). Never read back into a normal drain pass;
/// only user sign-out may delete it (#273) — and today NOTHING does even
/// that, so a `.quarantine` file is effectively permanent on-device storage
/// (see `QuarantinedUpload`'s doc in Models.swift for the growth caveat).
nonisolated struct QueueQuarantineRecord<Item: Codable>: Codable {
    var item: Item
    var reason: QuarantineReason
    var stage: UploadStage?
    var httpStatus: Int?
    var postgrestCode: String?
    var errorMessage: String?
    /// Set only for `reason == .stuckRetrying` — how many consecutive
    /// passes it failed before being given up on, for auditability.
    var attemptCount: Int?
    var quarantinedAt: Date
    /// #491 review F1: true when `item` is a `strippedOfHeavyPayload()` copy
    /// — either stripped at quarantine time (workouts, #481) or reclaimed
    /// later under disk pressure (recordings). Honest provenance: a
    /// resurrected re-attempt of this record uploads real summary stats but
    /// not the original buffer, and support/debugging must be able to tell
    /// that from "the buffer was always this small". nil on legacy records.
    var payloadDropped: Bool?

    enum CodingKeys: String, CodingKey {
        /// The on-disk key stays "bundle": #475 shipped workout quarantine
        /// records as `QuarantinedUpload`, whose stored property was named
        /// `bundle` — files already on real devices must keep decoding.
        /// `OfflineQueueTests` pins this compatibility with a file written
        /// through the legacy type.
        case item = "bundle"
        case reason, stage, httpStatus, postgrestCode, errorMessage, attemptCount, quarantinedAt
        case payloadDropped
    }
}

/// #491 review F2: the header-only projection of a `QueueQuarantineRecord`,
/// for the two per-pass sweeps that must not materialize every quarantined
/// recording's full sample array on a watch (`quarantinedCount` and the
/// not-yet-due majority of `resurrectDueStuckRetries`). `enqueuedUserId` is
/// the one item field the #475-F4 account scoping needs, and every
/// `QueueUploadItem` encodes it under that same synthesized key, so the
/// probe can reach into the legacy "bundle" object without knowing the item
/// type. Decode failure is handled exactly like the full record's ("counted
/// as the cautious default").
private nonisolated struct QueueQuarantineProbe: Decodable {
    struct ItemStamp: Decodable {
        var enqueuedUserId: UUID?
    }

    var item: ItemStamp
    var reason: QuarantineReason
    var quarantinedAt: Date

    enum CodingKeys: String, CodingKey {
        case item = "bundle"
        case reason, quarantinedAt
    }
}

/// How `WatchBuild.refreshAndReportQueueStatus` reaches every queue without
/// hand-listing `async let`s (#491): `PendingSyncCache` requires every
/// `PendingSyncQueue` slot before it reports a total, and the registry test
/// pins that `WatchBuild.reportingQueues` covers every slot — so a dropped
/// source now reads as "not reported" (and fails a test) rather than as an
/// empty queue.
protocol QueueDepthReporting: Sendable {
    nonisolated var syncSlot: PendingSyncQueue { get }
    func refreshReportedCounts() async
}

/// The one offline upload queue implementation (#491). `OfflineQueue`,
/// `PendingSessionQueue` and `PendingRecordingQueue` were three line-for-line
/// copies of the same actor, and the copies had already diverged in the worst
/// direction: #475's retry ledger + quarantine landed only in `OfflineQueue`,
/// so one permanently-rejected force recording parked the LARGEST payload of
/// the three queues forever (the original #475 F3 defect, reintroduced on a
/// new surface). The three named queues are now thin shells over one engine,
/// so there is exactly one retry/quarantine policy to get right.
///
/// Every save is first serialized to `<baseDir>/<directoryName>/<uuid>.json`,
/// then uploaded and deleted on success; drains run serially, oldest first,
/// on launch / foreground / an accepted auth relay / the #472b backoff.
/// Replays are safe because every upload is an idempotent upsert on a
/// client-minted UUID.
///
/// The seams (`upload`/`classify`/`clock`/`baseDir`/`sessionRelay`/
/// `scheduler`/`fileIO`) are #475's injectable pattern: production wrappers
/// pass the real Supabase-backed uploader, the wall clock and the app's real
/// Documents directory; tests construct their own instance with a scripted
/// uploader and a scratch directory so the real `drainPass` control flow —
/// not a reimplementation of it — is what gets exercised.
actor UploadQueueEngine<Item: QueueUploadItem> {
    /// Which `PendingSyncCache` slot this queue publishes to (#21).
    private let slot: PendingSyncQueue
    private let directoryName: String
    /// Per-queue marker filename — the queues share one `baseDir`, so a
    /// single shared name would let one queue's success overwrite another's
    /// history. `OfflineQueue` keeps the pre-#491 name so existing installs
    /// keep their recorded timestamp.
    private let lastSyncFileName: String
    private let upload: @Sendable (Item) async throws -> Void
    private let classify: @Sendable (Error, Item) -> UploadClassification
    private let clock: QueueClock
    private let baseDir: URL
    private let sessionRelay: SessionRelayRequesting
    private let scheduler: DrainScheduling
    private let fileIO: QueueFileIO
    /// #486 review F5, recordings only today: a refused write (disk full)
    /// retries after dropping the OLDEST other queued file — see
    /// `writeWithEviction`. The other two queues keep their pre-#491
    /// fail-fast persist (falling back to the direct upload); widening the
    /// eviction policy to them is a product decision, not a refactor.
    private let evictsOldestOnRefusedWrite: Bool
    private let evictionReporter: EvictionReporting?
    /// #481 / #491 review F1: strip the item's heavy payload at quarantine
    /// time. ON for workouts — `workout.raw` is a 1Hz debug trace, not the
    /// training data, so dropping it before the potentially-forever
    /// quarantine is #481's named cheap win. OFF for recordings — the
    /// samples ARE the recording, and every recording quarantine is the
    /// re-attemptable `.stuckRetrying` kind (its classifier has no
    /// first-attempt schema branch), so stripping eagerly would gut a rep
    /// that a healed server could still land whole; their samples are
    /// reclaimed only under actual disk pressure (`writeWithEviction`'s
    /// last resort), when the alternative is losing a brand-new rep.
    private let stripsPayloadOnQuarantine: Bool

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
        slot: PendingSyncQueue,
        directoryName: String,
        lastSyncFileName: String,
        upload: @escaping @Sendable (Item) async throws -> Void,
        classify: @escaping @Sendable (Error, Item) -> UploadClassification,
        clock: QueueClock,
        baseDir: URL,
        sessionRelay: SessionRelayRequesting,
        scheduler: DrainScheduling,
        fileIO: QueueFileIO = RealQueueFileIO(),
        evictsOldestOnRefusedWrite: Bool = false,
        evictionReporter: EvictionReporting? = nil,
        stripsPayloadOnQuarantine: Bool = false
    ) {
        self.slot = slot
        self.directoryName = directoryName
        self.lastSyncFileName = lastSyncFileName
        self.upload = upload
        self.classify = classify
        self.clock = clock
        self.baseDir = baseDir
        self.sessionRelay = sessionRelay
        self.scheduler = scheduler
        self.fileIO = fileIO
        self.evictsOldestOnRefusedWrite = evictsOldestOnRefusedWrite
        self.evictionReporter = evictionReporter
        self.stripsPayloadOnQuarantine = stripsPayloadOnQuarantine
    }

    private var pendingDir: URL {
        let dir = baseDir.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Count of items pending for the currently signed-in account, PLUS any
    /// item stranded while nobody is signed in (issue #189) — otherwise
    /// Account B would see a permanently-stuck "N pending" badge for items
    /// stranded under Account A (#158), AND an item saved while signed out
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
                let item = try? decoder.decode(Item.self, from: data)
            else { return true } // unreadable: retained and reported until a later build can decode it
            return shouldDrain(itemUserId: item.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
        }.count
        // Publish for the sync-readable stamp (#21): reading this actor is an
        // await, which the WatchConnectivity send paths can't do.
        PendingSyncCache.shared.record(count, for: slot)
        return count
    }

    /// Count of items `drainPass` has taken off the ordinary drain path
    /// (#475) — a specific DB constraint rejected them, or they failed
    /// enough consecutive SERVER-EVALUATED passes to be treated as stuck
    /// (F3/F11), so no ordinary retry will land them (though a
    /// `.stuckRetrying` one may still land itself via the F12 backoff —
    /// see `resurrectDueStuckRetries`). Reported through a cache slot
    /// separate from `total` (never "pending", never "will sync" — CLAUDE.md
    /// #264) and surfaced to the phone over the same #21/#228 channel as
    /// `pendingCount()` — see `WatchBuild.stamp`.
    ///
    /// Account-scoped the SAME way as `pendingCount()` (#475 F4, reversing
    /// the original PR's "stuck is stuck regardless of who's signed in"
    /// call — review found that once this count is actually surfaced,
    /// unscoped it re-opens #158: Account A's stuck item would show up
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
            // #491 review F2: the header-only probe, not the full record —
            // this sweep runs at the end of every drain pass and must not
            // materialize every quarantined recording's sample array.
            guard
                let data = try? Data(contentsOf: file),
                let record = try? decoder.decode(QueueQuarantineProbe.self, from: data)
            else {
                total += 1 // unreadable: retained and reported, same as pendingCount()
                continue
            }
            guard shouldDrain(itemUserId: record.item.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
            else { continue }
            total += 1
            if record.reason == .stuckRetrying { stuck += 1 }
        }
        PendingSyncCache.shared.recordQuarantined(total, for: slot)
        PendingSyncCache.shared.recordQuarantinedStuck(stuck, for: slot)
        return total
    }

    /// One call that publishes BOTH of this queue's cache slots (#491) —
    /// `PendingSyncCache` refuses to report a total until every queue has
    /// published, so the launch/foreground refresh must hit all of them; see
    /// `WatchBuild.reportingQueues`.
    func refreshReportedCounts() {
        _ = pendingCount()
        _ = quarantinedCount()
    }

    /// Persist the item and return as soon as it's on disk — the upload runs
    /// in the background (the queue retries until it lands). If persistence
    /// fails, keep the in-memory value alive long enough to attempt the
    /// idempotent upload directly; only failure of both paths is `.lost`.
    func enqueue(_ item: Item) async -> QueuePersistOutcome {
        var item = item
        // Stamp which account is signed in right now (issue #158) — the
        // relayed access token's `sub` claim, read synchronously from the
        // Keychain cache (#265). Checked back in drain().
        item.enqueuedUserId = WatchSessionStore.shared.userId

        switch PendingQueuePolicy.actionAfterPersist(persist(item)) {
        case .drainQueued:
            Task { await drain() }
            return .queued
        case .uploadDirect:
            do {
                try await upload(item)
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: true)
            } catch {
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: false)
            }
        }
    }

    /// #486 review F5: encoding failure is a programmer error no eviction can
    /// fix, so it's kept out of the eviction loop — only the actual disk
    /// WRITE gets the eviction treatment (when this queue opted into it).
    private func persist(_ item: Item) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(item.queueFileId.uuidString).json")
        let persisted: Bool
        if let data = try? encoder.encode(item) {
            persisted = write(data, to: url)
        } else {
            persisted = false
        }
        _ = pendingCount() // refresh the reported depth (#21)
        Task { @MainActor in WatchBuild.reportQueueStatus() }
        return persisted
    }

    private func write(_ data: Data, to url: URL) -> Bool {
        guard evictsOldestOnRefusedWrite else {
            do {
                try fileIO.write(data, to: url)
                return true
            } catch {
                return false
            }
        }
        return writeWithEviction(data, to: url)
    }

    /// #486 review F5: a refused write (disk full) is retried after dropping
    /// the OLDEST other queued file, repeatedly, down to this new entry
    /// alone — the same "the new recording wins" policy `recordingQueue.ts`
    /// decided under CLAUDE.md #264 for the web queue: the new recording is
    /// the rep the user just pulled and is still thinking about, while a
    /// queued entry has by definition already failed to sync at least once.
    ///
    /// The loop itself is `EvictingWrite.run` (SendLogWatchCore) — pure,
    /// bounded, and tested on Linux CI (#495 R3), carrying the #486
    /// re-review R1 termination guarantees: a removal failure STOPS the loop
    /// (it is information — "this file cannot be freed" — not noise), and the
    /// iteration count is additionally bounded by how many other files
    /// existed when it started.
    ///
    /// #486 re-review R2: an evicted file WAS a queued, unsynced item;
    /// deleting it is a real loss, not routine housekeeping, exactly like a
    /// `.lost` `enqueue` outcome — so a nonzero eviction count is reported
    /// (via `evictionReporter`, the same durable one-shot the `.lost` path
    /// uses) on every exit, success or failure, because a file deleted along
    /// the way is gone regardless of how the NEW entry's own write turned
    /// out. Only pending `.json` files are ever evicted: a `.quarantine`
    /// file's deletion stays reserved for user sign-out (#273), and the
    /// evicted item's `.retry` ledger goes with it (metadata about a file
    /// that no longer exists).
    private func writeWithEviction(_ data: Data, to url: URL) -> Bool {
        let directoryContents = ((try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: nil
        )) ?? [])
        let otherFileCount = directoryContents
            .filter { $0.pathExtension == "json" && $0 != url }.count
        // The bound covers both stages: every other pending file, then every
        // quarantine record whose payload could still be reclaimed.
        let quarantineFileCount = directoryContents
            .filter { $0.pathExtension == quarantineExtension }.count

        let result = EvictingWrite.run(
            maxEvictions: otherFileCount + quarantineFileCount,
            write: { try fileIO.write(data, to: url) },
            evictOldest: {
                if let oldest = self.oldestOtherFile(excluding: url) {
                    do {
                        try self.fileIO.removeItem(at: oldest)
                        try? self.fileIO.removeItem(
                            at: oldest.deletingPathExtension().appendingPathExtension(self.retryLedgerExtension)
                        )
                        return .evicted
                    } catch {
                        return .evictionRefused
                    }
                }
                // #491 review F1: no pending file left to evict. Before
                // giving the write up (and with it, likely, the brand-new
                // rep — the direct-upload fallback needs a network the user
                // may not have), reclaim the sample payload of the OLDEST
                // still-heavy quarantined record. The record itself is
                // retained — id, stats, provenance, `payloadDropped: true` —
                // so #273 ("only sign-out deletes a quarantined item")
                // holds; only its buffer is sacrificed, and only at the
                // moment it would otherwise cost data the user just
                // produced. Reported through the same loss notice as an
                // eviction, because it is one.
                return self.reclaimOldestHeavyQuarantinePayload()
            }
        )
        if result.evictedCount > 0 {
            evictionReporter?.recordEviction()
        }
        return result.persisted
    }

    /// The disk-full last resort behind `writeWithEviction` (#491 review
    /// F1): rewrites the oldest quarantine record whose item still carries a
    /// heavy payload as its stripped copy. Atomic replace via `fileIO.write`
    /// — if even that small write is refused, the record is left whole and
    /// the loop stops (`.evictionRefused`): a truly zero-byte disk is beyond
    /// this valve, and a half-destroyed record must never be the outcome
    /// (#264). Records that fail to decode are skipped, not touched — the
    /// #287 rule (never delete or rewrite what we cannot read) outranks
    /// freeing space.
    private func reclaimOldestHeavyQuarantinePayload() -> EvictionAttemptOutcome {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: [.creationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == quarantineExtension }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l < r
            }
        for file in files {
            guard
                let data = try? Data(contentsOf: file),
                var record = try? decoder.decode(QueueQuarantineRecord<Item>.self, from: data),
                let stripped = record.item.strippedOfHeavyPayload()
            else { continue }
            record.item = stripped
            record.payloadDropped = true
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let strippedData = try? encoder.encode(record) else { continue }
            do {
                try fileIO.write(strippedData, to: file)
                return .evicted
            } catch {
                return .evictionRefused
            }
        }
        return .nothingLeftToEvict
    }

    private func oldestOtherFile(excluding url: URL) -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: [.creationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == "json" && $0 != url }
        guard !files.isEmpty else { return nil }
        return files.min { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return l < r
        }
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

    /// Whether a backoff retry is currently armed (#472b F18) — the watch UI
    /// must not promise "retrying automatically" in a state where nothing
    /// actually is (e.g. no relayed token yet, so `drainPass` never even
    /// attempts an upload and never stalls).
    func isRetryScheduled() -> Bool { backoffScheduled }

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
                let item = try? decoder.decode(Item.self, from: data)
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
            guard shouldDrain(itemUserId: item.enqueuedUserId, currentUserId: currentUserId) else {
                // Queued under a different account (or nobody's signed in):
                // leave the file on disk untouched and keep checking the
                // rest — this is not a network/auth error, so don't `break`.
                continue
            }
            do {
                try await upload(item)
                try? fileIO.removeItem(at: file)
                clearRetryLedger(for: item) // a previously-struggling item finally landed
                recordSuccessfulSync(at: clock.now(), userId: currentUserId) // #472b — the "have we synced lately" signal
            } catch {
                // #475: a generic "stop on any error" treated a permanent
                // DB rejection exactly like a network outage, and because
                // the queue drains oldest-first, the poisoned file was
                // retried first on every pass forever — blocking every
                // healthy item behind it. Classify before deciding: only
                // a rejection the classifier positively recognizes as
                // permanent (#475 F5) quarantines immediately; everything
                // else stops the pass so a real outage doesn't burn through
                // the rest of the queue out of order — UNLESS this exact
                // item has now been rejected by the SERVER (not merely
                // failed) `QueueRetryPolicy.maxConsecutiveFailures` times in
                // a row with no success in between, in which case it is
                // quarantined too (reason `.stuckRetrying`, #475 F3) rather
                // than left to block the queue forever on an error this
                // classifier doesn't specifically recognize.
                let classification = classify(error, item)
                switch classification.outcome {
                case .quarantine:
                    quarantine(
                        item: item,
                        originalFile: file,
                        reason: .schemaRejection,
                        stage: classification.stage,
                        failure: classification.failure,
                        attemptCount: nil
                    )
                    clearRetryLedger(for: item)
                    continue filesLoop
                case .needsAuthRelay:
                    // #475 F11: a stale token means the request was never
                    // evaluated under a valid credential — it is NOT
                    // evidence about this item, so it must never advance
                    // the stuck-retry counter. Shipping this counting every
                    // failure (including this one) let a sustained #472-style
                    // stale-relay storm quarantine — and thereby permanently
                    // abandon — a completely healthy workout. Pure break,
                    // ledger untouched.
                    //
                    // #472b — the core fix that issue was filed for: classifying
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
                    // all and is equally not evidence about the item.
                    //
                    // #475 F17: nor does a 5xx that arrives as a non-JSON
                    // body (`HTTPError`, e.g. a gateway's HTML error page
                    // during a Supabase incident) — the taxonomy's own doc
                    // comment already calls 5xx/408/429 transient; the
                    // ledger must agree. A sustained outage shaped this way
                    // must not quarantine a healthy item any more than a
                    // transport failure or a stale token does. An outcome
                    // the guards below can't positively identify as a
                    // server verdict therefore defaults to RETRY, ledger
                    // untouched.
                    let failure = classification.failure
                    let transientHTTP = failure.httpStatus.map { $0 >= 500 || $0 == 408 || $0 == 429 } ?? false
                    guard !transientHTTP, failure.postgrestCode != nil || failure.httpStatus != nil else {
                        stalled = true
                        break filesLoop // transport-only or an outage body: no verdict was reached, ledger untouched
                    }
                    let previous = readRetryLedger(for: item)?.consecutiveFailures ?? 0
                    switch QueueRetryPolicy.afterFailedAttempt(previousConsecutiveFailures: previous) {
                    case .retryLater(let attempts):
                        writeRetryLedger(
                            RetryLedgerEntry(
                                consecutiveFailures: attempts,
                                lastErrorMessage: failure.message,
                                lastAttemptAt: clock.now()
                            ),
                            for: item
                        )
                        stalled = true
                        break filesLoop // a real rejection, but not one we recognize — stop, retry next drain
                    case .stuck(let attempts):
                        quarantine(
                            item: item,
                            originalFile: file,
                            reason: .stuckRetrying,
                            stage: classification.stage,
                            failure: failure,
                            attemptCount: attempts
                        )
                        clearRetryLedger(for: item)
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

    /// Replaces the original pending file with a `QueueQuarantineRecord`
    /// carrying the original item plus the failing stage/error/reason
    /// (#475). The original bytes are preserved verbatim inside the new
    /// file, not lost — this is a rename-with-metadata, not a delete. If the
    /// durable write itself fails, the original `<uuid>.json` is left
    /// exactly where it was: it keeps retrying (and keeps failing the same
    /// way) rather than risking the data on an unconfirmed write (#264).
    private func quarantine(
        item: Item,
        originalFile: URL,
        reason: QuarantineReason,
        stage: UploadStage?,
        failure: UploadFailure,
        attemptCount: Int?
    ) {
        // #481 / #491 review F1: quarantine is retained indefinitely, so a
        // queue that opted in sheds the heavy payload NOW rather than
        // storing it forever — see `stripsPayloadOnQuarantine`'s doc for
        // which queues opt in and why.
        var quarantinedItem = item
        var payloadDropped: Bool?
        if stripsPayloadOnQuarantine, let stripped = item.strippedOfHeavyPayload() {
            quarantinedItem = stripped
            payloadDropped = true
        }
        let record = QueueQuarantineRecord(
            item: quarantinedItem,
            reason: reason,
            stage: stage,
            httpStatus: failure.httpStatus,
            postgrestCode: failure.postgrestCode,
            errorMessage: failure.message,
            attemptCount: attemptCount,
            quarantinedAt: clock.now(),
            payloadDropped: payloadDropped
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let quarantineURL = pendingDir
            .appendingPathComponent(item.queueFileId.uuidString)
            .appendingPathExtension(quarantineExtension)
        do {
            let data = try encoder.encode(record)
            try fileIO.write(data, to: quarantineURL)
            try? fileIO.removeItem(at: originalFile)
        } catch {
            // Left in place; see the doc comment above.
        }
    }

    /// #475 F12: `.stuckRetrying` is a bet, not a proof — give any that are
    /// old enough (`QueueRetryPolicy.stuckRetryBackoffS`) exactly one more
    /// chance by restoring them to the ordinary pending rotation with a
    /// fresh retry budget (no ledger — a resurrected item starts counting
    /// from zero, same as a brand-new one). `.schemaRejection` is untouched:
    /// it is the one case actually proven permanent; per the #287 precedent
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
            // #491 review F2: probe first — this runs at the top of every
            // drain pass, and for the (typical) not-yet-due majority the
            // header answers without materializing the payload. Only a
            // record that is actually due pays for the full decode below.
            guard
                let data = try? Data(contentsOf: file),
                let probe = try? decoder.decode(QueueQuarantineProbe.self, from: data),
                probe.reason == .stuckRetrying,
                QueueRetryPolicy.isStuckRetryDue(quarantinedAt: probe.quarantinedAt, now: now),
                let record = try? decoder.decode(QueueQuarantineRecord<Item>.self, from: data)
            else { continue }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let itemData = try? encoder.encode(record.item) else { continue }
            let pendingURL = pendingDir.appendingPathComponent("\(record.item.queueFileId.uuidString).json")
            do {
                try fileIO.write(itemData, to: pendingURL)
                try? fileIO.removeItem(at: file)
            } catch {
                // Left quarantined; eligible again next time isStuckRetryDue is checked.
            }
        }
    }

    // MARK: #475 F3 — per-item retry ledger

    private func retryLedgerURL(for item: Item) -> URL {
        pendingDir
            .appendingPathComponent(item.queueFileId.uuidString)
            .appendingPathExtension(retryLedgerExtension)
    }

    private func readRetryLedger(for item: Item) -> RetryLedgerEntry? {
        guard let data = try? Data(contentsOf: retryLedgerURL(for: item)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RetryLedgerEntry.self, from: data)
    }

    private func writeRetryLedger(_ entry: RetryLedgerEntry, for item: Item) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? fileIO.write(data, to: retryLedgerURL(for: item))
    }

    private func clearRetryLedger(for item: Item) {
        try? fileIO.removeItem(at: retryLedgerURL(for: item))
    }

    // MARK: #472b — "have we synced in a while", surfaced honestly

    /// Sits next to (not inside) `pendingDir`: that directory's listing is
    /// filtered by extension already, but any stray `.json` file dropped
    /// there would be mis-decoded as a pending item and reported as a
    /// permanently-unreadable one (see `pendingCount()`'s "unreadable:
    /// retained and reported" branch) — this marker must never risk that.
    private var lastSyncURL: URL {
        baseDir.appendingPathComponent(lastSyncFileName)
    }

    /// `userId` is stamped from the account that was actually signed in for
    /// THIS successful upload (review F20): unlike `pendingCount()`/
    /// `quarantinedCount()`, which are re-derived per file from each item's
    /// own `enqueuedUserId` every time they're read, this marker is a single
    /// global file — with no `userId` of its own it would silently outlive
    /// the account it describes (account A syncs, the phone switches to
    /// account B, B reads A's timestamp as if it were current). Read back in
    /// `lastSuccessfulSyncAt()`, which refuses a mismatch.
    private func recordSuccessfulSync(at date: Date, userId: UUID?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(LastSyncMarker(syncedAt: date, userId: userId)) else { return }
        try? fileIO.write(data, to: lastSyncURL)
    }

    /// When an upload last actually landed FOR THE CURRENTLY SIGNED-IN
    /// ACCOUNT, for `SyncFreshnessPolicy`. nil means "never" (or "not this
    /// account's sync") — callers must not default a missing value to the
    /// current time, or a queue that has never synced under this account
    /// would read as freshly synced. A stored marker whose `userId` doesn't
    /// match `WatchSessionStore.shared.userId` right now is exactly that
    /// case (#472b F20) and is treated the same as no marker at all.
    func lastSuccessfulSyncAt() -> Date? {
        guard let data = try? Data(contentsOf: lastSyncURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(LastSyncMarker.self, from: data) else { return nil }
        guard marker.userId == WatchSessionStore.shared.userId else { return nil }
        return marker.syncedAt
    }
}
