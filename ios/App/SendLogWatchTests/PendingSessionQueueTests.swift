import Foundation
import XCTest
import SendLogWatchCore
import Supabase
@testable import SendLogWatch_Watch_App

/// #491: `PendingSessionQueue` had no seams and therefore no behavioral
/// tests at all — it talked straight to `Repo` and the real Documents
/// directory. Now that it is a shell over `UploadQueueEngine` (whose policy
/// is covered exhaustively via `OfflineQueueTests` and
/// `PendingRecordingQueueTests`), these pin the wiring THIS queue
/// contributes: its directory, its uploader adapter, and the fact that the
/// #475 ledger genuinely applies to it too (it used to `break` on any error,
/// the same head-of-line gap as the recordings queue).
final class PendingSessionQueueTests: XCTestCase {
    private let testUserId = UUID()
    private var tempDir: URL!
    private var pendingDir: URL { tempDir.appendingPathComponent("pending-sessions", isDirectory: true) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingSessionQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WatchSessionStore.shared.store(
            RelayedSession(
                accessToken: "test-access-token",
                userId: testUserId,
                expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970
            )
        )
    }

    override func tearDownWithError() throws {
        WatchSessionStore.shared.clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession(id: UUID) -> PendingTindeqSession {
        PendingTindeqSession(
            id: id, date: "2026-08-06", durationMin: 25, rpe: 6.5, rpeConfirmed: false,
            note: "", groupId: UUID(), enqueuedUserId: testUserId
        )
    }

    @discardableResult
    private func writeFile(_ session: PendingTindeqSession, createdAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let url = pendingDir.appendingPathComponent("\(session.id.uuidString).json")
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
        uploader: ScriptedSessionUploader,
        clock: QueueClock = SystemQueueClock(),
        sessionRelay: SessionRelayRequesting = NoopSessionRelay()
    ) -> PendingSessionQueue {
        PendingSessionQueue(
            uploader: uploader,
            clock: clock,
            baseDir: tempDir,
            sessionRelay: sessionRelay,
            scheduler: DiscardingScheduler()
        )
    }

    func testEnqueuePersistsToDiskBeforeReturning() async throws {
        let id = UUID()
        // Uploads fail on transport so the background drain `enqueue` spawns
        // cannot delete the file out from under the assertion — persistence
        // itself is what's under test.
        let uploader = ScriptedSessionUploader(failing: [id: URLError(.notConnectedToInternet)])
        let queue = makeQueue(uploader: uploader)

        let outcome = await queue.enqueue(makeSession(id: id))

        XCTAssertEqual(outcome, .queued)
        XCTAssertTrue(try filesOnDisk().contains("\(id.uuidString).json"))
    }

    func testDrainUploadsAndDeletesOnSuccess() async throws {
        let id = UUID()
        try writeFile(makeSession(id: id), createdAt: Date())
        let uploader = ScriptedSessionUploader(failing: [:])
        let queue = makeQueue(uploader: uploader)

        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(id))
        XCTAssertFalse(try filesOnDisk().contains("\(id.uuidString).json"))
    }

    /// The #491 acceptance criterion on this queue: a permanently-rejected
    /// session no longer parks every session behind it forever. Pre-#491
    /// this queue `break`-ed on any error with no ledger, so the healthy
    /// session below would NEVER upload.
    func testAServerRejectedSessionEventuallyQuarantinesAndFreesTheQueueBehindIt() async throws {
        let poisoned = UUID()
        let healthy = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makeSession(id: poisoned), createdAt: now)
        try writeFile(makeSession(id: healthy), createdAt: now.addingTimeInterval(1))

        let rejection = PostgrestError(code: "23514", message: "sessions duration bound violated")
        let uploader = ScriptedSessionUploader(failing: [poisoned: rejection])
        let queue = makeQueue(uploader: uploader, clock: FixedClock(now))

        for _ in 0..<QueueRetryPolicy.maxConsecutiveFailures {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(poisoned.uuidString).quarantine"), "retained under quarantine, never deleted")
        XCTAssertFalse(remaining.contains("\(poisoned.uuidString).json"))
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(healthy), "the healthy session must be freed once the poisoned one is quarantined")
    }

    /// #475 F11 on this queue: an outage is not a verdict — no ledger, no
    /// quarantine, no matter how many passes it survives.
    func testANetworkOutageNeverQuarantinesASession() async throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makeSession(id: id), createdAt: now)
        let uploader = ScriptedSessionUploader(failing: [id: URLError(.notConnectedToInternet)])
        let queue = makeQueue(uploader: uploader, clock: FixedClock(now))

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(id.uuidString).json"))
        XCTAssertFalse(remaining.contains("\(id.uuidString).retry"))
        XCTAssertFalse(remaining.contains("\(id.uuidString).quarantine"))
    }

    /// #472b on this queue (new with #491 — the copy never asked): a stale
    /// token drain must actually request a fresh relay from the phone.
    func testAStaleTokenDrainAsksThePhoneForARelay() async throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makeSession(id: id), createdAt: now)
        let uploader = ScriptedSessionUploader(failing: [
            id: PostgrestError(code: "PGRST301", message: "No suitable key or wrong key type"),
        ])
        let relay = RecordingSessionRelay()
        let queue = makeQueue(uploader: uploader, clock: FixedClock(now), sessionRelay: relay)

        await queue.drain()

        let requestCount = await relay.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(try filesOnDisk().contains("\(id.uuidString).json"), "retained — a stale token is recoverable")
    }
}

// MARK: - Test doubles

private actor ScriptedSessionUploader: TindeqSessionUploading {
    private let failing: [UUID: Error]
    private(set) var uploadedIds: Set<UUID> = []

    init(failing: [UUID: Error]) {
        self.failing = failing
    }

    func upload(_ session: PendingTindeqSession) async throws {
        if let error = failing[session.id] { throw error }
        uploadedIds.insert(session.id)
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

private struct DiscardingScheduler: DrainScheduling {
    nonisolated func scheduleRetry(after delay: TimeInterval, _ action: RetryAction) {}
}
