import Foundation
import XCTest
import SendLogWatchCore
import Supabase
@testable import SendLogWatch_Watch_App

/// Issue #531: `LiveWorkoutSync.upsert` used to `try?` away every failure,
/// including a TERMINAL (End) write — the one row nothing else would ever
/// retry, since `beat()`/`markEnded()` refuse every later sequence once
/// `terminalQueued`. `LiveWorkoutTerminalRetry` is the durable owner a
/// failed terminal row is handed off to; these tests exercise its real
/// `handOff`/`retryNow` control flow through the injectable seams, the same
/// way `OfflineQueueTests` exercises `OfflineQueue`'s.
final class LiveWorkoutTerminalRetryTests: XCTestCase {
    private var tempDir: URL!
    private let testUserId = UUID()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWorkoutTerminalRetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleRow(runId: UUID = UUID(), sequence: Int = 7, userId: UUID? = nil) -> LiveWorkoutUpsert {
        LiveWorkoutUpsert(
            userId: userId ?? testUserId, workoutId: runId, runId: runId, sequence: sequence,
            event: "end", terminal: true, status: "ended",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hr: nil, attemptCount: 3, activeKcal: nil, elevationGainM: nil,
            climbing: false, climbingSince: nil, restStartedAt: nil, restTargetS: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_010)
        )
    }

    /// Builds a retry actor signed in as `testUserId` by default — every
    /// existing (pre-#531-review) test exercises the common case where the
    /// row's stamped account matches whoever is currently signed in.
    private func makeRetry(
        upload: @escaping @Sendable (LiveWorkoutUpsert) async throws -> Void,
        sessionRelay: SessionRelayRequesting = RecordingTerminalSessionRelay(),
        scheduler: DrainScheduling = RecordingTerminalScheduler(),
        currentUserId: @escaping @Sendable () -> UUID? = { nil }
    ) -> LiveWorkoutTerminalRetry {
        LiveWorkoutTerminalRetry(
            upload: upload,
            baseDir: tempDir,
            sessionRelay: sessionRelay,
            scheduler: scheduler,
            currentUserId: currentUserId
        )
    }

    private func signedInAs(_ userId: UUID) -> @Sendable () -> UUID? { { userId } }

    /// The named acceptance criterion: a failed terminal upsert must stay
    /// retryable. `handOff` retries immediately, so a transient blip
    /// recovers with no further trigger.
    func testHandOffPersistsThenRecoversOnImmediateRetry() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        let row = sampleRow()
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let uploaded = await uploader.uploaded
        XCTAssertEqual(uploaded, [row.sequence])
        let pending = await retry.hasPendingRetry()
        XCTAssertFalse(pending, "a successful immediate retry must clear the durable row")
    }

    /// A terminal write that keeps failing must stay queued (never dropped)
    /// and arm the #472b bounded backoff so it is retried again with no
    /// foreground/relay event.
    func testFailedRetryStaysPersistedAndSchedulesBackoff() async throws {
        let uploader = ScriptedTerminalUploader(failing: true)
        let scheduler = RecordingTerminalScheduler()
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            scheduler: scheduler,
            currentUserId: signedInAs(testUserId)
        )
        let row = sampleRow()
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let pending = await retry.hasPendingRetry()
        XCTAssertTrue(pending, "a failed retry must keep the row queued, not drop it")
        XCTAssertEqual(scheduler.scheduledCount, 1, "a failed retry must arm the backoff")
    }

    /// "A later auth relay/foreground/backoff can land the terminal row
    /// without requiring another workout action" — proven here by
    /// constructing a BRAND NEW actor instance over the same directory (no
    /// in-memory state carried over, simulating the app having been killed
    /// and relaunched) and confirming it still finds and lands the row.
    func testPersistedRowSurvivesRelaunchAndLandsOnNextRetry() async throws {
        let failingUploader = ScriptedTerminalUploader(failing: true)
        let firstRunActor = makeRetry(
            upload: { try await failingUploader.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        let row = sampleRow()
        await firstRunActor.handOff(row, error: URLError(.notConnectedToInternet))

        let recoveredUploader = ScriptedTerminalUploader(failing: false)
        let relaunchedActor = makeRetry(
            upload: { try await recoveredUploader.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        await relaunchedActor.retryNow()

        let uploaded = await recoveredUploader.uploaded
        XCTAssertEqual(uploaded, [row.sequence], "the row persisted before the kill must land on the next launch's retry")
        let stillPending = await relaunchedActor.hasPendingRetry()
        XCTAssertFalse(stillPending)
    }

    /// A stale-token classification (`.needsAuthRelay`) must ask the phone
    /// for a fresh relay, same as `OfflineQueue`'s #472b recovery path —
    /// not just wait on the blind backoff.
    func test401FailureRequestsAnAuthRelay() async throws {
        let uploader = ScriptedTerminalUploader(
            failing: true,
            error: PostgrestError(code: "PGRST301", message: "No suitable key or wrong key type")
        )
        let relay = RecordingTerminalSessionRelay()
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            sessionRelay: relay,
            currentUserId: signedInAs(testUserId)
        )
        await retry.handOff(sampleRow(), error: URLError(.notConnectedToInternet))

        let requests = await relay.requestCount
        XCTAssertEqual(requests, 1, "a stale-token classification must ask the phone for a fresh relay")
    }

    func testRetryNowIsANoOpWithNothingQueued() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        await retry.retryNow()
        let uploaded = await uploader.uploaded
        XCTAssertTrue(uploaded.isEmpty, "nothing was ever handed off, so retryNow() must not invent a request")
    }

    /// "Repeated retry is idempotent under the existing run/sequence DB
    /// contract" — the DB trigger is what makes a resend of an
    /// already-landed row a safe no-op; the client-side half of that
    /// contract is that a retry always resends the SAME row and stops
    /// resending once it has landed, never inventing a mutated duplicate.
    func testRepeatedRetryIsIdempotentUnderRunSequenceContract() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        let row = sampleRow()
        await retry.handOff(row, error: URLError(.notConnectedToInternet))
        await retry.retryNow() // already cleared; must not resend
        await retry.retryNow()

        let uploadedRows = await uploader.uploadedRows
        XCTAssertEqual(uploadedRows.count, 1, "a landed row must not be resent once cleared")
        XCTAssertEqual(uploadedRows.first?.sequence, row.sequence)
        XCTAssertEqual(uploadedRows.first?.runId, row.runId)
    }

    /// Two overlapping triggers (e.g. foreground firing right as an accepted
    /// relay's follow-up drain runs) must coalesce into one in-flight
    /// attempt, not double-send.
    func testConcurrentRetryTriggersCoalesceToOneAttempt() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        let row = sampleRow()
        await retry.handOff(row, error: URLError(.notConnectedToInternet))
        // The row already landed via handOff's own immediate retry; a
        // trailing concurrent call must see nothing queued.
        async let a: Void = retry.retryNow()
        async let b: Void = retry.retryNow()
        _ = await (a, b)

        let uploadedRows = await uploader.uploadedRows
        XCTAssertEqual(uploadedRows.count, 1)
    }

    // MARK: - #531 review finding 1 + 2: compare-and-clear + lost wake-up

    /// The reviewer's exact scenario: a NEWER terminal hand-off (run B)
    /// arrives while an OLDER attempt (run A) is still suspended inside
    /// `upload`. Without a compare-and-clear, A's success would blindly
    /// delete whatever is on disk — which by then is B's row, not A's — so B
    /// is lost forever (nothing else will ever retry it: `terminalQueued`
    /// already refused every later beat on the real `LiveWorkoutSync`, and
    /// `WorkoutManager.end()` already dropped that actor). Without a
    /// guaranteed rerun (finding 2), even a correct compare-and-clear would
    /// leave B sitting on disk with nothing left to wake it — A's SUCCESS
    /// resets `consecutiveFailures` and never arms the backoff.
    ///
    /// Both fixes are exercised together here, directly, the way
    /// `gaugeSessionEnd.ts` pins its own concurrent-call invariant
    /// (CLAUDE.md's named pattern for this exact class of bug) — no timers,
    /// no sleeps: a `GatedUploader` makes the interleaving deterministic and
    /// the test only ever proceeds by explicitly resuming it, so it cannot
    /// hang.
    func testNewerHandOffWhileOlderAttemptInFlightIsNotLostAndBothLand() async throws {
        let gated = GatedUploader()
        let retry = makeRetry(
            upload: { try await gated.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        let runA = UUID()
        let runB = UUID()
        let rowA = sampleRow(runId: runA, sequence: 1)
        let rowB = sampleRow(runId: runB, sequence: 1)

        let handOffA = Task { await retry.handOff(rowA, error: URLError(.notConnectedToInternet)) }
        await gated.waitUntilStarted() // A's upload is now suspended, in flight

        // B fails and is handed off WHILE A is still in flight. Its own
        // retryNow() call must return promptly (coalesced, not blocked on A).
        await retry.handOff(rowB, error: URLError(.notConnectedToInternet))

        await gated.release() // let A's (and then B's) upload proceed
        await handOffA.value

        let uploadedRuns = await gated.calls.map(\.runId)
        XCTAssertTrue(uploadedRuns.contains(runA), "A must have been attempted")
        XCTAssertTrue(uploadedRuns.contains(runB), "B must not be lost to A's compare-and-clear — it must still be attempted")

        let stillPending = await retry.hasPendingRetry()
        XCTAssertFalse(stillPending, "both rows landed; nothing should remain queued")
    }

    /// Same interleaving, but A's attempt FAILS (not succeeds) after B has
    /// already replaced the file. A's failure path must not touch B's row
    /// either — it stays exactly as B's hand-off left it, and the coalesced
    /// rerun still picks it up.
    func testNewerHandOffSurvivesAnOlderInFlightAttemptThatFails() async throws {
        let gated = GatedUploader()
        let retry = makeRetry(
            upload: { try await gated.upload($0) },
            currentUserId: signedInAs(testUserId)
        )
        let runA = UUID()
        let runB = UUID()
        let rowA = sampleRow(runId: runA, sequence: 1)
        let rowB = sampleRow(runId: runB, sequence: 1)

        await gated.setShouldFail(runA) // only A's attempt fails
        let handOffA = Task { await retry.handOff(rowA, error: URLError(.notConnectedToInternet)) }
        await gated.waitUntilStarted()

        await retry.handOff(rowB, error: URLError(.notConnectedToInternet))
        await gated.release()
        await handOffA.value

        let uploadedRuns = await gated.calls.map(\.runId)
        XCTAssertTrue(uploadedRuns.contains(runA))
        XCTAssertTrue(uploadedRuns.contains(runB), "B must still be attempted even though A's own attempt failed")

        // B (the last row handed off) succeeded and should be cleared; A
        // failed and was superseded, so only B's outcome should be reflected.
        let stillPending = await retry.hasPendingRetry()
        XCTAssertFalse(stillPending, "B landed; nothing should remain queued")
    }

    // MARK: - #531 review finding 3: account scoping

    /// A row stamped for a different account than the one currently signed
    /// in must never be sent — Supabase RLS attributes the write to
    /// `auth.uid()` at request time, not hand-off time, so sending it under
    /// the WRONG account's bearer token is not merely wasted effort, it is a
    /// cross-account write attempt.
    func testRowStampedForADifferentAccountIsNeverSent() async throws {
        let otherAccount = UUID()
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: signedInAs(otherAccount)
        )
        let row = sampleRow(userId: testUserId)
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let uploaded = await uploader.uploaded
        XCTAssertTrue(uploaded.isEmpty, "a row stamped for a different account must never be sent")
    }

    /// Nobody signed in at all — same skip, not a network/auth failure.
    func testNoSignedInAccountNeverSendsAQueuedRow() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: { nil }
        )
        let row = sampleRow(userId: testUserId)
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let uploaded = await uploader.uploaded
        XCTAssertTrue(uploaded.isEmpty)
    }

    /// A row held for a different account is not lost — it becomes eligible
    /// again the moment ITS OWN account is signed in and something calls
    /// `retryNow()` (an accepted relay, in production). Matches the
    /// repo-wide "kept but undrainable until the owning account returns"
    /// invariant (#158) rather than deleting cross-account data.
    func testRowStampedForADifferentAccountLandsOnceThatAccountReturns() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let box = MutableCurrentUserId(nil)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: { box.value }
        )
        let row = sampleRow(userId: testUserId)

        box.value = UUID() // some other account is signed in
        await retry.handOff(row, error: URLError(.notConnectedToInternet))
        var uploaded = await uploader.uploaded
        XCTAssertTrue(uploaded.isEmpty, "must not send under the wrong account")

        box.value = testUserId // the row's own account signs back in
        await retry.retryNow()
        uploaded = await uploader.uploaded
        XCTAssertEqual(uploaded, [row.sequence], "must land once the owning account is current again")
    }

    /// `hasPendingRetry()` must not read a cross-account row as pending for
    /// the CURRENT account — same "treated as absent" rule
    /// `UploadQueueEngine.lastSuccessfulSyncAt()` applies to its own marker.
    func testHasPendingRetryReadsAsAbsentForAMismatchedAccount() async throws {
        let uploader = ScriptedTerminalUploader(failing: true) // never lands, stays on disk
        let box = MutableCurrentUserId(testUserId)
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            currentUserId: { box.value }
        )
        await retry.handOff(sampleRow(userId: testUserId), error: URLError(.notConnectedToInternet))

        var pending = await retry.hasPendingRetry()
        XCTAssertTrue(pending, "own account: the row reads as pending")

        box.value = UUID()
        pending = await retry.hasPendingRetry()
        XCTAssertFalse(pending, "a different signed-in account must read the row as absent, not as its own pending retry")
    }
}

private actor ScriptedTerminalUploader {
    private var shouldFail: Bool
    private let error: Error
    private(set) var uploaded: [Int] = []
    private(set) var uploadedRows: [LiveWorkoutUpsert] = []

    init(failing: Bool, error: Error = URLError(.notConnectedToInternet)) {
        self.shouldFail = failing
        self.error = error
    }

    func upload(_ row: LiveWorkoutUpsert) async throws {
        if shouldFail { throw error }
        uploaded.append(row.sequence)
        uploadedRows.append(row)
    }
}

private actor RecordingTerminalSessionRelay: SessionRelayRequesting {
    private(set) var requestCount = 0
    func requestSessionRelay() async { requestCount += 1 }
}

/// Captures scheduled backoff actions instead of sleeping for real — same
/// rationale as `OfflineQueueTests`' `RecordingScheduler`.
private final class RecordingTerminalScheduler: DrainScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [RetryAction] = []

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduled.count
    }

    nonisolated func scheduleRetry(after delay: TimeInterval, _ action: RetryAction) {
        lock.lock()
        scheduled.append(action)
        lock.unlock()
    }
}

/// Deterministic interleaving without sleeps or timers: `upload` suspends
/// until the test explicitly `release()`s it, and `waitUntilStarted()` lets
/// the test know the suspension has actually begun before it proceeds — so a
/// second hand-off is provably concurrent with the first, not racing to get
/// there first. `release()` is always called exactly once per test and
/// unconditionally, so this cannot hang the suite (#501/#290).
private actor GatedUploader {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var failingRuns: Set<UUID> = []
    private(set) var calls: [LiveWorkoutUpsert] = []

    func setShouldFail(_ runId: UUID) {
        failingRuns.insert(runId)
    }

    func upload(_ row: LiveWorkoutUpsert) async throws {
        calls.append(row)
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !released {
            await withCheckedContinuation { cont in
                releaseContinuation = cont
            }
        }
        if failingRuns.contains(row.runId) {
            throw URLError(.notConnectedToInternet)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { cont in
            startedContinuation = cont
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// A mutable box for `currentUserId` closures that need to change mid-test
/// (an account signing in/out), backed by a lock since it's read from the
/// actor's `@Sendable` closure off the main thread.
private final class MutableCurrentUserId: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UUID?

    init(_ value: UUID?) { _value = value }

    var value: UUID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}
