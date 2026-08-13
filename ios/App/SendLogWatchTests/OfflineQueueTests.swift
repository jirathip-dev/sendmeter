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

    /// #529 F4: `makeBundle` above always coalesces a nil `enqueuedUserId`
    /// to `testUserId` — a convenience for the account-scoping tests
    /// elsewhere in this file, where "unspecified" means "the signed-in
    /// test account". That coalescing makes it unusable for pinning the
    /// LEGACY on-disk shape, where `enqueuedUserId` is genuinely nil. This
    /// is that genuine shape — the same one
    /// `WorkoutSaveBundleDecodeCompatTests` decodes from a frozen pre-#529
    /// file.
    private func makeLegacyBundle(id: UUID, attempts: [ClimbAttemptInsert] = []) -> WorkoutSaveBundle {
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
        return WorkoutSaveBundle(session: session, workout: workout, attempts: attempts, enqueuedUserId: nil)
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

    /// #600 fixture: a `.stuckRetrying` quarantine record written directly
    /// (same shape `drainPass` produces after 20 unrecognized rejections),
    /// so retry tests don't need 20 failing drain passes per record.
    @discardableResult
    private func writeStuckQuarantine(
        _ bundle: WorkoutSaveBundle,
        at date: Date,
        payloadDropped: Bool? = nil
    ) throws -> URL {
        try writeQuarantine(
            bundle,
            at: date,
            reason: .stuckRetrying,
            attemptCount: QueueRetryPolicy.maxConsecutiveFailures,
            payloadDropped: payloadDropped
        )
    }

    @discardableResult
    private func writeSchemaRejection(_ bundle: WorkoutSaveBundle, at date: Date) throws -> URL {
        try writeQuarantine(bundle, at: date, reason: .schemaRejection, attemptCount: nil, payloadDropped: nil)
    }

    @discardableResult
    private func writeQuarantine(
        _ bundle: WorkoutSaveBundle,
        at date: Date,
        reason: QuarantineReason,
        attemptCount: Int?,
        payloadDropped: Bool?
    ) throws -> URL {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = QueueQuarantineRecord(
            item: bundle,
            reason: reason,
            stage: .session,
            httpStatus: 400,
            postgrestCode: "PGRST205",
            errorMessage: "fixture failure",
            attemptCount: attemptCount,
            quarantinedAt: date,
            payloadDropped: payloadDropped
        )
        let url = pendingDir
            .appendingPathComponent(bundle.workout.id.uuidString)
            .appendingPathExtension("quarantine")
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
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

    /// 401/403 must NOT be quarantined (the taxonomy's conservative
    /// default): a retryable/ambiguous failure stops the pass exactly like
    /// the pre-#475 behavior, so a real outage doesn't burn through the
    /// rest of the queue out of order. 403 (unlike 429/5xx/408 — see F17,
    /// below) is a real, SERVER-evaluated ambiguous rejection, so it still
    /// advances the per-item retry ledger.
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
                    url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil
                )!)
            ),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(behindIt.workout.id), "a retryable failure must still stop the pass, not skip ahead")

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(transient.workout.id.uuidString).json"), "403 must stay pending, not be quarantined")
        XCTAssertFalse(remaining.contains("\(transient.workout.id.uuidString).quarantine"))
        // The retry ledger records the one failed attempt, well short of
        // the F3 threshold.
        XCTAssertTrue(remaining.contains("\(transient.workout.id.uuidString).retry"))
        let quarantined = await queue.quarantinedCount()
        let pending = await queue.pendingCount()
        XCTAssertEqual(quarantined, 0)
        XCTAssertEqual(pending, 2)
    }

    // MARK: #475 F17 — a transient status delivered as a non-JSON body must not burn the budget

    /// The exact F17 scenario: a sustained 5xx outage (a gateway's HTML
    /// error page during a Supabase incident — never decodes as
    /// `PostgrestError`, so it arrives as an `HTTPError`) must never
    /// quarantine a healthy workout, no matter how many passes it survives —
    /// same guarantee as the F11 stale-token/network-outage regressions,
    /// for the same reason: no server ever evaluated the bundle itself.
    func testASustained5xxNonJSONOutageNeverQuarantinesAHealthyWorkout() async throws {
        let healthy = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(healthy, createdAt: now)

        let uploader = ScriptedUploader(failing: [
            healthy.workout.id: StagedUploadError(
                stage: .session,
                underlying: HTTPError(data: "<html>502 Bad Gateway</html>".data(using: .utf8)!, response: HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 502, httpVersion: nil, headerFields: nil
                )!)
            ),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(healthy.workout.id.uuidString).json"), "must remain pending through any number of 5xx passes")
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).quarantine"), "a non-JSON 5xx body is an outage, not a verdict — must never quarantine")
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).retry"), "must not even accumulate a retry count")
        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 0)
    }

    /// 408/429 are the same shape as the 5xx case above — the taxonomy's own
    /// `.retry` doc comment already calls them transient alongside 5xx, so
    /// the ledger must treat them the same way.
    func test408And429AlsoNeverQuarantineAHealthyWorkout() async throws {
        for statusCode in [408, 429] {
            let healthy = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try writeFile(healthy, createdAt: now)

            let uploader = ScriptedUploader(failing: [
                healthy.workout.id: StagedUploadError(
                    stage: .session,
                    underlying: HTTPError(data: Data(), response: HTTPURLResponse(
                        url: URL(string: "https://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil
                    )!)
                ),
            ])
            let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

            for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
                await queue.drain()
            }

            let remaining = try filesOnDisk()
            XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).quarantine"), "status \(statusCode) must never quarantine")
            XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).retry"), "status \(statusCode) must not accumulate a retry count")

            try FileManager.default.removeItem(at: pendingDir.appendingPathComponent("\(healthy.workout.id.uuidString).json"))
        }
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
    /// stale ledger toward some future, unrelated failure streak. Uses 403
    /// (a real, SERVER-evaluated ambiguous rejection), not 500 — after F17,
    /// a 500 is transient and never writes a ledger entry in the first
    /// place, which would make this test's setup assert something false
    /// before even reaching what it's meant to check.
    func testASuccessfulUploadClearsAPreviousRetryLedger() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)

        let failingUploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(
                stage: .session,
                underlying: HTTPError(data: Data(), response: HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil
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

    // MARK: #475 F11 — the retry budget must not be burned by outages or stale tokens

    /// Permanent regression for the review's proof: a stale relayed access
    /// token (`.needsAuthRelay`) is a property of the PASS, not evidence
    /// about this bundle — the request was never evaluated under a valid
    /// credential. It must never advance the stuck-retry counter, no matter
    /// how many drains it survives, or a sustained #472-style stale-relay
    /// storm permanently abandons a perfectly healthy workout.
    func testAStaleAuthTokenNeverQuarantinesAHealthyWorkout() async throws {
        let healthy = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(healthy, createdAt: now)

        let staleToken = PostgrestError(code: "PGRST301", message: "No suitable key or wrong key type")
        let uploader = ScriptedUploader(failing: [
            healthy.workout.id: StagedUploadError(stage: .session, underlying: staleToken),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        // Comfortably past the F3 threshold — if the bug were still present
        // this would already have quarantined it several times over.
        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(healthy.workout.id.uuidString).json"), "must remain pending, no matter how many stale-token passes it survives")
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).quarantine"), "a stale token is not evidence about the bundle — must never quarantine")
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).retry"), "must not even accumulate a retry count — no verdict was ever reached")
        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 0)
    }

    /// Permanent regression, the review's second proof: a pure transport
    /// failure (no network) reaches no server at all and is equally not
    /// evidence about the bundle — must never quarantine, no matter how
    /// many outages it survives.
    func testANetworkOutageNeverQuarantinesAHealthyWorkout() async throws {
        let healthy = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(healthy, createdAt: now)

        let uploader = ScriptedUploader(failing: [
            healthy.workout.id: StagedUploadError(
                stage: .session,
                underlying: URLError(.notConnectedToInternet)
            ),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        for _ in 0..<(QueueRetryPolicy.maxConsecutiveFailures * 2) {
            await queue.drain()
        }

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(healthy.workout.id.uuidString).json"), "must remain pending through any number of outages")
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).quarantine"), "a transport failure reached no server — must never quarantine")
        XCTAssertFalse(remaining.contains("\(healthy.workout.id.uuidString).retry"), "must not even accumulate a retry count")
        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 0)
    }

    /// A REAL, recognized-as-a-rejection-but-not-the-schema-one error (the
    /// same `climb_workouts_check` example F3's own test uses) still counts
    /// and still quarantines at the threshold — F11 narrows WHAT counts, it
    /// does not defeat F3's original guarantee.
    func testARealButUnrecognizedRejectionStillQuarantinesAtTheThreshold() async throws {
        let stuck = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(stuck, createdAt: now)
        let unrecognizedViolation = PostgrestError(
            code: "23514",
            message: "new row for relation \"climb_workouts\" violates check constraint \"climb_workouts_check\""
        )
        let uploader = ScriptedUploader(failing: [
            stuck.workout.id: StagedUploadError(stage: .climbWorkout, underlying: unrecognizedViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        for _ in 0..<QueueRetryPolicy.maxConsecutiveFailures {
            await queue.drain()
        }

        XCTAssertTrue(try filesOnDisk().contains("\(stuck.workout.id.uuidString).quarantine"))
    }

    // MARK: #475 F12 — a `.stuckRetrying` bet gets one more chance

    func testStuckRetryingQuarantineIsNotResurrectedBeforeItsBackoffElapses() async throws {
        let stuck = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(stuck, createdAt: now)
        let unrecognizedViolation = PostgrestError(
            code: "23514",
            message: "new row for relation \"climb_workouts\" violates check constraint \"climb_workouts_check\""
        )
        let quarantiningUploader = ScriptedUploader(failing: [
            stuck.workout.id: StagedUploadError(stage: .climbWorkout, underlying: unrecognizedViolation),
        ])
        let firstQueue = OfflineQueue(uploader: quarantiningUploader, clock: FixedClock(now), baseDir: tempDir)
        for _ in 0..<QueueRetryPolicy.maxConsecutiveFailures {
            await firstQueue.drain()
        }
        XCTAssertTrue(try filesOnDisk().contains("\(stuck.workout.id.uuidString).quarantine"))

        // A NEW instance (simulating relaunch), clock just short of the
        // backoff, uploader now healthy — must NOT be resurrected yet.
        let healthyUploader = ScriptedUploader(failing: [:])
        let tooSoon = now.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS - 1)
        let secondQueue = OfflineQueue(uploader: healthyUploader, clock: FixedClock(tooSoon), baseDir: tempDir)
        await secondQueue.drain()

        XCTAssertTrue(try filesOnDisk().contains("\(stuck.workout.id.uuidString).quarantine"), "must stay quarantined before the backoff elapses")
        let uploaded = await healthyUploader.uploadedIds
        XCTAssertFalse(uploaded.contains(stuck.workout.id))
    }

    func testStuckRetryingQuarantineIsResurrectedAfterItsBackoffElapses() async throws {
        let stuck = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(stuck, createdAt: now)
        let unrecognizedViolation = PostgrestError(
            code: "23514",
            message: "new row for relation \"climb_workouts\" violates check constraint \"climb_workouts_check\""
        )
        let quarantiningUploader = ScriptedUploader(failing: [
            stuck.workout.id: StagedUploadError(stage: .climbWorkout, underlying: unrecognizedViolation),
        ])
        let firstQueue = OfflineQueue(uploader: quarantiningUploader, clock: FixedClock(now), baseDir: tempDir)
        for _ in 0..<QueueRetryPolicy.maxConsecutiveFailures {
            await firstQueue.drain()
        }
        XCTAssertTrue(try filesOnDisk().contains("\(stuck.workout.id.uuidString).quarantine"))

        // Whatever was wrong resolved itself (a server fix, an app update)
        // — the backoff has elapsed and this launch's uploader succeeds.
        let healthyUploader = ScriptedUploader(failing: [:])
        let due = now.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS)
        let secondQueue = OfflineQueue(uploader: healthyUploader, clock: FixedClock(due), baseDir: tempDir)
        await secondQueue.drain()

        let remaining = try filesOnDisk()
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).quarantine"), "resurrected, then uploaded successfully — no longer quarantined")
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).json"), "uploaded, not just restored to pending")
        let uploaded = await healthyUploader.uploadedIds
        XCTAssertTrue(uploaded.contains(stuck.workout.id), "resurrection must make it eligible in the SAME pass, not just the next one")
    }

    func testAResurrectedItemThatFailsAgainReEarnsAFreshRetryBudget() async throws {
        let stuck = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(stuck, createdAt: now)
        let unrecognizedViolation = PostgrestError(
            code: "23514",
            message: "new row for relation \"climb_workouts\" violates check constraint \"climb_workouts_check\""
        )
        let stillFailingUploader = ScriptedUploader(failing: [
            stuck.workout.id: StagedUploadError(stage: .climbWorkout, underlying: unrecognizedViolation),
        ])
        let firstQueue = OfflineQueue(uploader: stillFailingUploader, clock: FixedClock(now), baseDir: tempDir)
        for _ in 0..<QueueRetryPolicy.maxConsecutiveFailures {
            await firstQueue.drain()
        }
        XCTAssertTrue(try filesOnDisk().contains("\(stuck.workout.id.uuidString).quarantine"))

        // Resurrected, but the SAME unrecognized error keeps happening — a
        // single failed pass must not immediately re-quarantine it; the
        // budget starts over from zero.
        let due = now.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS)
        let secondQueue = OfflineQueue(uploader: stillFailingUploader, clock: FixedClock(due), baseDir: tempDir)
        await secondQueue.drain()

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).json"), "resurrected and pending again, not re-quarantined after one failure")
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).quarantine"))
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).retry"), "a fresh ledger, starting from 1")
    }

    // MARK: #472b — THE core fix: `.needsAuthRelay` must actually ask the phone

    /// The named acceptance criterion: a 401 drain must trigger a relay
    /// request — not just classify the failure and go quiet. Before this
    /// fix, `drainPass` recognized `.needsAuthRelay` and did nothing but
    /// `break`: retrying later with the same expired token just produces
    /// another 401 forever. This observes the ACTUAL CALL through the
    /// `sessionRelay` seam, not the classifier (which #475 already pins) —
    /// per the review correction, asserting only the classification would
    /// pass even with the pre-fix "recognize and do nothing" code.
    func testA401DrainTriggersASessionRelayRequest() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(
                stage: .session,
                underlying: HTTPError(data: Data(), response: HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil
                )!)
            ),
        ])
        let relay = RecordingSessionRelay()
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir, sessionRelay: relay)

        await queue.drain()

        let requestCount = await relay.requestCount
        XCTAssertEqual(requestCount, 1, "a 401 must ask the phone for a fresh relay, not just recognize and go quiet")
    }

    /// Same trigger, for PostgREST's own JWT-rejection code — the shape a
    /// real 401 actually arrives as in this project's production PostgREST
    /// (#475 F2).
    func testAPGRST301DrainTriggersASessionRelayRequest() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let staleToken = PostgrestError(code: "PGRST301", message: "No suitable key or wrong key type")
        let uploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(stage: .session, underlying: staleToken),
        ])
        let relay = RecordingSessionRelay()
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir, sessionRelay: relay)

        await queue.drain()

        let requestCount = await relay.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    /// A retryable-but-not-auth failure must NOT ask for a relay — only
    /// `.needsAuthRelay` should trigger this, or every ordinary outage would
    /// also spam the phone.
    func testANonAuthFailureDoesNotTriggerASessionRelayRequest() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(stage: .session, underlying: URLError(.notConnectedToInternet)),
        ])
        let relay = RecordingSessionRelay()
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir, sessionRelay: relay)

        await queue.drain()

        let requestCount = await relay.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    // MARK: #472b — bounded backoff retry with no foreground event

    /// The named acceptance criterion: a failed drain must retry later with
    /// NO foreground event and no accepted relay — this drives the actual
    /// PRODUCTION scheduling path (`OfflineQueue.drain()` → `scheduler`),
    /// not a standalone delay function. The scheduler double captures the
    /// scheduled action instead of sleeping for real, then the test fires it
    /// itself to simulate the timer elapsing with nothing else involved.
    func testAFailedDrainRetriesLaterWithNoForegroundEventAndThenSucceeds() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)

        // First attempt fails on a transient, ambiguous rejection (still
        // ledger-eligible, unlike #475 F11/F17's excluded cases — irrelevant
        // to what's under test here, which is purely "does a retry get
        // scheduled and fire").
        let uploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(
                stage: .session,
                underlying: HTTPError(data: Data(), response: HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil
                )!)
            ),
        ])
        let scheduler = RecordingScheduler()
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir, scheduler: scheduler)

        await queue.drain()

        var scheduledCount = scheduler.scheduledCount
        XCTAssertEqual(scheduledCount, 1, "a stalled drain must schedule exactly one backoff retry")

        // Whatever was wrong resolves itself before the timer fires — no
        // foreground, no enqueue, no accepted relay touches this queue at
        // any point from here on.
        await uploader.stopFailing()

        await scheduler.fireOldest()

        let remaining = try filesOnDisk()
        XCTAssertFalse(remaining.contains("\(bundle.workout.id.uuidString).json"), "the scheduled retry must have drained and uploaded the item")
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(bundle.workout.id))

        // A pass that completes cleanly must not leave another retry armed.
        scheduledCount = scheduler.scheduledCount
        XCTAssertEqual(scheduledCount, 0, "a successful pass must not schedule a further retry")
    }

    /// A pass that stalls repeatedly keeps rescheduling — no give-up state.
    /// Mirrors the F11-style "survives any number of passes" regressions:
    /// this queue never stops trying just because it has failed before.
    func testARepeatedlyFailingDrainKeepsSchedulingFurtherRetries() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(stage: .session, underlying: URLError(.notConnectedToInternet)),
        ])
        let scheduler = RecordingScheduler()
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir, scheduler: scheduler)

        await queue.drain()
        XCTAssertEqual(scheduler.scheduledCount, 1)

        await scheduler.fireOldest() // still failing — the retry itself calls drain() again
        XCTAssertEqual(scheduler.scheduledCount, 1, "still failing, but a NEW retry must be armed — never zero")

        await scheduler.fireOldest()
        XCTAssertEqual(scheduler.scheduledCount, 1, "third stall in a row — still rescheduling, no give-up state")
    }

    /// A drain that has nothing eligible to upload (an empty queue, or
    /// everything belongs to a different signed-in account) is not a stall —
    /// it must not arm the backoff timer.
    func testAnEmptyDrainDoesNotScheduleARetry() async throws {
        let scheduler = RecordingScheduler()
        let queue = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir,
            scheduler: scheduler
        )

        await queue.drain()

        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    // MARK: #472b — last successful sync / staleness surfacing

    func testLastSuccessfulSyncIsNilBeforeAnyUploadEverLands() async throws {
        let queue = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir
        )
        let lastSync = await queue.lastSuccessfulSyncAt()
        XCTAssertNil(lastSync, "unknown must not read as a fresh sync")
    }

    /// Recorded on success, off the clock (not the wall clock) so it's
    /// deterministic, and it must survive a fresh actor instance over the
    /// same directory (a relaunch) — an in-memory-only timestamp would lose
    /// exactly the information a long-stalled queue needs to report.
    func testLastSuccessfulSyncIsRecordedOnSuccessAndSurvivesRelaunch() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let firstLaunch = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir
        )
        await firstLaunch.drain()
        let recordedAtFirstLaunch = await firstLaunch.lastSuccessfulSyncAt()
        XCTAssertEqual(recordedAtFirstLaunch, now)

        let secondLaunch = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]),
            clock: FixedClock(now.addingTimeInterval(3600)),
            baseDir: tempDir
        )
        let recordedAfterRelaunch = await secondLaunch.lastSuccessfulSyncAt()
        XCTAssertEqual(recordedAfterRelaunch, now, "must survive a fresh actor instance over the same directory")
    }

    /// Review F20: unlike `pendingCount()`/`quarantinedCount()`, which
    /// re-derive account scoping from each on-disk item's own
    /// `enqueuedUserId` on every read, the last-sync marker is a SINGLE
    /// global file — without its own account stamp it would keep reporting
    /// account A's timestamp forever, even after the phone switches to
    /// account B and B's own queue has never synced at all. Same failure
    /// shape as #158/#475 F4, one instance later.
    func testLastSuccessfulSyncDoesNotLeakAcrossAccounts() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let queue = OfflineQueue(uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir)
        await queue.drain()
        let syncedUnderA = await queue.lastSuccessfulSyncAt()
        XCTAssertEqual(syncedUnderA, now, "account A sees its own sync")

        let otherAccount = UUID()
        signIn(as: otherAccount)
        let syncedUnderB = await queue.lastSuccessfulSyncAt()
        XCTAssertNil(syncedUnderB, "account B must not see account A's timestamp as if it described B's own queue")

        signIn(as: testUserId)
        let syncedBackUnderA = await queue.lastSuccessfulSyncAt()
        XCTAssertEqual(syncedBackUnderA, now, "signing back in as A restores visibility of A's own sync")
    }

    // MARK: #472b review F18 — "retrying automatically" must reflect a real armed backoff

    func testIsRetryScheduledIsFalseWhenNoDrainHasEverStalled() async throws {
        let queue = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir
        )
        let armed = await queue.isRetryScheduled()
        XCTAssertFalse(armed)
    }

    func testIsRetryScheduledIsTrueAfterAStalledDrain() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            bundle.workout.id: StagedUploadError(stage: .session, underlying: URLError(.notConnectedToInternet)),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir, scheduler: RecordingScheduler())

        await queue.drain()

        let armed = await queue.isRetryScheduled()
        XCTAssertTrue(armed)
    }

    /// The exact F18(a) scenario the reviewer reproduced: a signed-out
    /// watch has a pending item (`pendingCount()` deliberately widens to
    /// count it, #189), but `shouldDrain` returns `false` for every file
    /// when nobody is signed in — `drainPass` `continue`s past it rather
    /// than attempting (and possibly stalling on) it, so NO retry is ever
    /// armed. The UI must not claim one is.
    func testIsRetryScheduledStaysFalseWhenSignedOutEvenWithAPendingItem() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(bundle, createdAt: now)
        WatchSessionStore.shared.clear() // signed out
        let queue = OfflineQueue(uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir)

        await queue.drain()

        let armed = await queue.isRetryScheduled()
        XCTAssertFalse(armed, "signed out — drainPass never attempts the item, so nothing can stall")
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 1, "the item is still reported pending (#189) — only the retry-armed claim is false")
    }

    // MARK: #481 / #491 review F1 — quarantine sheds the raw trace, keeps everything user-visible

    /// Quarantine is retained indefinitely (nothing prunes it, #475 F8), and
    /// `workout.raw` is the 1Hz debug trace — hundreds of KB per workout
    /// with keepRawTrace on. #481's named cheap win: strip it BEFORE the
    /// forever-write. Every user-visible field must survive the strip.
    func testQuarantineStripsTheRawTraceButKeepsEveryUserVisibleField() async throws {
        var poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
        poisoned.workout.raw = [[0, 12.5, 0.4, 140], [1, 12.6, 0.5, 141]]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        await queue.drain()

        let data = try Data(contentsOf: pendingDir.appendingPathComponent("\(poisoned.workout.id.uuidString).quarantine"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(QueueQuarantineRecord<WorkoutSaveBundle>.self, from: data)
        XCTAssertNil(record.item.workout.raw, "the debug trace must not be stored forever")
        XCTAssertEqual(record.payloadDropped, true, "the strip is recorded honestly on the record")
        XCTAssertEqual(record.item.workout.id, poisoned.workout.id)
        XCTAssertEqual(record.item.attempts.count, 1, "attempts — the training data — survive")
        XCTAssertEqual(record.item.session.id, poisoned.session.id, "the session row survives")
        XCTAssertEqual(record.reason, .schemaRejection)
    }

    /// A bundle with no trace to shed quarantines exactly as before — no
    /// strip, no `payloadDropped` claim about a payload that never existed.
    func testQuarantineOfATracelessBundleDoesNotClaimAStrip() async throws {
        let poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        await queue.drain()

        let data = try Data(contentsOf: pendingDir.appendingPathComponent("\(poisoned.workout.id.uuidString).quarantine"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(QueueQuarantineRecord<WorkoutSaveBundle>.self, from: data)
        XCTAssertNil(record.payloadDropped)
    }

    // MARK: #491 — on-disk compatibility with pre-consolidation quarantine records

    /// The generic engine reads/writes `QueueQuarantineRecord<Item>`, whose
    /// on-disk shape must stay byte-compatible with the `QuarantinedUpload`
    /// records #475 builds already wrote to real devices (same field names,
    /// and the item under the legacy "bundle" key). Written HERE through the
    /// legacy type itself — which is also why that type deliberately stays
    /// in Models.swift — then read back through the real engine paths: the
    /// count classifies it, and the F12 resurrection re-pends it.
    func testAPre491QuarantineRecordStillCountsAndResurrects() async throws {
        let bundle = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacyRecord = QuarantinedUpload(
            bundle: bundle,
            reason: .stuckRetrying,
            stage: .session,
            httpStatus: nil,
            postgrestCode: "P0001",
            errorMessage: "raise_exception",
            attemptCount: QueueRetryPolicy.maxConsecutiveFailures,
            quarantinedAt: now
        )
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir
            .appendingPathComponent(bundle.workout.id.uuidString)
            .appendingPathExtension("quarantine")
        try encoder.encode(legacyRecord).write(to: url, options: .atomic)

        let queue = OfflineQueue(uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir)
        let counted = await queue.quarantinedCount()
        XCTAssertEqual(counted, 1, "a legacy record must decode — an unreadable one would still count, but as the cautious schema-like default")

        // Beyond the F12 backoff, a fresh launch must be able to read the
        // legacy record well enough to resurrect and upload its bundle.
        let uploader = ScriptedUploader(failing: [:])
        let laterQueue = OfflineQueue(
            uploader: uploader,
            clock: FixedClock(now.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS + 1)),
            baseDir: tempDir
        )
        await laterQueue.drain()
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(bundle.workout.id), "the legacy-quarantined workout must come back to life and land")
        XCTAssertFalse(try filesOnDisk().contains("\(bundle.workout.id.uuidString).quarantine"))
    }

    // MARK: #599 — the quarantine diagnostics surface

    /// The diagnostics read must not materialize the item payload: a record
    /// whose stored item would FAIL a full `QueueQuarantineRecord` decode
    /// (this handcrafted "bundle" carries only the synthesized
    /// `enqueuedUserId` key, nothing else) still lists every header field —
    /// the probe never reaches into the item. This is the #599 acceptance
    /// criterion for the header-only read, pinned the same way
    /// `quarantinedCount`'s F2 probe is.
    func testQuarantinedDiagnosticsReadHeaderFieldsWithoutDecodingThePayload() async throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let longError = String(repeating: "y", count: 300)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let json = """
        {"bundle":{"enqueuedUserId":"\(testUserId.uuidString)"},
         "reason":"stuckRetrying","stage":"session","httpStatus":400,
         "postgrestCode":"PGRST205","errorMessage":"\(longError)",
         "attemptCount":20,"quarantinedAt":"\(formatter.string(from: now))","payloadDropped":true}
        """
        let url = pendingDir
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("quarantine")
        try Data(json.utf8).write(to: url, options: .atomic)

        let queue = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir
        )
        let diagnostics = await queue.quarantinedDiagnostics()
        XCTAssertEqual(diagnostics.count, 1)
        guard case .record(let item) = diagnostics[0] else {
            return XCTFail("expected a record entry, got \(diagnostics[0])")
        }
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.reason, .stuckRetrying)
        XCTAssertEqual(item.stage, .session)
        XCTAssertEqual(item.httpStatus, 400)
        XCTAssertEqual(item.postgrestCode, "PGRST205")
        XCTAssertEqual(item.errorMessage, QuarantineDiagnostics.truncatedErrorMessage(longError))
        XCTAssertEqual(item.attemptCount, 20)
        XCTAssertEqual(item.quarantinedAt, now)
        XCTAssertEqual(item.payloadDropped, true)

        // The header-only read is what served the fields above: the SAME file
        // cannot decode as a full record.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(
            try? decoder.decode(QueueQuarantineRecord<WorkoutSaveBundle>.self, from: Data(contentsOf: url)),
            "the fixture must be undecodable as a full record, or this test proves nothing about the probe"
        )
        // And the count agrees — same probe, same file.
        let counted = await queue.quarantinedCount()
        XCTAssertEqual(counted, 1)
    }

    /// The real quarantine path (a poisoned bundle drained to
    /// `.schemaRejection`) must surface the actual recorded fields — stage,
    /// PostgREST code, message, the #481 strip — so the user can see exactly
    /// what the phone's "will not retry" banner is about.
    func testQuarantinedDiagnosticsReportTheRealQuarantineFields() async throws {
        var poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
        poisoned.workout.raw = [[0, 12.5, 0.4, 140]]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)
        await queue.drain()

        let diagnostics = await queue.quarantinedDiagnostics()
        XCTAssertEqual(diagnostics.count, 1)
        guard case .record(let item) = diagnostics[0] else {
            return XCTFail("expected a record entry, got \(diagnostics[0])")
        }
        XCTAssertEqual(item.id, poisoned.workout.id)
        XCTAssertEqual(item.reason, .schemaRejection)
        XCTAssertEqual(item.stage, .climbAttempts)
        XCTAssertNil(item.httpStatus, "a PostgrestError carries no HTTP status")
        XCTAssertEqual(item.postgrestCode, "23514")
        XCTAssertEqual(item.errorMessage, durationCheckViolation.message)
        XCTAssertNil(item.attemptCount, "schema rejection quarantines on the first attempt")
        XCTAssertEqual(item.payloadDropped, true, "workouts shed `raw` at quarantine time (#481)")
    }

    /// An unreadable `.quarantine` file must stay VISIBLE — listed as
    /// unreadable with its file-derived id — and must stay on disk (#287),
    /// never deleted by a read.
    func testAnUnreadableQuarantineFileIsListedAsUnreadableAndRetained() async throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try Data("not a quarantine record".utf8).write(
            to: pendingDir.appendingPathComponent("\(id.uuidString).quarantine"),
            options: .atomic
        )
        let queue = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]),
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir
        )

        let diagnostics = await queue.quarantinedDiagnostics()
        XCTAssertEqual(diagnostics, [.unreadable(id: id)])
        XCTAssertTrue(try filesOnDisk().contains("\(id.uuidString).quarantine"), "#287: retained, never deleted by the read")
        let counted = await queue.quarantinedCount()
        XCTAssertEqual(counted, 1, "still counted the same cautious way as before")

        // An unreadable record can't be attributed to any account, so it is
        // visible to whoever is signed in — same rule the count already
        // applies ("retained and reported").
        signIn(as: UUID())
        let underOtherAccount = await queue.quarantinedDiagnostics()
        XCTAssertEqual(underOtherAccount.count, 1)
    }

    /// The diagnostics list is account-scoped exactly like `quarantinedCount`
    /// (#475 F4): Account A's stuck upload must not read as B's diagnostics.
    func testQuarantinedDiagnosticsAreAccountScoped() async throws {
        let poisoned = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(poisoned, createdAt: now)
        let uploader = ScriptedUploader(failing: [
            poisoned.workout.id: StagedUploadError(stage: .climbAttempts, underlying: durationCheckViolation),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)
        await queue.drain()
        let underA = await queue.quarantinedDiagnostics()
        XCTAssertEqual(underA.count, 1)

        signIn(as: UUID())
        let underB = await queue.quarantinedDiagnostics()
        XCTAssertEqual(
            underB.count,
            0,
            "Account A's stuck upload must not read as Account B's diagnostics"
        )
        XCTAssertTrue(try filesOnDisk().contains("\(poisoned.workout.id.uuidString).quarantine"), "never deleted by the account switch")

        signIn(as: testUserId)
        let backUnderA = await queue.quarantinedDiagnostics()
        XCTAssertEqual(backUnderA.count, 1, "signing back in restores visibility")
    }

    /// The diagnostics list is ordered oldest-first, matching the queues'
    /// own drain order — the item stuck the longest is the one to read first.
    func testQuarantinedDiagnosticsAreOrderedOldestFirst() async throws {
        func quarantineAt(_ date: Date, id: UUID) async throws {
            try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let record = QueueQuarantineRecord(
                item: makeBundle(id: id),
                reason: .stuckRetrying,
                stage: nil,
                httpStatus: nil,
                postgrestCode: "P0001",
                errorMessage: "raise_exception",
                attemptCount: QueueRetryPolicy.maxConsecutiveFailures,
                quarantinedAt: date,
                payloadDropped: nil
            )
            let url = pendingDir
                .appendingPathComponent(id.uuidString)
                .appendingPathExtension("quarantine")
            try encoder.encode(record).write(to: url, options: .atomic)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = UUID()
        let newer = UUID()
        try await quarantineAt(now, id: older)
        try await quarantineAt(now.addingTimeInterval(3600), id: newer)

        let queue = OfflineQueue(uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir)
        let diagnostics = await queue.quarantinedDiagnostics()
        XCTAssertEqual(diagnostics.count, 2)
        guard case .record(let first) = diagnostics[0], case .record(let second) = diagnostics[1] else {
            return XCTFail("expected two record entries")
        }
        XCTAssertEqual(first.id, older, "oldest first")
        XCTAssertEqual(second.id, newer)
    }

    // MARK: #600 — manual retry of quarantined items

    /// The named acceptance criterion: "Retry stuck uploads" restores every
    /// retryable record to the pending rotation and drains it in the SAME
    /// call — the user standing there with working network doesn't wait for
    /// the 7-day backoff. `.schemaRejection` is left quarantined, never
    /// offered as a retry.
    func testRetryQuarantinedItemsRestoresStuckRecordsAndDrainsThem() async throws {
        let stuck = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
        let permanent = makeBundle(id: UUID(), attempts: [makePoisonedAttempt(workoutId: UUID())])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now)
        try writeSchemaRejection(permanent, at: now.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        let restored = await queue.retryQuarantinedItems()
        XCTAssertEqual(restored, 1, "exactly the retryable record is restored")

        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(stuck.workout.id), "the restored item is drained immediately")
        XCTAssertFalse(uploaded.contains(permanent.workout.id), "a proven-permanent rejection is never retried")

        let remaining = try filesOnDisk()
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).quarantine"))
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).json"), "restored item uploaded, not just re-pended")
        XCTAssertTrue(remaining.contains("\(permanent.workout.id.uuidString).quarantine"), "the schema-rejected record stays quarantined")

        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 1)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    /// A retry whose restored item fails again does NOT lose it — it goes
    /// back through the ordinary pipeline (pending, retry ledger, eventual
    /// quarantine again at the threshold). The retry never deletes a queued
    /// item on failure (CLAUDE.md #273).
    func testARestoredItemThatFailsAgainStaysPending() async throws {
        let stuck = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now)
        // A real, SERVER-evaluated ambiguous rejection (403) — unlike a
        // transport failure (which per F11 never writes a ledger), a 403
        // proves the restored item is back on the ordinary retry pipeline.
        let uploader = ScriptedUploader(failing: [
            stuck.workout.id: StagedUploadError(
                stage: .session,
                underlying: HTTPError(data: Data(), response: HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil
                )!)
            ),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        let restored = await queue.retryQuarantinedItems()
        XCTAssertEqual(restored, 1)

        let remaining = try filesOnDisk()
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).quarantine"))
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).json"), "failed retry keeps the item pending — never deleted")
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).retry"), "a server verdict starts a fresh retry ledger")
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 1, "still reported as pending — it IS on the upload path again")
    }

    /// Crash-safe in the durable direction: if the pending write is refused,
    /// the quarantine record must survive untouched — the item is never
    /// risked on an unconfirmed write (the exact inverse of `quarantine()`).
    func testRetryIsCrashSafeWhenThePendingWriteFails() async throws {
        let stuck = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now)
        let queue = OfflineQueue(
            uploader: ScriptedUploader(failing: [:]),
            clock: FixedClock(now),
            baseDir: tempDir,
            fileIO: AlwaysRefusingFileIO()
        )

        let restored = await queue.retryQuarantinedItems()
        XCTAssertEqual(restored, 0, "a refused write restores nothing")

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).quarantine"), "the record survives a refused write")
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).json"), "no half-restored pending file")
        let quarantined = await queue.quarantinedCount()
        XCTAssertEqual(quarantined, 1, "still counted, still eligible for a later retry")
    }

    /// An undecodable `.quarantine` file is skipped and RETAINED by the
    /// retry — never deleted, never rewritten (#287), even though it blocks
    /// nothing (the readable record next to it is restored normally).
    func testRetrySkipsAndRetainsAnUndecodableRecord() async throws {
        let stuck = makeBundle(id: UUID())
        let garbageId = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try Data("not a record".utf8).write(
            to: pendingDir.appendingPathComponent("\(garbageId.uuidString).quarantine"),
            options: .atomic
        )
        let queue = OfflineQueue(uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir)

        let restored = await queue.retryQuarantinedItems()
        XCTAssertEqual(restored, 1, "the readable record is restored; the undecodable one is not")
        XCTAssertTrue(try filesOnDisk().contains("\(garbageId.uuidString).quarantine"), "an undecodable record is never deleted")
    }

    /// A manual retry respects the same ownership the automatic drain does:
    /// account A's quarantined item is not restored while B is signed in.
    func testRetryRespectsAccountOwnership() async throws {
        let stuck = makeBundle(id: UUID(), enqueuedUserId: testUserId)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now)
        signIn(as: UUID())
        let queue = OfflineQueue(uploader: ScriptedUploader(failing: [:]), clock: FixedClock(now), baseDir: tempDir)

        let restored = await queue.retryQuarantinedItems()
        XCTAssertEqual(restored, 0, "A's record must not be restored under B")
        XCTAssertTrue(try filesOnDisk().contains("\(stuck.workout.id.uuidString).quarantine"))

        signIn(as: testUserId)
        let restoredByOwner = await queue.retryQuarantinedItems()
        XCTAssertEqual(restoredByOwner, 1, "its owner can retry it")
    }

    /// #599/#600 review finding 1: the `|| currentUserId == nil` escape hatch
    /// belongs to the COUNTING sweeps (so a signed-out watch doesn't report
    /// its queues as zero) and must never ride into a MUTATION path. A
    /// signed-out retry restores NOTHING — every record's forensic header
    /// (stage, httpStatus, postgrestCode, errorMessage, attemptCount,
    /// quarantinedAt) would vanish the moment it became a plain pending
    /// .json, and `drainPass` wouldn't upload it anyway.
    func testRetryRestoresNothingWhileSignedOut() async throws {
        let stuck = makeBundle(id: UUID(), enqueuedUserId: testUserId)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now)
        WatchSessionStore.shared.clear() // signed out

        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)
        let restored = await queue.retryQuarantinedItems()
        XCTAssertEqual(restored, 0, "a signed-out retry must restore nothing")

        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(stuck.workout.id.uuidString).quarantine"), "the record and its forensics must survive untouched")
        XCTAssertFalse(remaining.contains("\(stuck.workout.id.uuidString).json"), "no half-restored pending file")
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.isEmpty)
    }

    /// The retry clears any leftover `<uuid>.retry` ledger so the restored
    /// item starts with a fresh budget — and a transport failure during the
    /// follow-up drain does not immediately re-earn one (the F11 rule: no
    /// server verdict, no ledger entry).
    func testRetryClearsTheLeftoverRetryLedger() async throws {
        let stuck = makeBundle(id: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now)
        try Data("stale".utf8).write(
            to: pendingDir.appendingPathComponent("\(stuck.workout.id.uuidString).retry"),
            options: .atomic
        )
        let uploader = ScriptedUploader(failing: [
            stuck.workout.id: StagedUploadError(stage: .session, underlying: URLError(.notConnectedToInternet)),
        ])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        _ = await queue.retryQuarantinedItems()

        XCTAssertFalse(try filesOnDisk().contains("\(stuck.workout.id.uuidString).retry"), "the restored item starts with a fresh budget")
    }

    /// A payload stripped at quarantine time (workouts shed `raw`, #481)
    /// restores without it and must not block the retry — the item uploads
    /// its real summary stats, never described as a full restore (the
    /// diagnostics surface carries the `payloadDropped` provenance).
    func testRetryRestoresAStrippedPayloadItemAsIs() async throws {
        var stuck = makeBundle(id: UUID(), attempts: [makeHealthyAttempt(workoutId: UUID())])
        stuck.workout.raw = nil // as stripped by `stripsPayloadOnQuarantine`
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeStuckQuarantine(stuck, at: now, payloadDropped: true)

        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        let restored = await queue.retryQuarantinedItems()
        XCTAssertEqual(restored, 1, "a stripped payload never blocks the retry")

        let uploaded = await uploader.uploadedBundles
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertNil(uploaded[0].workout.raw, "the restored item is exactly the stripped copy — summary data only")
        XCTAssertEqual(uploaded[0].workout.id, stuck.workout.id)
    }

    // MARK: #472b review F21 — a dropped scheduler callback must not disarm the backoff forever
    /// Exercises the REAL production `TaskDrainScheduler`, not a test
    /// double — the only test in this file that does, closing the "never
    /// exercised end-to-end" gap the review noted. An earlier version
    /// returned early when its internal sleep `Task` was already
    /// cancelled, without ever running the action; nothing currently
    /// cancels this unstructured `Task`, but if anything ever did, that
    /// early return would have disarmed `OfflineQueue`'s backoff for the
    /// rest of the process's lifetime. The fixed scheduler always runs the
    /// action.
    func testTaskDrainSchedulerActuallyRunsTheAction() async throws {
        let scheduler = TaskDrainScheduler()
        let ran = RanFlag()

        scheduler.scheduleRetry(after: 0.01, RetryAction { await ran.markRan() })

        try await Task.sleep(for: .seconds(1))
        let didRun = await ran.ran
        XCTAssertTrue(didRun, "the scheduled action must actually run after the delay")
    }

    // MARK: #529 slice 1 — workout ownership: A → signed-out/B holds an A-owned save

    /// The named acceptance criterion: a bundle stamped with account A's id
    /// at `WorkoutManager.start()` (via `Repo.makeSaveBundle`) must never
    /// upload while a DIFFERENT account is the one currently signed in — it
    /// is held on disk, not silently rebound to whoever is active now, and
    /// it does not count as B's pending work either. Once A is signed back
    /// in, the very same held item drains normally — this is also the
    /// "retry with a held owner" case: nothing special happens on the
    /// account's return, the ordinary drain loop just becomes eligible again.
    func testAnOwnedBundleIsHeldWhileADifferentAccountIsActiveAndDrainsOnceItsOwnerReturns() async throws {
        let ownerA = testUserId
        let otherAccountB = UUID()
        let bundle = makeBundle(id: UUID(), enqueuedUserId: ownerA)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Written directly to disk (the established pattern in this file,
        // e.g. `testPermanentErrorItemDoesNotBlockAHealthyItemBehindIt`)
        // rather than through `queue.enqueue(bundle)` — `enqueue`'s success
        // path fires an un-awaited `Task { await drain() }` internally,
        // whose scheduling this test cannot control; a bundle already
        // sitting on disk when the queue is constructed removes that race
        // entirely and matches what a real relaunch/foreground drain sees.
        try writeFile(bundle, createdAt: now)
        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)

        // B is active when the watch next drains — the exact A →
        // signed-out → B shape: A started and owns the run, but nobody
        // (or somebody else) is signed in by the time it's attempted.
        signIn(as: otherAccountB)
        await queue.drain()
        var uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(bundle.workout.id), "an A-owned bundle must never upload while B is the active account")
        XCTAssertTrue(try filesOnDisk().contains("\(bundle.workout.id.uuidString).json"), "held, not lost — the file stays pending on disk")

        let pendingUnderB = await queue.pendingCount()
        XCTAssertEqual(pendingUnderB, 0, "must not read as B's pending work — B can neither see nor act on A's data")

        // A signs back in — no special "resume" call, just an ordinary drain.
        signIn(as: ownerA)
        let pendingUnderA = await queue.pendingCount()
        XCTAssertEqual(pendingUnderA, 1, "signing back in as the owner restores visibility of the held item")

        await queue.drain()
        uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(bundle.workout.id), "must drain normally once its real owner is active again")
    }

    /// A held item must never be silently rebound to B either — draining
    /// several times while B stays signed in must not eventually give up and
    /// upload it under B, and it must not be quarantined (no verdict was
    /// ever reached; it was never even attempted).
    func testAnOwnedBundleIsNeverReboundToADifferentAccountAcrossRepeatedDrains() async throws {
        let ownerA = testUserId
        let otherAccountB = UUID()
        let bundle = makeBundle(id: UUID(), enqueuedUserId: ownerA)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(uploader: uploader, clock: FixedClock(now), baseDir: tempDir)
        signIn(as: otherAccountB)
        await queue.enqueue(bundle)

        for _ in 0..<5 {
            await queue.drain()
        }

        let uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(bundle.workout.id), "must never be uploaded under B, no matter how many drains it survives")
        let remaining = try filesOnDisk()
        XCTAssertTrue(remaining.contains("\(bundle.workout.id.uuidString).json"), "still pending — a held item is not an error")
        XCTAssertFalse(remaining.contains("\(bundle.workout.id.uuidString).quarantine"), "held items were never attempted, so there is nothing to quarantine")
    }

    /// `UploadQueueEngine.enqueue`'s nil→current-user fallback (issue #158)
    /// must survive for LEGACY on-disk items — a bundle that genuinely has
    /// no stamped owner is trusted to whoever is signed in at enqueue time,
    /// same as before this fix. #529 F4: this must use `makeLegacyBundle`,
    /// not `makeBundle(enqueuedUserId: nil)` — the latter's `?? testUserId`
    /// coalescing already stamps `testUserId` before `enqueue` ever runs, so
    /// the old version of this test passed even with the fallback deleted
    /// entirely. Asserting the stamp actually CHANGED (not merely equals the
    /// end state) is what makes that regression impossible to miss again.
    func testEnqueueStampsTheCurrentAccountOnlyForALegacyNilOwnerBundle() async throws {
        let bundle = makeLegacyBundle(id: UUID())
        XCTAssertNil(bundle.enqueuedUserId, "sanity: this fixture must genuinely be nil going in, or the assertion below proves nothing")
        // A non-destructive, unclassifiable failure (matches
        // `testANetworkOutageNeverQuarantinesAHealthyWorkout`'s pattern) —
        // this test asserts on the PERSISTED shape, not on upload outcome,
        // so the background `Task { await drain() }` `enqueue` fires on
        // success must not be free to race ahead and delete the file (on a
        // real network) before the read below runs.
        let uploader = ScriptedUploader(failing: [bundle.workout.id: URLError(.notConnectedToInternet)])
        let queue = OfflineQueue(
            uploader: uploader,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir
        )

        _ = await queue.enqueue(bundle)

        let data = try Data(contentsOf: pendingDir.appendingPathComponent("\(bundle.workout.id.uuidString).json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(WorkoutSaveBundle.self, from: data)
        XCTAssertEqual(persisted.enqueuedUserId, testUserId, "a legacy nil-owner item must be STAMPED to the currently signed-in account by enqueue, not merely left as whatever it already was")
    }

    /// The other half: a NEWLY built bundle that already carries an explicit
    /// owner (as every production `Repo.makeSaveBundle` call now must) must
    /// never take the nil-owner fallback path — `enqueue` must not overwrite
    /// it with whoever happens to be signed in at persist time, even when
    /// that differs from the stamped owner.
    func testEnqueueNeverOverwritesAnExplicitlyStampedOwner() async throws {
        let ownerA = UUID()
        let currentlySignedIn = testUserId
        XCTAssertNotEqual(ownerA, currentlySignedIn)
        let bundle = makeBundle(id: UUID(), enqueuedUserId: ownerA)
        // Same reasoning as the legacy test above: this asserts on the
        // PERSISTED shape, so the background drain the successful path
        // would trigger must not be free to race the file away first.
        let uploader = ScriptedUploader(failing: [bundle.workout.id: URLError(.notConnectedToInternet)])
        let queue = OfflineQueue(
            uploader: uploader,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir
        )

        _ = await queue.enqueue(bundle)

        let data = try Data(contentsOf: pendingDir.appendingPathComponent("\(bundle.workout.id.uuidString).json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(WorkoutSaveBundle.self, from: data)
        XCTAssertEqual(persisted.enqueuedUserId, ownerA, "an explicitly captured owner must never be replaced by whoever is signed in at enqueue time")
    }

    // MARK: #529 F2 — the direct-upload fallback must respect ownership too

    /// `drainPass` is the only OTHER upload path, and it gates every attempt
    /// on `shouldDrain` — `enqueue`'s `.uploadDirect` fallback (taken when
    /// persistence itself just failed) had no such guard at all. An A-owned
    /// bundle that can't be written to disk while B is active must not
    /// upload straight to B's token as a "better than nothing" fallback —
    /// persistence already failed, and uploading under the wrong account
    /// isn't a safe substitute, it's the exact misattribution this slice
    /// exists to close. Must report an honest `.lost` (#264): nothing
    /// completed, and nothing should claim otherwise.
    func testDirectUploadFallbackRefusesAnOwnerMismatchedBundleAsLost() async throws {
        let ownerA = testUserId
        let otherAccountB = UUID()
        let bundle = makeBundle(id: UUID(), enqueuedUserId: ownerA)
        signIn(as: otherAccountB)
        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(
            uploader: uploader,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir,
            fileIO: AlwaysRefusingFileIO()
        )

        let outcome = await queue.enqueue(bundle)

        XCTAssertEqual(outcome, .lost, "persistence failed AND the active account cannot legally receive this bundle — nothing can complete")
        let uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(bundle.workout.id), "must never upload under the wrong account, even as a last resort")
    }

    /// The matching positive case, so the fix is a real guard and not just a
    /// blanket refusal: a persist failure for the SAME account still falls
    /// back to the direct upload exactly as before.
    func testDirectUploadFallbackStillSucceedsForTheSameAccount() async throws {
        let bundle = makeBundle(id: UUID(), enqueuedUserId: testUserId)
        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(
            uploader: uploader,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir,
            fileIO: AlwaysRefusingFileIO()
        )

        let outcome = await queue.enqueue(bundle)

        XCTAssertEqual(outcome, .uploadedDirect)
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(bundle.workout.id))
    }

    /// And the legacy nil-owner shape: `enqueue`'s top-of-function stamp
    /// sets it to the current account BEFORE the persist/upload decision, so
    /// by the time the new ownership check runs it is indistinguishable
    /// from an explicit same-account owner — must still fall back normally.
    func testDirectUploadFallbackStillSucceedsForALegacyNilOwnerBundle() async throws {
        let bundle = makeLegacyBundle(id: UUID())
        let uploader = ScriptedUploader(failing: [:])
        let queue = OfflineQueue(
            uploader: uploader,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            baseDir: tempDir,
            fileIO: AlwaysRefusingFileIO()
        )

        let outcome = await queue.enqueue(bundle)

        XCTAssertEqual(outcome, .uploadedDirect, "a legacy nil-owner bundle must still fall back to the current account, exactly as before this fix")
    }
}

/// #529 F2: a minimal `QueueFileIO` that refuses every write — models a
/// full disk / refused container write so `enqueue`'s `.uploadDirect`
/// fallback path is reachable deterministically, without needing the real
/// filesystem to actually run out of space.
private struct AlwaysRefusingFileIO: QueueFileIO {
    func write(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteOutOfSpace) }
    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
}

private actor RanFlag {
    private(set) var ran = false
    func markRan() { ran = true }
}

/// Test double for `WorkoutBundleUploading` — throws a scripted error per
/// bundle id, otherwise succeeds. An actor so concurrent access from the
/// queue is safe without extra locking in the test.
private actor ScriptedUploader: WorkoutBundleUploading {
    private var failing: [UUID: Error]
    private(set) var uploadedIds: Set<UUID> = []
    /// #600: the full bundles as uploaded, so a retry test can assert on the
    /// RESTORED item's shape (e.g. that a stripped payload stays stripped).
    private(set) var uploadedBundles: [WorkoutSaveBundle] = []

    init(failing: [UUID: Error]) {
        self.failing = failing
    }

    func upload(_ bundle: WorkoutSaveBundle) async throws {
        if let error = failing[bundle.workout.id] {
            throw error
        }
        uploadedIds.insert(bundle.workout.id)
        uploadedBundles.append(bundle)
    }

    /// Simulates whatever was wrong resolving itself before a scheduled
    /// retry fires — e.g. connectivity returning, or a server-side fix.
    func stopFailing() {
        failing = [:]
    }
}

private struct FixedClock: QueueClock {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
}

/// Test double for `SessionRelayRequesting` — records how many times the
/// queue actually asked for a relay, so `.needsAuthRelay` triggering the
/// real recovery call is observable (#472b), not just inferred from the
/// classifier `UploadErrorClassifierTests` already pins.
private actor RecordingSessionRelay: SessionRelayRequesting {
    private(set) var requestCount = 0

    func requestSessionRelay() async {
        requestCount += 1
    }
}

/// Test double for `DrainScheduling` — captures scheduled actions instead of
/// sleeping for real, so "a failed drain retries later with no foreground
/// event" is provable by firing the captured action directly rather than
/// waiting on a real timer (#472b). A lock-backed class, not an actor:
/// `DrainScheduling.scheduleRetry` is a synchronous, non-async protocol
/// method (it must return immediately without waiting on the real delay),
/// so recording must also happen synchronously on that call — hopping
/// through an actor via an unstructured `Task` would race the very next
/// line in the test, which reads `scheduledCount` right after `drain()`
/// returns.
private final class RecordingScheduler: DrainScheduling, @unchecked Sendable {
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

    /// Fires the oldest still-pending scheduled action, simulating that
    /// timer elapsing. Removed before firing (not after) so a re-entrant
    /// schedule made by the action itself is never confused with the one
    /// being fired.
    func fireOldest() async {
        lock.lock()
        let action = scheduled.isEmpty ? nil : scheduled.removeFirst()
        lock.unlock()
        await action?.run()
    }
}
