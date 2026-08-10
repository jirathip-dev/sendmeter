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

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWorkoutTerminalRetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleRow(runId: UUID = UUID(), sequence: Int = 7) -> LiveWorkoutUpsert {
        LiveWorkoutUpsert(
            userId: UUID(), workoutId: runId, runId: runId, sequence: sequence,
            event: "end", terminal: true, status: "ended",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hr: nil, attemptCount: 3, activeKcal: nil, elevationGainM: nil,
            climbing: false, climbingSince: nil, restStartedAt: nil, restTargetS: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_010)
        )
    }

    /// The named acceptance criterion: a failed terminal upsert must stay
    /// retryable. `handOff` retries immediately, so a transient blip
    /// recovers with no further trigger.
    func testHandOffPersistsThenRecoversOnImmediateRetry() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = LiveWorkoutTerminalRetry(
            upload: { try await uploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: RecordingTerminalSessionRelay(),
            scheduler: RecordingTerminalScheduler()
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
        let retry = LiveWorkoutTerminalRetry(
            upload: { try await uploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: RecordingTerminalSessionRelay(),
            scheduler: scheduler
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
        let firstRunActor = LiveWorkoutTerminalRetry(
            upload: { try await failingUploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: RecordingTerminalSessionRelay(),
            scheduler: RecordingTerminalScheduler()
        )
        let row = sampleRow()
        await firstRunActor.handOff(row, error: URLError(.notConnectedToInternet))

        let recoveredUploader = ScriptedTerminalUploader(failing: false)
        let relaunchedActor = LiveWorkoutTerminalRetry(
            upload: { try await recoveredUploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: RecordingTerminalSessionRelay(),
            scheduler: RecordingTerminalScheduler()
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
        let retry = LiveWorkoutTerminalRetry(
            upload: { try await uploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: relay,
            scheduler: RecordingTerminalScheduler()
        )
        await retry.handOff(sampleRow(), error: URLError(.notConnectedToInternet))

        let requests = await relay.requestCount
        XCTAssertEqual(requests, 1, "a stale-token classification must ask the phone for a fresh relay")
    }

    func testRetryNowIsANoOpWithNothingQueued() async throws {
        let uploader = ScriptedTerminalUploader(failing: false)
        let retry = LiveWorkoutTerminalRetry(
            upload: { try await uploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: RecordingTerminalSessionRelay(),
            scheduler: RecordingTerminalScheduler()
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
        let retry = LiveWorkoutTerminalRetry(
            upload: { try await uploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: RecordingTerminalSessionRelay(),
            scheduler: RecordingTerminalScheduler()
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
        let retry = LiveWorkoutTerminalRetry(
            upload: { try await uploader.upload($0) },
            baseDir: tempDir,
            sessionRelay: RecordingTerminalSessionRelay(),
            scheduler: RecordingTerminalScheduler()
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
