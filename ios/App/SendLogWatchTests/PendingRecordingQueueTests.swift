import Foundation
import XCTest
import SendLogWatchCore
import Supabase
@testable import SendLogWatch_Watch_App

/// #486 review F9: `PendingRecordingQueue` shipped with only Codable/id-
/// passthrough coverage — nothing exercised `enqueue`, `drain`, `drainPass`
/// ordering, the #158 account guard, or the `.lost` path. These exercise the
/// REAL control flow (since #491, `UploadQueueEngine`'s) through the
/// `uploader`/`baseDir`/`fileIO` seams, not a reimplementation of it.
///
/// #491 additions: this queue now carries #475's retry ledger + quarantine
/// (it used to `break` on ANY error, so one permanently-rejected recording
/// parked the largest-payload queue forever), with the F11 exemption —
/// transport and auth failures never advance the ledger — and the F12
/// guarantee that a quarantined recording is retained and re-attempted.
/// #495 R3: the eviction path (where both real #486 re-review defects lived,
/// untested) gets behavioral coverage via the scripted `QueueFileIO` seam.
final class PendingRecordingQueueTests: XCTestCase {
    private let testUserId = UUID()
    private var tempDir: URL!
    private var pendingDir: URL { tempDir.appendingPathComponent("pending-recordings", isDirectory: true) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingRecordingQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        signIn(as: testUserId)
    }

    override func tearDownWithError() throws {
        WatchSessionStore.shared.clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func signIn(as userId: UUID) {
        WatchSessionStore.shared.store(
            RelayedSession(
                accessToken: "test-access-token-\(userId.uuidString)",
                userId: userId,
                expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970
            )
        )
    }

    private func makeRow(id: UUID, peakKg: Double = 34.5) -> TindeqRecordingInsert {
        TindeqRecordingInsert(
            id: id, durationMs: 12_000, peakKg: peakKg, avgKg: 28.1, sampleCount: 2,
            note: "", tag: "FDP", side: "left", groupId: nil, samples: [[0, 0], [1000, peakKg]]
        )
    }

    private func makePending(id: UUID, enqueuedUserId: UUID?) -> PendingTindeqRecording {
        PendingTindeqRecording(row: makeRow(id: id), enqueuedUserId: enqueuedUserId)
    }

    @discardableResult
    private func writeFile(_ pending: PendingTindeqRecording, createdAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pending)
        let url = pendingDir.appendingPathComponent("\(pending.row.id.uuidString).json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
        return url
    }

    private func filesOnDisk() throws -> [String] {
        guard FileManager.default.fileExists(atPath: pendingDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
    }

    private func makeQueue(
        uploader: ScriptedUploader,
        clock: QueueClock = SystemQueueClock(),
        sessionRelay: SessionRelayRequesting = NoopSessionRelay(),
        fileIO: QueueFileIO = RealQueueFileIO(),
        evictionReporter: EvictionReporting = CountingEvictionReporter()
    ) -> PendingRecordingQueue {
        PendingRecordingQueue(
            uploader: uploader,
            baseDir: tempDir,
            clock: clock,
            sessionRelay: sessionRelay,
            scheduler: DiscardingScheduler(), // no real 15s timers leaking out of a test
            fileIO: fileIO,
            evictionReporter: evictionReporter
        )
    }

    /// A server-evaluated rejection the classifier does not recognize as the
    /// one proven-permanent shape — the exact "permanently-rejected force
    /// recording" #491 is about. (Same SQLSTATE the workouts queue's schema
    /// check uses, but with no `.climbAttempts` stage and no zero-duration
    /// evidence it can only ever count toward the `.stuckRetrying` budget.)
    private let permanentRejection = PostgrestError(
        code: "23514",
        message: "new row for relation \"tindeq_recordings\" violates check constraint \"tindeq_recordings_check\""
    )

    // MARK: - enqueue: persistence is synchronous and observable before any drain runs

    func testEnqueuePersistsToDiskBeforeReturning() async throws {
        let id = UUID()
        // persist() runs synchronously inside enqueue, before the background
        // drain Task is even spawned — but that drain CAN win the race to
        // delete the file before the assertion below, so uploads fail on
        // transport to keep it on disk deterministically.
        let queue = makeQueue(uploader: ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet)))
        let outcome = await queue.enqueue(makePending(id: id, enqueuedUserId: nil))
        XCTAssertEqual(outcome, .queued)
        XCTAssertTrue(try filesOnDisk().contains("\(id.uuidString).json"))
    }

    // MARK: - drain: the happy path

    func testDrainUploadsAndDeletesOnSuccess() async throws {
        let id = UUID()
        try writeFile(makePending(id: id, enqueuedUserId: testUserId), createdAt: Date())
        let uploader = ScriptedUploader(failing: [:])
        let queue = makeQueue(uploader: uploader)

        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(id))
        XCTAssertFalse(try filesOnDisk().contains("\(id.uuidString).json"))
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testMultipleHealthyItemsAllUploadInOnePass() async throws {
        let first = UUID()
        let second = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: first, enqueuedUserId: testUserId), createdAt: base)
        try writeFile(makePending(id: second, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [:])
        let queue = makeQueue(uploader: uploader)
        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(first))
        XCTAssertTrue(uploaded.contains(second))
        XCTAssertEqual(try filesOnDisk().count, 0)
    }

    // MARK: - #491: the head-of-line gap is CLOSED — the #475 ledger applies here now

    /// Replaces the pre-#491 pin of the documented gap (#486 review F7):
    /// this used to assert that a permanently-failing head item blocks the
    /// healthy item behind it FOREVER. With the ledger, a server-evaluated
    /// rejection is bounded: below the threshold the pass still stops
    /// (deliberately — oldest-first order is preserved through outages), and
    /// on the threshold-reaching pass the poisoned recording is quarantined
    /// as `.stuckRetrying` and the healthy one uploads in that SAME pass.
    func testAServerRejectedRecordingEventuallyQuarantinesAndFreesTheQueueBehindIt() async throws {
        let poisoned = UUID()
        let healthy = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: poisoned, enqueuedUserId: testUserId), createdAt: now)
        try writeFile(makePending(id: healthy, enqueuedUserId: testUserId), createdAt: now.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [poisoned: permanentRejection])
        let queue = makeQueue(uploader: uploader, clock: FixedClock(now))

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures - 1) {
            await queue.drain()
        }
        var uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(healthy), "below the threshold the pass still stops oldest-first")
        XCTAssertTrue(try filesOnDisk().contains("\(poisoned.uuidString).json"), "still pending short of the threshold")
        XCTAssertTrue(try filesOnDisk().contains("\(poisoned.uuidString).retry"), "a server verdict must be accumulating in the ledger")

        // The threshold-reaching pass.
        await queue.drain()

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(poisoned.uuidString).quarantine"), "quarantined once the budget is spent")
        XCTAssertFalse(remaining.contains("\(poisoned.uuidString).json"))
        XCTAssertFalse(remaining.contains("\(poisoned.uuidString).retry"), "the ledger folds into the quarantine record")
        uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(healthy), "the healthy recording is freed the same pass")
        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 1)
    }

    /// #475 F12 (constraint: retained and re-attemptable, never deleted): a
    /// `.stuckRetrying` quarantine is a bet — after the long backoff the
    /// recording is restored to the pending rotation with a fresh budget,
    /// and uploads normally once whatever was wrong has healed.
    func testAQuarantinedRecordingIsRetainedAndResurrectedAfterTheBackoff() async throws {
        let poisoned = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: poisoned, enqueuedUserId: testUserId), createdAt: now)
        let rejectingUploader = ScriptedUploader(failing: [poisoned: permanentRejection])
        let rejectingQueue = makeQueue(uploader: rejectingUploader, clock: FixedClock(now))
        for _ in 0..<QueueRetryPolicy.maxConsecutiveFailures {
            await rejectingQueue.drain()
        }
        XCTAssertTrue(try filesOnDisk().contains("\(poisoned.uuidString).quarantine"), "retained on disk, never deleted")

        // A relaunch after the backoff, with the server-side cause healed.
        let healedUploader = ScriptedUploader(failing: [:])
        let laterQueue = makeQueue(
            uploader: healedUploader,
            clock: FixedClock(now.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS + 1))
        )
        await laterQueue.drain()

        let uploaded = await healedUploader.uploadedIds
        XCTAssertTrue(uploaded.contains(poisoned), "resurrected and uploaded in the same pass")
        XCTAssertFalse(try filesOnDisk().contains("\(poisoned.uuidString).quarantine"))
        XCTAssertFalse(try filesOnDisk().contains("\(poisoned.uuidString).json"))
    }

    // MARK: - #491 / #475 F11: only a server verdict advances the ledger

    /// A pure transport failure (no network, a timeout) reached no server at
    /// all — no matter how many passes it survives, the recording must stay
    /// pending with NO ledger and NO quarantine: parking recovers when
    /// connectivity returns; quarantine would not.
    func testANetworkOutageNeverQuarantinesARecording() async throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: id, enqueuedUserId: testUserId), createdAt: now)
        let uploader = ScriptedUploader(failing: [id: URLError(.notConnectedToInternet)])
        let queue = makeQueue(uploader: uploader, clock: FixedClock(now))

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(id.uuidString).json"), "must remain pending through any number of outage passes")
        XCTAssertFalse(remaining.contains("\(id.uuidString).retry"), "an outage must not even accumulate a retry count")
        XCTAssertFalse(remaining.contains("\(id.uuidString).quarantine"))
    }

    /// A 5xx delivered as a non-JSON body (#475 F17 — a gateway's error page
    /// during a Supabase incident) is an outage, not a verdict.
    func testA5xxOutageNeverQuarantinesARecording() async throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: id, enqueuedUserId: testUserId), createdAt: now)
        let uploader = ScriptedUploader(failing: [
            id: HTTPError(data: "<html>502 Bad Gateway</html>".data(using: .utf8)!, response: HTTPURLResponse(
                url: URL(string: "https://example.com")!, statusCode: 502, httpVersion: nil, headerFields: nil
            )!),
        ])
        let queue = makeQueue(uploader: uploader, clock: FixedClock(now))

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(id.uuidString).json"))
        XCTAssertFalse(remaining.contains("\(id.uuidString).retry"))
        XCTAssertFalse(remaining.contains("\(id.uuidString).quarantine"))
    }

    /// A stale relayed token means the request was never evaluated under a
    /// valid credential (#475 F11) — ledger untouched — AND the queue must
    /// actually ask the phone for a fresh relay (#472b), which the pre-#491
    /// copy of this queue never did: it recognized nothing and just broke
    /// the pass, leaving recovery to the next foreground.
    func testAStaleTokenNeverQuarantinesARecordingAndAsksThePhoneForARelay() async throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: id, enqueuedUserId: testUserId), createdAt: now)
        let uploader = ScriptedUploader(failing: [
            id: PostgrestError(code: "PGRST301", message: "No suitable key or wrong key type"),
        ])
        let relay = RecordingSessionRelay()
        let queue = makeQueue(uploader: uploader, clock: FixedClock(now), sessionRelay: relay)

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(id.uuidString).json"))
        XCTAssertFalse(remaining.contains("\(id.uuidString).retry"), "a stale token is not evidence about the recording")
        XCTAssertFalse(remaining.contains("\(id.uuidString).quarantine"))
        let requestCount = await relay.requestCount
        XCTAssertEqual(requestCount, QueueRetryPolicy.maxConsecutiveFailures * 2, "every stale-token pass must ask the phone (the seam throttles, not the queue)")
    }

    // MARK: - issue #158: an item queued under a different account never drains

    func testAccountMismatchLeavesFileUntouchedButDoesNotBlockTheRest() async throws {
        let otherAccount = UUID()
        let mismatched = UUID()
        let matching = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // The mismatched item is OLDEST — if the guard used `break` instead
        // of `continue`, it would silently block the matching item behind it
        // exactly like a real failure would.
        try writeFile(makePending(id: mismatched, enqueuedUserId: otherAccount), createdAt: base)
        try writeFile(makePending(id: matching, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [:])
        let queue = makeQueue(uploader: uploader)
        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(mismatched), "never uploads under the wrong account")
        XCTAssertTrue(uploaded.contains(matching), "a mismatched item ahead of it must not block it")
        XCTAssertTrue(try filesOnDisk().contains("\(mismatched.uuidString).json"), "left on disk, untouched")
        XCTAssertFalse(try filesOnDisk().contains("\(matching.uuidString).json"))
    }

    /// While signed in, a DIFFERENT account's item must NOT inflate the
    /// current account's badge (#158 — Account B must not see a
    /// permanently-stuck "N pending" for items stranded under Account A),
    /// but a legacy unstamped (nil) item trusts whoever is currently signed
    /// in, per `shouldDrain`'s own "legacy stamp: trust current session"
    /// branch — so only that one is counted here.
    func testPendingCountExcludesAMismatchedAccountButTrustsAnUnstampedLegacyItem() async throws {
        let otherAccount = UUID()
        try writeFile(makePending(id: UUID(), enqueuedUserId: otherAccount), createdAt: Date())
        try writeFile(makePending(id: UUID(), enqueuedUserId: nil), createdAt: Date())
        let queue = makeQueue(uploader: ScriptedUploader(failing: [:]))

        let count = await queue.pendingCount()
        XCTAssertEqual(count, 1)
    }

    /// The other half of issue #189: while NOBODY is signed in, an item
    /// stranded under some (any) account must still count — otherwise a
    /// recording saved while signed out would read as "0 pending" forever,
    /// since `shouldDrain` always returns false with `currentUserId == nil`.
    func testPendingCountIncludesAnyStrandedItemWhileSignedOut() async throws {
        WatchSessionStore.shared.clear()
        let someAccount = UUID()
        try writeFile(makePending(id: UUID(), enqueuedUserId: someAccount), createdAt: Date())
        let queue = makeQueue(uploader: ScriptedUploader(failing: [:]))

        let count = await queue.pendingCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - persistence failure: the .uploadDirect / .lost fallback (issue #264)

    func testPersistFailureFallsBackToDirectUploadAndSucceeds() async throws {
        // Block "pending-recordings" from ever being a real directory by
        // pre-creating a REGULAR FILE at that exact path — createDirectory
        // fails, and any write underneath it fails too.
        try Data().write(to: pendingDir)
        let id = UUID()
        let uploader = ScriptedUploader(failing: [:])
        let queue = makeQueue(uploader: uploader)

        let outcome = await queue.enqueue(makePending(id: id, enqueuedUserId: nil))

        XCTAssertEqual(outcome, .uploadedDirect)
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(id))
    }

    func testPersistFailureAndDirectUploadFailureIsReportedAsLost() async throws {
        try Data().write(to: pendingDir)
        let id = UUID()
        let uploader = ScriptedUploader(failing: [id: PostgrestError(code: "PGRST301", message: "stale token")])
        let queue = makeQueue(uploader: uploader)

        let outcome = await queue.enqueue(makePending(id: id, enqueuedUserId: nil))

        // Never phrased as queued (CLAUDE.md #264) — the caller must be able
        // to tell "durably queued" from "genuinely gone" apart from this
        // return value alone.
        XCTAssertEqual(outcome, .lost)
    }

    // MARK: - #495 R3: the eviction path, exercised behaviorally

    /// The core #486 F5 policy through the real actor: a refused write
    /// evicts the OLDEST other queued recordings, one per retry, until the
    /// new one fits — and the destroyed recordings are reported (#264), not
    /// passed off as housekeeping.
    func testARefusedWriteEvictsOldestFirstUntilTheNewRecordingFitsAndReportsTheLoss() async throws {
        let oldest = UUID()
        let middle = UUID()
        let newest = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: oldest, enqueuedUserId: testUserId), createdAt: base)
        try writeFile(makePending(id: middle, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(1))
        try writeFile(makePending(id: newest, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(2))

        let fileIO = ScriptedFileIO(refuseWrites: 2)
        let reporter = CountingEvictionReporter()
        // Uploads fail on transport so the post-enqueue background drain
        // can't race the on-disk assertions below.
        let uploader = ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet))
        let queue = makeQueue(uploader: uploader, fileIO: fileIO, evictionReporter: reporter)

        let incoming = UUID()
        let outcome = await queue.enqueue(makePending(id: incoming, enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .queued, "the new recording wins once eviction has made room")
        XCTAssertEqual(fileIO.removedFileNames, ["\(oldest.uuidString).json", "\(middle.uuidString).json"], "evicts strictly oldest-first, one per refused attempt")
        let remaining = try filesOnDisk()
        XCTAssertFalse(remaining.contains("\(oldest.uuidString).json"))
        XCTAssertFalse(remaining.contains("\(middle.uuidString).json"))
        XCTAssertTrue(remaining.contains("\(newest.uuidString).json"), "a newer recording than necessary is never evicted")
        XCTAssertTrue(remaining.contains("\(incoming.uuidString).json"))
        XCTAssertEqual(reporter.count, 1, "the evictions are one real loss event, reported exactly once")
    }

    /// The default reporter wiring: an eviction must land in the SAME
    /// durable one-shot notice the `.lost` path uses, so Home presents it on
    /// next appearance (#486 re-review R2 / CLAUDE.md #264).
    func testEvictionRecordsTheDurableRecordingLossNotice() async throws {
        _ = RecordingLossNotice.consume() // start from a clean flag
        _ = QuarantineTrimNotice.consume()
        defer {
            _ = RecordingLossNotice.consume()
            _ = QuarantineTrimNotice.consume()
        } // never leak state to other tests
        let oldest = UUID()
        try writeFile(makePending(id: oldest, enqueuedUserId: testUserId), createdAt: Date())
        let queue = PendingRecordingQueue(
            uploader: ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet)),
            baseDir: tempDir,
            scheduler: DiscardingScheduler(),
            fileIO: ScriptedFileIO(refuseWrites: 1)
            // evictionReporter deliberately defaulted: this test pins the
            // production wiring, not a stub.
        )

        _ = await queue.enqueue(makePending(id: UUID(), enqueuedUserId: testUserId))

        XCTAssertTrue(RecordingLossNotice.consume(), "an evicted recording is a real loss and must set the durable notice")
        XCTAssertFalse(QuarantineTrimNotice.consume(), "whole-entry eviction must not emit the payload-trim notice")
    }

    /// #491: recordings now carry per-item `.retry` ledgers, so evicting a
    /// recording must take its ledger with it — an orphaned ledger would sit
    /// on disk forever (and would be misread as history if the same UUID
    /// could ever recur).
    func testEvictionAlsoRemovesTheEvictedRecordingsRetryLedger() async throws {
        let oldest = UUID()
        try writeFile(makePending(id: oldest, enqueuedUserId: testUserId), createdAt: Date())
        let ledgerURL = pendingDir.appendingPathComponent("\(oldest.uuidString).retry")
        try Data("{\"consecutiveFailures\":3,\"lastAttemptAt\":\"2026-08-06T00:00:00Z\"}".utf8).write(to: ledgerURL)

        let queue = makeQueue(
            uploader: ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet)),
            fileIO: ScriptedFileIO(refuseWrites: 1)
        )
        let outcome = await queue.enqueue(makePending(id: UUID(), enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .queued)
        let remaining = try filesOnDisk()
        XCTAssertFalse(remaining.contains("\(oldest.uuidString).json"))
        XCTAssertFalse(remaining.contains("\(oldest.uuidString).retry"), "the evicted recording's ledger must not be orphaned")
    }

    /// The refusal that persists after evicting EVERYTHING: the loop is
    /// bounded (write attempts = other files + 1), the caller falls back to
    /// the direct upload, and the destroyed queue is still reported — a
    /// refusal at the end does not un-lose the files evicted on the way.
    func testARefusalThatPersistsAfterEvictingEverythingFallsBackToDirectUpload() async throws {
        let first = UUID()
        let second = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: first, enqueuedUserId: testUserId), createdAt: base)
        try writeFile(makePending(id: second, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(1))

        let fileIO = ScriptedFileIO(refuseAllWrites: true)
        let reporter = CountingEvictionReporter()
        let uploader = ScriptedUploader(failing: [:]) // direct upload succeeds
        let queue = makeQueue(uploader: uploader, fileIO: fileIO, evictionReporter: reporter)

        let incoming = UUID()
        let outcome = await queue.enqueue(makePending(id: incoming, enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .uploadedDirect)
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(incoming))
        XCTAssertEqual(fileIO.writeCalls, 3, "bounded: one attempt per possible eviction plus the first — never a spin")
        XCTAssertEqual(reporter.count, 1, "the two evicted recordings are still a reported loss")
        XCTAssertEqual(try filesOnDisk(), [], "everything evictable was destroyed and the new item never landed on disk")
    }

    /// #273: only user sign-out may delete a quarantined item — eviction
    /// must never select a `.quarantine` file, even when it is the only
    /// other file present and the write can therefore never be satisfied.
    func testEvictionNeverTouchesQuarantineFiles() async throws {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let quarantined = pendingDir.appendingPathComponent("\(UUID().uuidString).quarantine")
        try Data("preserved".utf8).write(to: quarantined)

        let fileIO = ScriptedFileIO(refuseAllWrites: true)
        let uploader = ScriptedUploader(failing: [:])
        let queue = makeQueue(uploader: uploader, fileIO: fileIO)

        let outcome = await queue.enqueue(makePending(id: UUID(), enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .uploadedDirect, "nothing evictable — straight to the direct-upload fallback")
        XCTAssertTrue(fileIO.removedFileNames.isEmpty, "a quarantine file must never be selected for eviction")
        XCTAssertTrue(try filesOnDisk().contains(quarantined.lastPathComponent))
    }

    // MARK: - #491 review F1: a disk full of quarantined recordings must not cost a new rep

    /// Writes a `.quarantine` record directly, the way the engine's own
    /// quarantine path lays it out. `quarantinedAt` is deliberately FUTURE
    /// (the same 2027-ish instant the other fixtures use) so the background
    /// drain's resurrection sweep, which runs on the real clock in these
    /// tests, can never re-pend it mid-assertion.
    @discardableResult
    private func writeQuarantineRecord(
        id: UUID,
        samples: [[Double]],
        createdAt: Date,
        payloadDropped: Bool? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        var pending = makePending(id: id, enqueuedUserId: testUserId)
        pending.row.samples = samples
        let record = QueueQuarantineRecord(
            item: pending,
            reason: .stuckRetrying,
            stage: nil,
            httpStatus: nil,
            postgrestCode: "23514",
            errorMessage: "rejected",
            attemptCount: QueueRetryPolicy.maxConsecutiveFailures,
            quarantinedAt: Date(timeIntervalSince1970: 1_800_000_000),
            payloadDropped: payloadDropped
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("quarantine")
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
        return url
    }

    private func readQuarantineRecord(id: UUID) throws -> QueueQuarantineRecord<PendingTindeqRecording> {
        let url = pendingDir
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("quarantine")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QueueQuarantineRecord<PendingTindeqRecording>.self, from: Data(contentsOf: url))
    }

    /// The assertion #495 R3 was filed about, extended by review F1: with
    /// nothing evictable left but retained quarantine records, a refused
    /// write reclaims the OLDEST record's sample payload (keeping the
    /// record — id, stats, provenance — per #273) instead of letting the
    /// brand-new rep die on the `.uploadDirect`-while-offline path.
    func testANewRepSurvivesADiskFullOfQuarantinedRecordings() async throws {
        let heavySamples: [[Double]] = (0..<200).map { [Double($0) * 10, 30 + Double($0 % 7)] }
        let oldQuarantined = UUID()
        let newerQuarantined = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeQuarantineRecord(id: oldQuarantined, samples: heavySamples, createdAt: base)
        try writeQuarantineRecord(id: newerQuarantined, samples: heavySamples, createdAt: base.addingTimeInterval(1))

        // The pending write is refused once (disk full); the small stripped
        // quarantine rewrite is allowed — freeing the payload is what lets
        // the retried pending write fit.
        let fileIO = ScriptedFileIO(refuseWrites: 1, refuseOnlyPathExtension: "json")
        let reporter = CountingEvictionReporter()
        // Offline throughout: the direct-upload fallback would fail, so
        // only the reclaim can save this rep — and the background drain
        // can't race the on-disk assertions.
        let uploader = ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet))
        let queue = makeQueue(uploader: uploader, fileIO: fileIO, evictionReporter: reporter)

        let incoming = UUID()
        let outcome = await queue.enqueue(makePending(id: incoming, enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .queued, "the new rep must survive on disk, not die on the offline direct-upload path")
        XCTAssertTrue(try filesOnDisk().contains("\(incoming.uuidString).json"))

        let reclaimed = try readQuarantineRecord(id: oldQuarantined)
        XCTAssertEqual(reclaimed.item.row.samples.isEmpty, true, "the OLDEST quarantined record's payload is what gets sacrificed")
        XCTAssertEqual(reclaimed.payloadDropped, true, "the sacrifice is recorded on the record itself")
        XCTAssertEqual(reclaimed.item.row.id, oldQuarantined, "the record survives — reclaim is a payload strip, not a delete (#273)")
        XCTAssertEqual(reclaimed.item.row.peakKg, 34.5, accuracy: 0.001, "summary stats survive for the eventual re-attempt")
        XCTAssertEqual(reclaimed.reason, .stuckRetrying)
        XCTAssertEqual(reclaimed.attemptCount, QueueRetryPolicy.maxConsecutiveFailures)

        let untouched = try readQuarantineRecord(id: newerQuarantined)
        XCTAssertEqual(untouched.item.row.samples.count, heavySamples.count, "only as many payloads are reclaimed as the write actually needs")
        XCTAssertNil(untouched.payloadDropped)

        // #491 R1: a reclaim is reported — but as a TRIM, never as a lost
        // rep: the new rep was saved (asserted above), so the loss copy
        // would be false.
        XCTAssertEqual(reporter.reclaimCount, 1, "the trimmed curve is reported exactly once")
        XCTAssertEqual(reporter.count, 0, "no rep was lost, so the loss notice must not fire")
    }

    /// A persist that both evicts a whole pending recording AND trims a
    /// quarantined one reports both facts — they are different events with
    /// different truths, not one generic "something was destroyed".
    func testAMixedEvictionAndReclaimReportsBothFactsSeparately() async throws {
        let heavySamples: [[Double]] = (0..<200).map { [Double($0) * 10, 30 + Double($0 % 7)] }
        let pendingVictim = UUID()
        let quarantined = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: pendingVictim, enqueuedUserId: testUserId), createdAt: base)
        try writeQuarantineRecord(id: quarantined, samples: heavySamples, createdAt: base)

        let fileIO = ScriptedFileIO(refuseWrites: 2, refuseOnlyPathExtension: "json")
        let reporter = CountingEvictionReporter()
        let uploader = ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet))
        let queue = makeQueue(uploader: uploader, fileIO: fileIO, evictionReporter: reporter)

        let incoming = UUID()
        let outcome = await queue.enqueue(makePending(id: incoming, enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .queued)
        XCTAssertFalse(try filesOnDisk().contains("\(pendingVictim.uuidString).json"), "the pending file went first")
        XCTAssertEqual(try readQuarantineRecord(id: quarantined).payloadDropped, true, "then the quarantine payload")
        XCTAssertEqual(reporter.count, 1, "the destroyed pending recording is a real loss")
        XCTAssertEqual(reporter.reclaimCount, 1, "the trimmed quarantine payload is its own, different fact")
    }

    /// The production wiring for the reclaim notice (#491 R1): a reclaim
    /// sets `QuarantineTrimNotice` — and must NOT set `RecordingLossNotice`,
    /// whose alert says a rep "is gone" when the rep in question was just
    /// saved.
    func testAReclaimRecordsTheTrimNoticeAndNotTheLossNotice() async throws {
        _ = RecordingLossNotice.consume() // start from clean flags
        _ = QuarantineTrimNotice.consume()
        defer {
            _ = RecordingLossNotice.consume() // never leak state to other tests
            _ = QuarantineTrimNotice.consume()
        }
        let heavySamples: [[Double]] = (0..<200).map { [Double($0) * 10, 30 + Double($0 % 7)] }
        try writeQuarantineRecord(id: UUID(), samples: heavySamples, createdAt: Date())
        let queue = PendingRecordingQueue(
            uploader: ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet)),
            baseDir: tempDir,
            scheduler: DiscardingScheduler(),
            fileIO: ScriptedFileIO(refuseWrites: 1, refuseOnlyPathExtension: "json")
            // evictionReporter deliberately defaulted: this pins the
            // production notice wiring, not a stub.
        )

        let outcome = await queue.enqueue(makePending(id: UUID(), enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .queued)
        XCTAssertTrue(QuarantineTrimNotice.consume(), "the trim is reported through its own honest notice")
        XCTAssertFalse(QuarantineTrimNotice.consume(), "a durable trim notice is one-shot")
        XCTAssertFalse(RecordingLossNotice.consume(), "no rep was lost — the loss alert must not fire")
    }

    /// Reclaim can leave persistence refused after it has freed the old
    /// curve. If the direct-upload fallback succeeds, the new rep is still
    /// safe and the trim notice must be emitted after that success — not while
    /// the write is still unresolved.
    func testAReclaimReportsTrimAfterASuccessfulDirectFallback() async throws {
        let quarantined = UUID()
        let heavySamples: [[Double]] = (0..<200).map { [Double($0) * 10, 30 + Double($0 % 7)] }
        try writeQuarantineRecord(id: quarantined, samples: heavySamples, createdAt: Date())
        let fileIO = ScriptedFileIO(refuseWrites: 2, refuseOnlyPathExtension: "json")
        let uploader = ScriptedUploader(failing: [:])
        let reporter = CountingEvictionReporter()
        let queue = makeQueue(uploader: uploader, fileIO: fileIO, evictionReporter: reporter)

        let incoming = UUID()
        let outcome = await queue.enqueue(makePending(id: incoming, enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .uploadedDirect)
        let uploadedIds = await uploader.uploadedIds
        XCTAssertTrue(uploadedIds.contains(incoming))
        XCTAssertEqual(reporter.reclaimCount, 1, "the trim is reported only after the direct upload makes the new rep safe")
        XCTAssertEqual(reporter.count, 0)
    }

    /// If both persistence and direct upload fail after reclaim, the new rep
    /// is genuinely lost; the trim copy would falsely say it was saved, so no
    /// trim notice may be emitted. The caller's ordinary `.lost` path owns
    /// the true loss notice in this outcome.
    func testAReclaimDoesNotReportTrimWhenTheNewRepIsUltimatelyLost() async throws {
        let quarantined = UUID()
        let heavySamples: [[Double]] = (0..<200).map { [Double($0) * 10, 30 + Double($0 % 7)] }
        try writeQuarantineRecord(id: quarantined, samples: heavySamples, createdAt: Date())
        let fileIO = ScriptedFileIO(refuseWrites: 2, refuseOnlyPathExtension: "json")
        let uploader = ScriptedUploader(failingAllWith: URLError(.notConnectedToInternet))
        let reporter = CountingEvictionReporter()
        let queue = makeQueue(uploader: uploader, fileIO: fileIO, evictionReporter: reporter)

        let outcome = await queue.enqueue(makePending(id: UUID(), enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .lost)
        XCTAssertEqual(reporter.reclaimCount, 0, "the new rep was not safe, so the trim notice's copy would be false")
        XCTAssertEqual(reporter.count, 0)
        XCTAssertEqual(try readQuarantineRecord(id: quarantined).payloadDropped, true)
    }

    /// When every quarantined payload is already gone, the reclaim stage
    /// honestly reports nothing left — the caller falls back to the direct
    /// upload, and no record is deleted or rewritten in a doomed attempt to
    /// free bytes that aren't there.
    func testAlreadyStrippedQuarantineRecordsAreNotTouchedAgain() async throws {
        let stripped = UUID()
        try writeQuarantineRecord(id: stripped, samples: [], createdAt: Date(), payloadDropped: true)

        let fileIO = ScriptedFileIO(refuseAllWrites: true, refuseOnlyPathExtension: "json")
        let uploader = ScriptedUploader(failing: [:]) // direct upload succeeds
        let queue = makeQueue(uploader: uploader, fileIO: fileIO)

        let incoming = UUID()
        let outcome = await queue.enqueue(makePending(id: incoming, enqueuedUserId: testUserId))

        XCTAssertEqual(outcome, .uploadedDirect, "nothing reclaimable — straight to the fallback")
        XCTAssertTrue(fileIO.removedFileNames.isEmpty)
        let record = try readQuarantineRecord(id: stripped)
        XCTAssertEqual(record.item.row.id, stripped, "the stripped record is left exactly as it was")
    }

    // MARK: - #486 re-review R1: eviction must terminate even when removal itself fails

    /// The exact shape the re-review proved hung: a write that can never
    /// succeed, an older file to "evict", and the removal ALSO failing (a
    /// read-only parent directory blocks both `data.write` and
    /// `removeItem`, the same way a real permissions/disk-pressure failure
    /// would). Before the fix this spun for 200,001 iterations / 59.6s with
    /// no exit; `enqueue` must now return well within the test timeout.
    /// Kept on the REAL filesystem (default `RealQueueFileIO`) deliberately —
    /// the scripted-IO twin of this case lives in `EvictingWriteTests`.
    func testWriteFailureWithAnUnremovableOlderFileTerminatesRatherThanHanging() async throws {
        let stuck = UUID()
        try writeFile(makePending(id: stuck, enqueuedUserId: testUserId), createdAt: Date())
        // Read+execute only: contentsOfDirectory (used to find the "oldest
        // other file") still works, but both creating the new file AND
        // removing the old one are refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pendingDir.path)
        defer {
            // Restore write access so tearDown can actually delete tempDir.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pendingDir.path)
        }

        let id = UUID()
        let queue = makeQueue(uploader: ScriptedUploader(failing: [:]))

        let expectation = expectation(description: "enqueue returns instead of hanging")
        Task {
            _ = await queue.enqueue(makePending(id: id, enqueuedUserId: testUserId))
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 5)

        // The pre-existing file must survive — removal was refused, not
        // silently treated as done.
        XCTAssertTrue(try filesOnDisk().contains("\(stuck.uuidString).json"))
    }
}

// MARK: - Test doubles

private actor ScriptedUploader: TindeqRecordingUploading {
    private var failing: [UUID: Error]
    private let failAllWith: Error?
    private(set) var uploadedIds: Set<UUID> = []

    init(failing: [UUID: Error]) {
        self.failing = failing
        self.failAllWith = nil
    }

    init(failingAllWith error: Error) {
        self.failing = [:]
        self.failAllWith = error
    }

    func upload(_ row: TindeqRecordingInsert) async throws {
        if let failAllWith { throw failAllWith }
        if let error = failing[row.id] { throw error }
        uploadedIds.insert(row.id)
    }
}

private struct FixedClock: QueueClock {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
}

private actor RecordingSessionRelay: SessionRelayRequesting {
    private(set) var requestCount = 0
    func requestSessionRelay() async { requestCount += 1 }
}

private struct NoopSessionRelay: SessionRelayRequesting {
    func requestSessionRelay() async {}
}

/// Swallows backoff scheduling — these tests drive `drain()` directly and
/// must not leak real 15s `Task.sleep` timers past the test's lifetime.
private struct DiscardingScheduler: DrainScheduling {
    nonisolated func scheduleRetry(after delay: TimeInterval, _ action: RetryAction) {}
}

/// Records evictions and reclaims synchronously — both `EvictionReporting`
/// methods are called from inside the actor's synchronous persist path. The
/// two are counted separately because the whole point of #491 R1 is that
/// they are different facts told differently.
private final class CountingEvictionReporter: EvictionReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _reclaimCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    var reclaimCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _reclaimCount
    }

    func recordEviction() {
        lock.lock()
        _count += 1
        lock.unlock()
    }

    func recordPayloadReclaim() {
        lock.lock()
        _reclaimCount += 1
        lock.unlock()
    }
}

/// #495 R3: scripts REFUSED writes (a full disk is not reproducible on the
/// test host's real filesystem) while performing real removals, so the
/// eviction loop's interplay with actual files stays honest.
private final class ScriptedFileIO: QueueFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var refuseWritesRemaining: Int
    private let refuseAllWrites: Bool
    /// When set, only writes to URLs with this path extension are scripted
    /// to fail; everything else performs the real write. Models "the big
    /// pending file is refused but the small quarantine rewrite fits" —
    /// the actual disk-full shape the #491 F1 reclaim exists for.
    private let refuseOnlyPathExtension: String?
    private var _writeCalls = 0
    private var _removedFileNames: [String] = []

    init(refuseWrites: Int = 0, refuseAllWrites: Bool = false, refuseOnlyPathExtension: String? = nil) {
        self.refuseWritesRemaining = refuseWrites
        self.refuseAllWrites = refuseAllWrites
        self.refuseOnlyPathExtension = refuseOnlyPathExtension
    }

    var writeCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _writeCalls
    }

    var removedFileNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _removedFileNames
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        _writeCalls += 1
        let scripted = refuseOnlyPathExtension.map { url.pathExtension == $0 } ?? true
        var refuse = false
        if scripted {
            refuse = refuseAllWrites || refuseWritesRemaining > 0
            if refuseWritesRemaining > 0 { refuseWritesRemaining -= 1 }
        }
        lock.unlock()
        if refuse { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
        lock.lock()
        _removedFileNames.append(url.lastPathComponent)
        lock.unlock()
    }
}
