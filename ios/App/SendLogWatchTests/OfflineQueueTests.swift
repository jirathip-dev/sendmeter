import Foundation
import XCTest
import SendLogWatchCore
import Supabase
@testable import SendLogWatch_Watch_App

/// Issue #475: `drainPass` used to `break` on ANY upload error — a
/// permanent DB rejection (the poison pill) looked exactly like a network
/// outage, and since the queue drains oldest-first, the poisoned file was
/// retried first on every pass forever, permanently blocking every healthy
/// item behind it. These exercise the REAL `drainPass` control flow (via
/// the `uploader`/`clock`/`baseDir` seam), not a reimplementation of it —
/// per the #475 correction comment, that seam is what makes "a
/// permanent-error item does not block a healthy item" writable at all.
final class OfflineQueueTests: XCTestCase {
    private let testUserId = UUID()
    private var tempDir: URL!
    private var pendingDir: URL { tempDir.appendingPathComponent("pending", isDirectory: true) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineQueueTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeBundle(id: UUID) -> WorkoutSaveBundle {
        let sessionId = UUID()
        let session = SessionInsert(
            id: sessionId, date: "2026-08-06", type: "auto", typeLabel: "Auto-tracked",
            durationMin: 20, rpe: 5, note: "test", phase: "capacity", groupId: nil, workoutSource: "watch"
        )
        let workout = ClimbWorkoutInsert(
            id: id, startedAt: Date(), endedAt: Date(), avgHr: nil, maxHr: nil, activeKcal: nil,
            elevationGainM: 0, attemptsDetected: 0, attemptsConfirmed: 0, rpePredicted: 5,
            rpeConfirmed: 5, meanEffort: 0, attemptsPer10min: 0, sessionId: sessionId, raw: nil
        )
        return WorkoutSaveBundle(session: session, workout: workout, attempts: [], enqueuedUserId: testUserId)
    }

    @discardableResult
    private func writeFile(_ bundle: WorkoutSaveBundle, createdAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let url = pendingDir.appendingPathComponent("\(bundle.workout.id.uuidString).json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
        return url
    }

    private let durationCheckViolation = PostgrestError(
        code: "23514",
        message: "new row for relation \"climb_attempts\" violates check constraint \"climb_attempts_duration_s_check\""
    )

    /// The named acceptance criterion: item A (permanently rejected) does
    /// not block item B (healthy) — through the real drain loop, oldest
    /// (A) sorted first. Also covers "quarantined item remains on disk and
    /// remains counted" and "distinctly from pending".
    func testPermanentErrorItemDoesNotBlockAHealthyItemBehindIt() async throws {
        let poisoned = makeBundle(id: UUID())
        let healthy = makeBundle(id: UUID())
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: base) // oldest: drains first
        try writeFile(healthy, createdAt: base.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(base), baseDir: tempDir)

        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(healthy.workout.id), "the healthy item behind the poisoned one must still upload")
        XCTAssertFalse(uploaded.contains(poisoned.workout.id))

        let remaining = try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).json"), "uploaded item's file should be gone")
        XCTAssertTrue(remaining.contains("\(poisoned.workout.id.uuidString).quarantine"), "poisoned item must remain on disk, quarantined")
        XCTAssertFalse(remaining.contains("\(poisoned.workout.id.uuidString).json"), "the original .json must not also linger")

        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0, "a quarantined item must not read as pending/will-sync")
        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 1)
    }

    /// The quarantine record preserves the original bundle plus which stage
    /// failed and why (Sol's stage-metadata requirement) — a quarantined
    /// item is not a silent drop.
    func testQuarantineRecordPreservesBundleStageAndError() async throws {
        let poisoned = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        await queue.drain()

        let url = pendingDir.appendingPathComponent("\(poisoned.workout.id.uuidString).quarantine")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(QuarantinedUpload.self, from: data)

        XCTAssertEqual(record.bundle.workout.id, poisoned.workout.id, "original bundle must be preserved verbatim")
        XCTAssertEqual(record.stage, .climbAttempts)
        XCTAssertEqual(record.postgrestCode, "23514")
        XCTAssertEqual(record.errorMessage, durationCheckViolation.message)
        XCTAssertEqual(record.quarantinedAt, now)
    }

    /// A quarantined item is written to disk, not held in memory — a fresh
    /// `OfflineQueue` instance pointed at the same directory (simulating a
    /// relaunch) must still see it as quarantined, never re-attempt it as
    /// pending, and still report its count.
    func testQuarantineSurvivesRelaunch() async throws {
        let poisoned = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: now)
        let firstLaunchUploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let firstLaunch = OfflineQueue(uploader: firstLaunchUploader, clock: FixedClock(now), baseDir: tempDir)
        await firstLaunch.drain()

        // A new actor instance over the same directory — nothing about
        // quarantine state may have lived only in memory.
        let secondLaunchUploader = ScriptedUploader(failing: [:])
        let secondLaunch = OfflineQueue(uploader: secondLaunchUploader, clock: FixedClock(now), baseDir: tempDir)
        await secondLaunch.drain()

        let secondLaunchUploaded = await secondLaunchUploader.uploadedIds
        XCTAssertFalse(secondLaunchUploaded.contains(poisoned.workout.id), "a quarantined item must never be re-attempted as pending")
        let secondLaunchQuarantined = await secondLaunch.quarantinedCount()
        let secondLaunchPending = await secondLaunch.pendingCount()
        XCTAssertEqual(secondLaunchQuarantined, 1)
        XCTAssertEqual(secondLaunchPending, 0)
    }

    /// 401/429 must NOT be quarantined (the taxonomy's conservative
    /// default): a retryable/ambiguous failure stops the pass exactly like
    /// the pre-#475 behavior, so a real outage doesn't burn through the
    /// rest of the queue out of order.
    func testRetryableErrorStopsThePassWithoutQuarantiningAnything() async throws {
        let transient = makeBundle(id: UUID())
        let behindIt = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(transient, createdAt: now)
        try writeFile(behindIt, createdAt: now.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [
            transient.workout.id: StagedUploadError(
                stage: .session,
                underlying: HTTPError(data: Data(), response: HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil, headerFields: nil
                )!)
            ),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(behindIt.workout.id), "a retryable failure must still stop the pass, not skip ahead")

        let remaining = try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertTrue(remaining.contains("\(transient.workout.id.uuidString).json"), "429 must stay pending, not be quarantined")
        XCTAssertFalse(remaining.contains("\(transient.workout.id.uuidString).quarantine"))
        let quarantined = await queue.quarantinedCount()
        let pending = await queue.pendingCount()
        XCTAssertEqual(quarantined, 0)
        XCTAssertEqual(pending, 2)
    }
}

/// Test double for `WorkoutBundleUploading` — throws a scripted error per
/// bundle id, otherwise succeeds. An actor so concurrent access from the
/// queue is safe without extra locking in the test.
private actor ScriptedUploader: WorkoutBundleUploading {
    private let failing: [UUID: Error]
    private(set) var uploadedIds: Set<UUID> = []

    init(failing: [UUID: Error]) {
        self.failing = failing
    }

    func upload(_ bundle: WorkoutSaveBundle) async throws {
        if let error = failing[bundle.workout.id] {
            throw error
        }
        uploadedIds.insert(bundle.workout.id)
    }
}

private struct FixedClock: QueueClock {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
}
