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

    /// #475 F9: a same-tick manual Begin/End on a pre-#475 build — the
    /// exact poison shape. `AttemptDetector` (SendLogWatchCore) now
    /// GUARANTEES `durationS > 0` for everything it emits, so this shape
    /// can no longer come out of the current detector by construction; the
    /// only faithful way to reproduce "a legacy bundle already sitting in
    /// the queue" is to build the on-disk shape directly, exactly as
    /// `Repo.makeSaveBundle` would have mapped it before this fix existed.
    private func makePoisonedAttempt(workoutId: UUID) -> ClimbAttemptInsert {
        ClimbAttemptInsert(
            id: UUID(), workoutId: workoutId, startedAt: Date(), durationS: 0.0,
            elevationGainM: 0, avgHr: nil, peakHr: nil, motionIntensity: 0, effortScore: 0,
            source: "manual"
        )
    }

    private func makeHealthyAttempt(workoutId: UUID) -> ClimbAttemptInsert {
        ClimbAttemptInsert(
            id: UUID(), workoutId: workoutId, startedAt: Date(), durationS: 24.5,
            elevationGainM: 3.1, avgHr: 140, peakHr: 160, motionIntensity: 0.4, effortScore: 5,
            source: "auto"
        )
    }

    private func makeBundle(
        id: UUID,
        attempts: [ClimbAttemptInsert] = [],
        enqueuedUserId: UUID? = nil
    ) -> WorkoutSaveBundle {
        let sessionId = UUID()
        let session = SessionInsert(
            id: sessionId, date: "2026-08-06", type: "auto", typeLabel: "Auto-tracked",
            durationMin: 20, rpe: 5, note: "test", phase: "capacity", groupId: nil, workoutSource: "watch"
        )
        let workout = ClimbWorkoutInsert(
            id: id, startedAt: Date(), endedAt: Date(), avgHr: nil, maxHr: nil, activeKcal: nil,
            elevationGainM: 0, attemptsDetected: attempts.count, attemptsConfirmed: attempts.count,
            rpePredicted: 5, rpeConfirmed: 5, meanEffort: 0, attemptsPer10min: 0,
            sessionId: sessionId, raw: nil
        )
        return WorkoutSaveBundle(
            session: session, workout: workout, attempts: attempts,
            enqueuedUserId: enqueuedUserId ?? testUserId
        )
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

    private func filesOnDisk() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
    }

    private let durationCheckViolation = PostgrestError(
        code: "23514",
        message: "new row for relation \"climb_attempts\" violates check constraint \"climb_attempts_duration_s_check\""
    )

    /// The named acceptance criterion: item A (permanently rejected) does
    /// not block item B (healthy) — through the real drain loop, oldest
    /// (A) sorted first. Also covers "quarantined item remains on disk and
    /// remains counted" and "distinctly from pending". Both bundles carry
    /// real attempts (#475 F9) — the poisoned one's zero-duration attempt is
    /// what the classifier's local-evidence check actually looks at.
    func testPermanentErrorItemDoesNotBlockAHealthyItemBehindIt() async throws {
        let poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
        let healthyId = UUID()
        let healthy = makeBundle(id: healthyId, attempts: [makeHealthyAttempt(workoutId: healthyId)])
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

        let remaining = try filesOnDisk()
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).json"), "uploaded item's file should be gone")
        XCTAssertTrue(remaining.contains("\(poisoned.workout.id.uuidString).quarantine"), "poisoned item must remain on disk, quarantined")
        XCTAssertFalse(remaining.contains("\(poisoned.workout.id.uuidString).json"), "the original .json must not also linger")

        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0, "a quarantined item must not read as pending/will-sync")
        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 1)
    }

    /// A same-source, same-SQLSTATE check violation on a bundle that does
    /// NOT actually carry a non-positive-duration attempt (#475 F5's
    /// `climb_attempts_source_check` example) must fall through to retry,
    /// not quarantine — proving the classifier's local-evidence check, not
    /// just its message-string, gates the decision.
    func testCheckViolationOnAHealthyBundleDoesNotQuarantine() async throws {
        let bundle = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let sourceCheckViolation = PostgrestError(
            code: "23514",
            message: "new row for relation \"climb_attempts\" violates check constraint \"climb_attempts_source_check\""
        )
        let uploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(stage: .climbAttempts, underlying: sourceCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        await queue.drain()

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(bundle.workout.id.uuidString).json"), "must stay pending, not be quarantined")
        XCTAssertFalse(remaining.contains("\(bundle.workout.id.uuidString).quarantine"))
    }

    /// The quarantine record preserves the original bundle plus which stage
    /// and reason it was quarantined for (Sol's stage-metadata requirement)
    /// — a quarantined item is not a silent drop.
    func testQuarantineRecordPreservesBundleStageReasonAndError() async throws {
        let poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
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
        XCTAssertEqual(record.bundle.attempts.first?.durationS, 0.0, "the poisoned attempt itself must round-trip")
        XCTAssertEqual(record.reason, .schemaRejection)
        XCTAssertEqual(record.stage, .climbAttempts)
        XCTAssertEqual(record.postgrestCode, "23514")
        XCTAssertEqual(record.errorMessage, durationCheckViolation.message)
        XCTAssertNil(record.attemptCount, "schema-rejection quarantines on the first attempt — no retry count to report")
        XCTAssertEqual(record.quarantinedAt, now)
    }

    /// A quarantined item is written to disk, not held in memory — a fresh
    /// `OfflineQueue` instance pointed at the same directory (simulating a
    /// relaunch) must still see it as quarantined, never re-attempt it as
    /// pending, and still report its count.
    func testQuarantineSurvivesRelaunch() async throws {
        let poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
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

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(transient.workout.id.uuidString).json"), "429 must stay pending, not be quarantined")
        XCTAssertFalse(remaining.contains("\(transient.workout.id.uuidString).quarantine"))
        // The retry ledger records the one failed attempt, well short of
        // the F3 threshold.
        XCTAssertTrue(remaining.contains("\(transient.workout.id.uuidString).retry"))
        let quarantined = await queue.quarantinedCount()
        let pending = await queue.pendingCount()
        XCTAssertEqual(quarantined, 0)
        XCTAssertEqual(pending, 2)
    }

    /// #475 F3: an error the classifier does NOT specifically recognize
    /// (unlike the one named check violation) must still not park the
    /// queue behind it forever. `climb_workouts_check` — a REAL, different
    /// permanent DB rejection (see the migration and the #475 review's own
    /// example) — retries `maxConsecutiveFailures - 1` times exactly like
    /// before this PR (still blocking a healthy item behind it — the
    /// unbounded-parking symptom, reproduced deliberately), then on the
    /// threshold-reaching pass is quarantined as `.stuckRetrying` and stops
    /// blocking the rest of the queue.
    func testUnrecognizedPermanentErrorEventuallyQuarantinesAsStuckRetrying() async throws {
        let stuck = makeBundle(id: UUID())
        let behindIt = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(stuck, createdAt: now)
        try writeFile(behindIt, createdAt: now.addingTimeInterval(1))

        let unrecognizedViolation = PostgrestError(
            code: "23514",
            message: "new row for relation \"climb_workouts\" violates check constraint \"climb_workouts_check\""
        )
        let uploader = ScriptedUploader(failing: [
            stuck.workout.id: StagedUploadError(stage: .climbWorkout, underlying: unrecognizedViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures - 1) {
            await queue.drain()
        }
        var remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).json"), "still short of the threshold")
        var uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(behindIt.workout.id), "still blocked below the threshold — reproducing the bounded parking symptom")

        // The threshold-reaching pass.
        await queue.drain()

        remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).quarantine"), "must be quarantined once the threshold is reached")
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).json"))
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).retry"), "the retry ledger is folded into the quarantine record, not left behind")

        uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(behindIt.workout.id), "the healthy item is freed the SAME pass the stuck one is quarantined")

        let data = try Data(contentsOf: pendingDir.appendingPathComponent("\(stuck.workout.id.uuidString).quarantine"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(QuarantinedUpload.self, from: data)
        XCTAssertEqual(record.reason, .stuckRetrying)
        XCTAssertEqual(record.attemptCount, QueueRetryPolicy.maxConsecutiveFailures)
    }

    /// A success clears any accumulated retry-failure count — a bundle
    /// that struggled for a few passes and then landed must not carry a
    /// stale ledger toward some future, unrelated failure streak.
    func testASuccessfulUploadClearsAPreviousRetryLedger() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)

        let failingUploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(
                stage: .session,
                underlying: HTTPError(data: Data(), response: HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 500, httpVersion: nil, headerFields: nil
                )!)
            ),
        ])
        let strugglingQueue = OfflineQueue(uploader: failingUploader, clock: FixedClock(now), baseDir: tempDir)
        await strugglingQueue.drain()
        XCTAssertTrue(try filesOnDisk().contains("\(bundle.workout.id.uuidString).retry"))

        let healthyUploader = ScriptedUploader(failing: [:])
        let recoveredQueue = OfflineQueue(uploader: healthyUploader, clock: FixedClock(now), baseDir: tempDir)
        await recoveredQueue.drain()

        XCTAssertFalse(try filesOnDisk().contains("\(bundle.workout.id.uuidString).retry"), "the ledger must not survive a successful upload")
    }

    /// #475 F4: quarantine is account-scoped the same way `pendingCount()`
    /// is. Without this, the moment quarantine is surfaced to the phone
    /// (#475 F1), Account A's stuck workout would read as "could not be
    /// uploaded" on Account B's phone for data B can't see or act on.
    func testQuarantinedCountIsAccountScoped() async throws {
        let poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)
        await queue.drain()

        let quarantinedUnderA = await queue.quarantinedCount()
        XCTAssertEqual(quarantinedUnderA, 1)

        let otherAccount = UUID()
        signIn(as: otherAccount)
        let quarantinedUnderB = await queue.quarantinedCount()
        XCTAssertEqual(quarantinedUnderB, 0, "Account A's stuck workout must not read as Account B's problem")

        // Never deleted by an account switch — still on disk, just not
        // counted for the account that can't act on it.
        XCTAssertTrue(try filesOnDisk().contains("\(poisoned.workout.id.uuidString).quarantine"))

        signIn(as: testUserId)
        let quarantinedBackUnderA = await queue.quarantinedCount()
        XCTAssertEqual(quarantinedBackUnderA, 1, "signing back in restores visibility of A's own stuck workout")
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
