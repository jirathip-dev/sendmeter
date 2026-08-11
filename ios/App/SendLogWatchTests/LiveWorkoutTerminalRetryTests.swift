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
        // `PendingSyncCache.shared` is process-wide (#549 finding 6) — reset
        // it so a `.liveWorkoutTerminal` slot left behind by another test
        // can't leak into this one's assertions.
        PendingSyncCache.shared.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        PendingSyncCache.shared.reset()
    }

    private func sampleRow(
        runId: UUID = UUID(), sequence: Int = 7, userId: UUID? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> LiveWorkoutUpsert {
        LiveWorkoutUpsert(
            userId: userId ?? testUserId, workoutId: runId, runId: runId, sequence: sequence,
            event: "end", terminal: true, status: "ended",
            startedAt: startedAt,
            hr: nil, attemptCount: 3, activeKcal: nil, elevationGainM: nil,
            climbing: false, climbingSince: nil, restStartedAt: nil, restTargetS: nil,
            updatedAt: startedAt.addingTimeInterval(10)
        )
    }

    /// Builds a retry actor signed in as `testUserId` by default — every
    /// existing (pre-#531-review) test exercises the common case where the
    /// row's stamped account matches whoever is currently signed in. #549
    /// review finding 4: the default really is `signedInAs(testUserId)` now
    /// (it used to be `{ nil }`, silently contradicting this doc comment —
    /// a test trusting the comment would have asserted nothing, since
    /// `shouldDrain` refuses every row when nobody is signed in). Tests that
    /// want signed-out (or a different account) opt in explicitly via the
    /// `currentUserId:` argument, same as before.
    private func makeRetry(
        upload: @escaping @Sendable (LiveWorkoutUpsert) async throws -> Void,
        sessionRelay: SessionRelayRequesting = RecordingTerminalSessionRelay(),
        scheduler: DrainScheduling = RecordingTerminalScheduler(),
        fileIO: TerminalRetryFileIO = RealQueueFileIO(),
        lossReporter: TerminalLossReporting = RecordingTerminalLossReporter(),
        currentUserId: (@Sendable () -> UUID?)? = nil
    ) -> LiveWorkoutTerminalRetry {
        LiveWorkoutTerminalRetry(
            upload: upload,
            baseDir: tempDir,
            sessionRelay: sessionRelay,
            scheduler: scheduler,
            fileIO: fileIO,
            lossReporter: lossReporter,
            currentUserId: currentUserId ?? signedInAs(testUserId)
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

    // MARK: - #549 review finding 1 + 3: the disk-write-failure fallback

    /// Finding 1: `attemptUnpersistable`'s account-mismatch arm used to
    /// return with no log at all, unlike its catch arm — this exercises that
    /// branch (a mismatched account with nothing durable on disk, i.e. a
    /// genuine, permanent loss) and pins BOTH observable behaviors: the row
    /// is never sent under the wrong account, AND (#549 F4 — the old test
    /// only asserted the first, which was already true of the pre-fix code)
    /// the loss is actually reported through `TerminalLossReporting`, not
    /// just logged somewhere a test can't see.
    func testUnpersistableRowWithAccountMismatchIsNeverSentAndReportsTheLoss() async throws {
        let alwaysRefusing = InMemoryTerminalFileIO(allowedWrites: 0)
        let uploader = ScriptedTerminalUploader(failing: false)
        let reporter = RecordingTerminalLossReporter()
        let retry = makeRetry(
            upload: { try await uploader.upload($0) },
            fileIO: alwaysRefusing,
            lossReporter: reporter,
            currentUserId: signedInAs(UUID())
        )
        let row = sampleRow(userId: testUserId)
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let uploaded = await uploader.uploaded
        XCTAssertTrue(uploaded.isEmpty, "an unpersistable row for a mismatched account must never be sent")

        let mismatchLosses = reporter.accountMismatchLosses
        XCTAssertEqual(mismatchLosses, [row.runId], "the loss must be reported, not just logged where nothing can see it")
    }

    /// The ordinary disk-write-failure path still recovers via one direct
    /// attempt when nothing else is in flight — regression coverage for
    /// `attemptUnpersistable` now that it's routed through `drainState`.
    func testUnpersistableFallbackStillLandsDirectlyWhenNoOtherPassIsInFlight() async throws {
        let alwaysRefusing = InMemoryTerminalFileIO(allowedWrites: 0)
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(upload: { try await uploader.upload($0) }, fileIO: alwaysRefusing)
        let row = sampleRow()
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let uploaded = await uploader.uploaded
        XCTAssertEqual(uploaded, [row.sequence], "the direct fallback must still land the row when nothing else is in flight")
    }

    /// A direct attempt that itself fails (not merely loses the `drainState`
    /// race) is the one genuinely unrecoverable outcome left after the F1
    /// fix below — no durable copy exists, and the attempt it just got was
    /// its only chance. Must be reported, not just logged.
    func testUnpersistableFallbackReportsWhenTheDirectRetryItselfFails() async throws {
        let alwaysRefusing = InMemoryTerminalFileIO(allowedWrites: 0)
        let uploader = ScriptedTerminalUploader(failing: true)
        let reporter = RecordingTerminalLossReporter()
        let retry = makeRetry(upload: { try await uploader.upload($0) }, fileIO: alwaysRefusing, lossReporter: reporter)
        let row = sampleRow()
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let failures = reporter.unrecoverableUploadFailures
        XCTAssertEqual(failures, [row.runId], "a failed direct retry with no durable backup must be reported as unrecoverable")
    }

    /// Finding 3, and its own round-1 review finding (F1): `handOff` used to
    /// call `attemptUnpersistable(row)` directly, bypassing `drainState`
    /// entirely, so it could run concurrently with an in-flight `drainPass()`
    /// — breaking the actor's one-attempt-in-flight property. The first fix
    /// for that made things WORSE: a coalesced (queued) unpersistable row was
    /// simply discarded with zero upload attempts ever made, since the
    /// coalesced rerun only re-reads DISK, which this row was never on. Row A
    /// persists and its upload is gated in flight; row B's disk write then
    /// fails (the one allowed write was A's), so B falls into
    /// `attemptUnpersistable` WHILE A's pass still holds `drainState`. B must
    /// not race A's in-flight upload (`GatedUploader` would hang this test if
    /// it did — a second concurrent caller would overwrite the single release
    /// continuation A is suspended on) — but it must still land, deferred
    /// until A's whole coalesced chain finishes, not dropped.
    func testUnpersistableFallbackIsDeferredNotLostWhileADrainPassIsInFlight() async throws {
        let gated = GatedUploader()
        let flakyIO = InMemoryTerminalFileIO(allowedWrites: 1)
        let retry = makeRetry(upload: { try await gated.upload($0) }, fileIO: flakyIO)
        let rowA = sampleRow(runId: UUID(), sequence: 1)
        let rowB = sampleRow(runId: UUID(), sequence: 1)

        let handOffA = Task { await retry.handOff(rowA, error: URLError(.notConnectedToInternet)) }
        await gated.waitUntilStarted() // A's persist consumed the one allowed write; its upload is now suspended in flight

        // B's persist fails (no writes remain) -> falls into
        // attemptUnpersistable, which loses the drainState race to A's
        // in-flight pass and must be deferred, not discarded.
        await retry.handOff(rowB, error: URLError(.notConnectedToInternet))

        await gated.release() // let A's upload proceed; once A's chain fully finishes, B's deferred attempt runs
        await handOffA.value

        let uploadedRuns = await gated.calls.map(\.runId)
        XCTAssertEqual(
            uploadedRuns, [rowA.runId, rowB.runId],
            "B must still be attempted, strictly after A finishes (not concurrently) — deferred by the coalescing gate, never dropped"
        )
        let stillPending = await retry.hasPendingRetry()
        XCTAssertFalse(stillPending, "both A (persisted) and B (deferred direct attempt) landed; nothing should remain queued")
    }

    // MARK: - #549 review finding 5: undecodable persisted row

    /// A row that fails to decode used to be silently discarded (`try?`)
    /// while staying stuck on disk forever, with `hasPendingRetry()` reading
    /// false the whole time. #549 F4: the old version of this test asserted
    /// only "not uploaded" and "file retained" — both already true of the
    /// pre-fix `try?` code, so the actual behavioral delta (the row is now
    /// REPORTED) was unverified despite the test's name promising it. Now
    /// asserted directly through `TerminalLossReporting`, since `Logger`
    /// output isn't independently observable from a unit test (see
    /// `WorkoutManagerHRMissingDateIntervalTests`'s note).
    func testUndecodablePersistedRowIsReportedNotSwallowedAndRetainedOnDisk() async throws {
        let fileIO = InMemoryTerminalFileIO()
        let fileURL = tempDir.appendingPathComponent("live-workout-terminal-retry.json")
        fileIO.seed(Data("{ this is not a valid LiveWorkoutUpsert }".utf8), at: fileURL)

        let uploader = ScriptedTerminalUploader(failing: false)
        let reporter = RecordingTerminalLossReporter()
        let retry = makeRetry(upload: { try await uploader.upload($0) }, fileIO: fileIO, lossReporter: reporter)

        let pending = await retry.hasPendingRetry()
        XCTAssertFalse(pending, "an undecodable row can't be resolved to an account, so it can't read as pending for anyone")
        let reportsAfterHasPendingRetry = reporter.undecodableRowReportCount
        XCTAssertGreaterThan(reportsAfterHasPendingRetry, 0, "the undecodable row must be reported, not just silently returned as absent")

        await retry.retryNow()
        let uploaded = await uploader.uploaded
        XCTAssertTrue(uploaded.isEmpty, "an undecodable row must never be guessed at and sent")

        XCTAssertNoThrow(
            try fileIO.read(from: fileURL),
            "the #287 rule: an undecodable row must be RETAINED on disk, never deleted, so a later compatible build can recover it"
        )
    }

    // MARK: - #549 review finding 7: fractional-seconds ISO8601

    /// `started_at` is the field `guard_live_workout_order()` compares to
    /// order runs — a plain-seconds encode would let a persisted-and-retried
    /// row compare differently than the original send would have.
    func testPersistedRowRoundTripsSubSecondPrecisionOnStartedAt() async throws {
        let preciseStartedAt = Date(timeIntervalSince1970: 1_800_000_000.123)
        let row = sampleRow(startedAt: preciseStartedAt)
        let failingUploader = ScriptedTerminalUploader(failing: true)
        let retry = makeRetry(upload: { try await failingUploader.upload($0) })
        await retry.handOff(row, error: URLError(.notConnectedToInternet))

        let recoveredUploader = ScriptedTerminalUploader(failing: false)
        let relaunched = makeRetry(upload: { try await recoveredUploader.upload($0) })
        await relaunched.retryNow()

        let landedRows = await recoveredUploader.uploadedRows
        let landedStartedAt = try XCTUnwrap(landedRows.first?.startedAt)
        XCTAssertEqual(
            landedStartedAt.timeIntervalSince1970, preciseStartedAt.timeIntervalSince1970, accuracy: 0.001,
            "sub-second started_at must survive the on-disk round trip"
        )
    }

    /// Decode must stay tolerant of a row a PRE-#549 build persisted (plain
    /// ISO8601, no fractional seconds) — otherwise this change would itself
    /// manufacture finding 5's undecodable-row failure on every device that
    /// upgrades with a row already queued.
    func testPersistedRowFromBeforeTheFractionalSecondsChangeStillDecodes() async throws {
        let fileIO = InMemoryTerminalFileIO()
        let row = sampleRow()
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601 // the pre-#549 plain-seconds format
        let legacyData = try legacyEncoder.encode(row)
        let fileURL = tempDir.appendingPathComponent("live-workout-terminal-retry.json")
        fileIO.seed(legacyData, at: fileURL)

        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = makeRetry(upload: { try await uploader.upload($0) }, fileIO: fileIO)
        await retry.retryNow()

        let uploaded = await uploader.uploaded
        XCTAssertEqual(
            uploaded, [row.sequence],
            "a row persisted by a build before the fractional-seconds change must still decode and land after the upgrade"
        )
    }

    // MARK: - #549 review finding 6: PendingSyncCache publication

    /// `PendingSyncCache.total` only resolves once every `PendingSyncQueue`
    /// case has reported (#491) — stand in for the other three queues by
    /// reporting zero for them directly, the way
    /// `WatchBuild.refreshAndReportQueueStatus` would on a real launch, so
    /// `.liveWorkoutTerminal`'s own contribution is what's under test.
    private func reportOtherQueuesAsEmpty() {
        for queue: PendingSyncQueue in [.workouts, .tindeqSessions, .tindeqRecordings] {
            PendingSyncCache.shared.record(0, for: queue)
            PendingSyncCache.shared.recordQuarantined(0, for: queue)
            PendingSyncCache.shared.recordQuarantinedStuck(0, for: queue)
        }
    }

    func testHandOffPublishesQueueDepthAndLandingClearsItBackToZero() async throws {
        reportOtherQueuesAsEmpty()
        let failingUploader = ScriptedTerminalUploader(failing: true)
        let retry = makeRetry(upload: { try await failingUploader.upload($0) })
        // This queue's own slot hasn't published anything yet — honestly nil,
        // not zero, until `refreshReportedCounts()`/a hand-off counts it.
        await retry.refreshReportedCounts()
        XCTAssertEqual(PendingSyncCache.shared.total, 0, "nothing handed off yet")

        await retry.handOff(sampleRow(), error: URLError(.notConnectedToInternet))
        XCTAssertEqual(PendingSyncCache.shared.total, 1, "a persisted-but-unlanded row must be visible to the phone's queue banner")

        let recoveredUploader = ScriptedTerminalUploader(failing: false)
        let relaunched = makeRetry(upload: { try await recoveredUploader.upload($0) })
        await relaunched.retryNow()
        XCTAssertEqual(PendingSyncCache.shared.total, 0, "landing the row must clear this queue's slot back to zero")
    }

    func testRefreshReportedCountsPublishesAnHonestZeroWithNothingQueued() async throws {
        reportOtherQueuesAsEmpty()
        let retry = makeRetry(upload: { _ in })
        XCTAssertEqual(retry.syncSlot, .liveWorkoutTerminal)
        await retry.refreshReportedCounts()
        XCTAssertEqual(PendingSyncCache.shared.total, 0)
    }

    /// This queue never quarantines anything, but must still report zero for
    /// both quarantine slots every refresh — otherwise `quarantinedTotal`/
    /// `quarantinedStuckTotal` would regress to permanently nil the moment
    /// this case exists, since `PendingSyncCache` refuses to report until
    /// EVERY case has published.
    func testThisQueueReportsZeroQuarantineSoTheOtherTotalsDoNotRegressToNil() async throws {
        for queue: PendingSyncQueue in [.workouts, .tindeqSessions, .tindeqRecordings] {
            PendingSyncCache.shared.recordQuarantined(0, for: queue)
            PendingSyncCache.shared.recordQuarantinedStuck(0, for: queue)
        }
        let retry = makeRetry(upload: { _ in })
        await retry.refreshReportedCounts()
        XCTAssertEqual(PendingSyncCache.shared.quarantinedTotal, 0)
        XCTAssertEqual(PendingSyncCache.shared.quarantinedStuckTotal, 0)
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

/// An in-memory `TerminalRetryFileIO`: write/read/removeItem behave like a
/// real filesystem (so a hand-off followed by a read sees what was written),
/// but writes beyond `allowedWrites` are refused with a disk-full-shaped
/// error — deterministic, host-filesystem-independent modeling of "this
/// specific hand-off's persist fails" (#549 findings 3 and 5; same
/// rationale as `OfflineQueueTests`' `AlwaysRefusingFileIO` and
/// `PendingRecordingQueueTests`' `ScriptedFileIO`, which script refused
/// writes for the same reason a full disk isn't reproducible on the test
/// host's real one).
private final class InMemoryTerminalFileIO: TerminalRetryFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: Data] = [:]
    private var writesRemaining: Int?

    /// nil (default) never refuses a write.
    init(allowedWrites: Int? = nil) {
        self.writesRemaining = allowedWrites
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if let remaining = writesRemaining {
            guard remaining > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
            writesRemaining = remaining - 1
        }
        storage[url] = data
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: url)
    }

    func read(from url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[url] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    /// Directly seeds a raw payload — bypasses `write`'s refusal counter, for
    /// tests that need a specific (possibly undecodable, or legacy-format)
    /// file on disk without going through a real hand-off.
    func seed(_ data: Data, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storage[url] = data
    }
}

/// Records every `TerminalLossReporting` call instead of a no-op — #549 F4:
/// makes the actual behavioral delta of "reported, not swallowed" (findings
/// 1 and 5) assertable, since `Logger`/OSLog output is not. Lock-based
/// (not an actor) so a call from inside `LiveWorkoutTerminalRetry` — itself
/// an actor, calling this synchronously with no `await` — is recorded
/// before that call returns, same rationale as this file's own
/// `RecordingTerminalScheduler`: an actor-hop here would let a test read
/// the recording before the hop-off `Task` actually runs, which is exactly
/// the kind of race this codebase's CLAUDE.md calls out as its most-repeated
/// defect class.
private final class RecordingTerminalLossReporter: TerminalLossReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _accountMismatchLosses: [UUID] = []
    private var _unrecoverableUploadFailures: [UUID] = []
    private var _undecodableRowReportCount = 0

    var accountMismatchLosses: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return _accountMismatchLosses
    }

    var unrecoverableUploadFailures: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return _unrecoverableUploadFailures
    }

    var undecodableRowReportCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _undecodableRowReportCount
    }

    func reportAccountMismatchLoss(runId: UUID, sequence: Int) {
        lock.lock(); defer { lock.unlock() }
        _accountMismatchLosses.append(runId)
    }

    func reportUnrecoverableUploadFailure(runId: UUID, sequence: Int, error: Error) {
        lock.lock(); defer { lock.unlock() }
        _unrecoverableUploadFailures.append(runId)
    }

    func reportUndecodableRow(error: Error) {
        lock.lock(); defer { lock.unlock() }
        _undecodableRowReportCount += 1
    }
}
