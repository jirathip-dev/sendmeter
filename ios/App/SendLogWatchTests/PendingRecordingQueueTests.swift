import Foundation
import XCTest
import SendLogWatchCore
import Supabase
@testable import SendLogWatch_Watch_App

/// #486 review F9: `PendingRecordingQueue` shipped with only Codable/id-
/// passthrough coverage — nothing exercised `enqueue`, `drain`, `drainPass`
/// ordering, the #158 account guard, or the `.lost` path, and the HANDOFF's
/// claim that no injectable seam exists was true of this branch's base but
/// false of the merged world (PR #482 ships exactly this shape for
/// `OfflineQueue`). These exercise the REAL `drainPass`/`enqueue` control
/// flow through the `uploader`/`baseDir` seam added alongside them, not a
/// reimplementation of it.
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

    // MARK: - enqueue: persistence is synchronous and observable before any drain runs

    func testEnqueuePersistsToDiskBeforeReturning() async throws {
        let id = UUID()
        let queue = PendingRecordingQueue(uploader: ScriptedUploader(failing: [:]), baseDir: tempDir)
        let outcome = await queue.enqueue(makePending(id: id, enqueuedUserId: nil))
        XCTAssertEqual(outcome, .queued)
        // persist() runs synchronously inside enqueue, before the background
        // drain Task is even spawned — no race to win here.
        XCTAssertTrue(try filesOnDisk().contains("\(id.uuidString).json"))
    }

    // MARK: - drain: the happy path

    func testDrainUploadsAndDeletesOnSuccess() async throws {
        let id = UUID()
        try writeFile(makePending(id: id, enqueuedUserId: testUserId), createdAt: Date())
        let uploader = ScriptedUploader(failing: [:])
        let queue = PendingRecordingQueue(uploader: uploader, baseDir: tempDir)

        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(id))
        XCTAssertFalse(try filesOnDisk().contains("\(id.uuidString).json"))
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - drain ordering + the documented head-of-line gap (issue #491)

    /// #486 review F7 (deferred to #491, NOT fixed here): unlike a
    /// post-#482 `OfflineQueue`, this queue has no quarantine — any failure
    /// `break`s the whole pass, oldest-first, so a permanently-failing item
    /// at the head blocks a healthy item behind it. This test PINS that
    /// documented current behavior (so a future accidental "fix" that
    /// silently changes it is caught) rather than asserting it as desirable.
    func testOldestFirstOrderingAndTheDocumentedHeadOfLineGap() async throws {
        let poisoned = UUID()
        let healthy = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: poisoned, enqueuedUserId: testUserId), createdAt: base)
        try writeFile(makePending(id: healthy, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [poisoned: PostgrestError(code: "23514", message: "check violation")])
        let queue = PendingRecordingQueue(uploader: uploader, baseDir: tempDir)

        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertFalse(uploaded.contains(poisoned), "the oldest (failing) item is attempted first")
        XCTAssertFalse(uploaded.contains(healthy), "#491: with no quarantine, the failing head blocks everything behind it")
        // Both files remain — nothing is deleted on a failed attempt.
        XCTAssertTrue(try filesOnDisk().contains("\(poisoned.uuidString).json"))
        XCTAssertTrue(try filesOnDisk().contains("\(healthy.uuidString).json"))
    }

    /// The inverse ordering case: when the oldest item succeeds, the pass
    /// continues on to the next one in the same drain — proving this isn't
    /// a "stop after one item" limit, only a "stop on failure" one.
    func testMultipleHealthyItemsAllUploadInOnePass() async throws {
        let first = UUID()
        let second = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFile(makePending(id: first, enqueuedUserId: testUserId), createdAt: base)
        try writeFile(makePending(id: second, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [:])
        let queue = PendingRecordingQueue(uploader: uploader, baseDir: tempDir)
        await queue.drain()

        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(first))
        XCTAssertTrue(uploaded.contains(second))
        XCTAssertEqual(try filesOnDisk().count, 0)
    }

    // MARK: - issue #158: an item queued under a different account never drains

    func testAccountMismatchLeavesFileUntouchedButDoesNotBlockTheRest() async throws {
        let otherAccount = UUID()
        let mismatched = UUID()
        let matching = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // The mismatched item is OLDEST — if the guard used `break` instead
        // of `continue`, it would silently block the matching item behind it
        // exactly like a real failure would (see the ordering test above).
        try writeFile(makePending(id: mismatched, enqueuedUserId: otherAccount), createdAt: base)
        try writeFile(makePending(id: matching, enqueuedUserId: testUserId), createdAt: base.addingTimeInterval(1))

        let uploader = ScriptedUploader(failing: [:])
        let queue = PendingRecordingQueue(uploader: uploader, baseDir: tempDir)
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
        let queue = PendingRecordingQueue(uploader: ScriptedUploader(failing: [:]), baseDir: tempDir)

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
        let queue = PendingRecordingQueue(uploader: ScriptedUploader(failing: [:]), baseDir: tempDir)

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
        let queue = PendingRecordingQueue(uploader: uploader, baseDir: tempDir)

        let outcome = await queue.enqueue(makePending(id: id, enqueuedUserId: nil))

        XCTAssertEqual(outcome, .uploadedDirect)
        let uploaded = await uploader.uploadedIds
        XCTAssertTrue(uploaded.contains(id))
    }

    func testPersistFailureAndDirectUploadFailureIsReportedAsLost() async throws {
        try Data().write(to: pendingDir)
        let id = UUID()
        let uploader = ScriptedUploader(failing: [id: PostgrestError(code: "PGRST301", message: "stale token")])
        let queue = PendingRecordingQueue(uploader: uploader, baseDir: tempDir)

        let outcome = await queue.enqueue(makePending(id: id, enqueuedUserId: nil))

        // Never phrased as queued (CLAUDE.md #264) — the caller must be able
        // to tell "durably queued" from "genuinely gone" apart from this
        // return value alone.
        XCTAssertEqual(outcome, .lost)
    }
}

// MARK: - Test doubles

private actor ScriptedUploader: TindeqRecordingUploading {
    private var failing: [UUID: Error]
    private(set) var uploadedIds: Set<UUID> = []

    init(failing: [UUID: Error]) {
        self.failing = failing
    }

    func upload(_ row: TindeqRecordingInsert) async throws {
        if let error = failing[row.id] {
            throw error
        }
        uploadedIds.insert(row.id)
    }
}
