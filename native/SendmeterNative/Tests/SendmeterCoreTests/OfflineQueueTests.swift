import XCTest
@testable import SendmeterCore

private struct TestPayload: Codable, Equatable, Sendable {
    let value: String
}

final class OfflineQueueTests: XCTestCase {
    /// A positive force-editor floor is unrelated to ordinary queue writes.
    /// All zero-order payload shapes must remain durable, and the explicit
    /// enqueue result must say they were accepted so AppModel cannot publish a
    /// false optimistic success.
    func testZeroOrderingWritesSurvivePositiveEditorFloorAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let editor = DurableQueueItem(
            accountUserID: user,
            orderingKey: 1_000,
            terminalKey: UUID(),
            payload: TestPayload(value: "force-editor")
        )
        let editorAccepted = try await queue.enqueue(editor)
        XCTAssertTrue(editorAccepted)
        try await queue.remove(id: editor.id, accountUserID: user, reason: "uploaded")
        let floor = await queue.orderingFloor(for: user)
        XCTAssertEqual(floor?.orderingKey, 1_000)

        let session = DurableQueueItem(
            accountUserID: user,
            payload: TestPayload(value: "manual-session")
        )
        let workout = DurableQueueItem(
            accountUserID: user,
            payload: TestPayload(value: "manual-workout")
        )
        let recording = DurableQueueItem(
            accountUserID: user,
            payload: TestPayload(value: "force-recording")
        )
        let delete = DurableQueueItem(
            accountUserID: user,
            terminalKey: UUID(),
            payload: TestPayload(value: "session-delete")
        )

        let sessionAccepted = try await queue.enqueue(session)
        let workoutAccepted = try await queue.enqueue(workout)
        let recordingAccepted = try await queue.enqueueIfCurrent(recording, expectedRevision: nil)
        let deleteAccepted = try await queue.enqueueUnlessTerminalizedKeepingNewest(
            [delete],
            terminalKey: delete.terminalKey!,
            accountUserID: user
        )
        XCTAssertTrue(sessionAccepted)
        XCTAssertTrue(workoutAccepted)
        XCTAssertTrue(recordingAccepted)
        XCTAssertTrue(deleteAccepted)

        let reloaded = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let values = Set((await reloaded.items(for: user, includeQuarantined: true)).map(\.payload.value))
        XCTAssertEqual(
            values,
            Set(["manual-session", "manual-workout", "force-recording", "session-delete"])
        )
    }

    /// A terminalized or stale semantic write may still be intentionally
    /// skipped, but the ordinary enqueue API must report that skip instead of
    /// letting AppModel claim that the write was durably queued.
    func testEnqueueReportsTerminalizedItemWasSkipped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let terminalKey = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let delete = DurableQueueItem(
            accountUserID: user,
            terminalKey: terminalKey,
            payload: TestPayload(value: "delete")
        )
        let deleteInstalled = try await queue.enqueueTerminalDelete(delete, terminalKey: terminalKey)
        XCTAssertTrue(deleteInstalled)
        let durableDeleteSnapshot = await queue.item(id: delete.id, accountUserID: user)
        let durableDelete = try XCTUnwrap(durableDeleteSnapshot)
        let deleteCompleted = try await queue.completeTerminalDelete(
            id: durableDelete.id,
            accountUserID: user,
            expectedRevision: durableDelete.revision,
            terminalKey: terminalKey,
            operationID: UUID()
        )
        XCTAssertTrue(deleteCompleted)

        let stale = DurableQueueItem(
            accountUserID: user,
            terminalKey: terminalKey,
            payload: TestPayload(value: "stale")
        )
        let staleAccepted = try await queue.enqueue(stale)
        XCTAssertFalse(staleAccepted)
        let staleItem = await queue.item(id: stale.id, accountUserID: user)
        XCTAssertNil(staleItem)
    }

    /// Re-authentication is an immediate account-scoped recovery pass: it
    /// bypasses backoff for active entries, leaves them durable, and still
    /// excludes a permanently quarantined entry.
    func testAuthRecoverySelectionBypassesBackoffWithoutDiscardingData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let otherUser = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let authItem = DurableQueueItem(
            accountUserID: user,
            payload: TestPayload(value: "auth-parked")
        )
        let otherAccountItem = DurableQueueItem(
            accountUserID: otherUser,
            payload: TestPayload(value: "other-account")
        )
        try await queue.enqueue(authItem)
        try await queue.enqueue(otherAccountItem)
        try await queue.markFailure(
            id: authItem.id,
            accountUserID: user,
            error: "expired",
            classification: .auth,
            now: now
        )

        let dueBeforeRecovery = await queue.items(for: user, dueAt: now)
        XCTAssertTrue(dueBeforeRecovery.isEmpty, "ordinary recovery remains backoff-gated")
        let recovery = await queue.items(
            for: user,
            dueAt: QueueUploadMode.authRecovery.revalidationDueAt(now: now)
        )
        XCTAssertEqual(recovery.map(\.payload.value), ["auth-parked"])
        XCTAssertNil(recovery.first?.quarantined)
        let otherRecovery = await queue.items(
            for: otherUser,
            dueAt: QueueUploadMode.authRecovery.revalidationDueAt(now: now)
        )
        XCTAssertTrue(otherRecovery.contains { $0.id == otherAccountItem.id })

        let permanent = DurableQueueItem(
            accountUserID: user,
            payload: TestPayload(value: "permanent")
        )
        try await queue.enqueue(permanent)
        var failureAt = now
        for _ in 0..<3 {
            try await queue.markFailure(
                id: permanent.id,
                accountUserID: user,
                error: "rejected",
                classification: .permanent,
                now: failureAt
            )
            failureAt = failureAt.addingTimeInterval(30)
        }
        let recoveryAfterQuarantine = await queue.items(
            for: user,
            dueAt: QueueUploadMode.authRecovery.revalidationDueAt(now: failureAt)
        )
        XCTAssertFalse(recoveryAfterQuarantine.contains { $0.id == permanent.id })

        let reloaded = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let reloadedAuthItem = await reloaded.item(id: authItem.id, accountUserID: user)
        XCTAssertNotNil(reloadedAuthItem)
    }

    func testQueueIsDurableAndAccountScoped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstUser = UUID()
        let secondUser = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: firstUser, payload: TestPayload(value: "one"))
        try await queue.enqueue(item)

        let firstCount = await queue.count(for: firstUser)
        let secondCount = await queue.count(for: secondUser)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
        do {
            try await queue.remove(id: item.id, accountUserID: secondUser)
            XCTFail("Expected account mismatch")
        } catch {
            XCTAssertEqual(error as? DurableQueueError, .accountMismatch)
        }
        let remainingCount = await queue.count(for: firstUser)
        XCTAssertEqual(remainingCount, 1)

        let reloaded = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let reloadedItems = await reloaded.items(for: firstUser)
        XCTAssertEqual(reloadedItems.first?.payload, TestPayload(value: "one"))
    }

    /// The routine insert has already completed and its queue item has left
    /// the file. If the follow-up Undo delete cannot be persisted, the failed
    /// enqueue must not leave a memory-only delete that disappears on reload.
    func testEnqueuePersistenceFailureAfterCompletedInsertIsTransactional() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queueFile = directory.appendingPathComponent("queue.json")
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let completedInsert = DurableQueueItem(
            accountUserID: user,
            payload: TestPayload(value: "inserted")
        )
        try await queue.enqueue(completedInsert)
        try await queue.remove(id: completedInsert.id, accountUserID: user, reason: "uploaded")

        let durableEmptyQueue = try Data(contentsOf: queueFile)
        try FileManager.default.removeItem(at: queueFile)
        // A directory at the queue-file path makes the atomic write fail after
        // the candidate has been built, without relying on process privileges
        // or a test-only persistence hook.
        try FileManager.default.createDirectory(at: queueFile, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: queueFile) }

        let deleteIntent = DurableQueueItem(
            accountUserID: user,
            payload: TestPayload(value: "delete")
        )
        do {
            try await queue.enqueue(deleteIntent)
            XCTFail("Expected the queue-file persistence to fail")
        } catch {
            // The failure is the behavior under test.
        }

        let inMemoryItems = await queue.items(for: user, includeQuarantined: true)
        XCTAssertTrue(inMemoryItems.isEmpty)

        // Restore the last known durable bytes to model the atomic-write
        // contract and prove that a fresh queue sees no phantom delete.
        try FileManager.default.removeItem(at: queueFile)
        try durableEmptyQueue.write(to: queueFile, options: [.atomic])
        let reloaded = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let reloadedItems = await reloaded.items(for: user, includeQuarantined: true)
        XCTAssertTrue(reloadedItems.isEmpty)
    }

    func testFailureBackoffAndBreadcrumbRing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(
            directoryURL: directory,
            filename: "queue.json",
            breadcrumbLimit: 2
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let item = DurableQueueItem(accountUserID: user, createdAt: now, payload: TestPayload(value: "x"))
        try await queue.enqueue(item)
        try await queue.markFailure(
            id: item.id,
            accountUserID: user,
            error: "offline",
            classification: .retryable,
            now: now
        )
        let notDue = await queue.items(for: user, dueAt: now)
        let due = await queue.items(for: user, dueAt: now.addingTimeInterval(5))
        XCTAssertTrue(notDue.isEmpty)
        XCTAssertEqual(due.count, 1)
        try await queue.remove(id: item.id, accountUserID: user, reason: "uploaded", now: now)
        let breadcrumbs = await queue.breadcrumbs(for: user)
        XCTAssertEqual(breadcrumbs.count, 1)
    }

    // MARK: #675 quarantine

    /// AC-1: a `permanent` rejection retries with backoff up to the bounded
    /// attempt cap, then quarantines — and a quarantined entry is NEVER
    /// returned by the hot drain path (`items(for:dueAt:)`), even without a
    /// due-date filter.
    func testPermanentRejectionQuarantinesAfterBoundedAttemptsAndNeverHotDrains() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)

        let cap = DurableQueueItem<TestPayload>.maxPermanentAttempts
        XCTAssertEqual(cap, 3)

        var now = Date(timeIntervalSince1970: 1_000)
        // Attempts 1 and 2 keep backoff; item stays active and due after its
        // delay (5s for attempt 1, 10s for attempt 2).
        for attempt in 1..<cap {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            let due = await queue.items(for: user, dueAt: now.addingTimeInterval(20))
            XCTAssertEqual(due.count, 1, "attempt \(attempt) must stay on the retry path")
            XCTAssertNil(due.first?.quarantined)
            XCTAssertEqual(due.first?.attempts, attempt)
            let quarantinedCount = await queue.quarantinedCount(for: user)
            XCTAssertEqual(quarantinedCount, 0)
            now = now.addingTimeInterval(30)
        }

        // Attempt `cap` — the 3rd — crosses the bound and quarantines.
        try await queue.markFailure(
            id: item.id,
            accountUserID: user,
            error: "constraint",
            classification: .permanent,
            code: "23514",
            now: now
        )
        let quarantined = await queue.quarantinedItems(for: user)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(quarantined.first?.id, item.id)
        XCTAssertEqual(quarantined.first?.quarantined?.kind, .permanent)
        XCTAssertEqual(quarantined.first?.quarantined?.code, "23514")
        XCTAssertEqual(quarantined.first?.attempts, cap)

        // Hot drain path never sees it — with AND without a due-date filter.
        let all = await queue.items(for: user)
        let due = await queue.items(for: user, dueAt: now.addingTimeInterval(1_000))
        XCTAssertTrue(all.isEmpty)
        XCTAssertTrue(due.isEmpty)
        // And the active count excludes it.
        let activeCount = await queue.count(for: user)
        XCTAssertEqual(activeCount, 0)
    }

    /// AC-1: retryable failures keep ordinary backoff and never quarantine,
    /// no matter how many times they fire.
    func testRetryableFailuresKeepBackoffAndNeverQuarantine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "fine"))
        try await queue.enqueue(item)

        var now = Date(timeIntervalSince1970: 1_000)
        let many = DurableQueueItem<TestPayload>.maxPermanentAttempts * 4
        for attempt in 1...many {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "offline",
                classification: .retryable,
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedCount = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedCount, 0)
        let due = await queue.items(for: user, dueAt: now.addingTimeInterval(1_000))
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.attempts, many)
        XCTAssertNil(due.first?.quarantined)
    }

    /// #675 F3: the bounded-attempt budget is PERMANENT-specific. A long spell
    /// of retryable failures (the offline case an offline queue exists for)
    /// must never spend it — the first real permanent rejection after the
    /// network returns must get the full bounded window, not be quarantined on
    /// sight because `attempts` had already climbed past the cap.
    func testRetryableFailuresThenFirstPermanentGetsFullWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "fine"))
        try await queue.enqueue(item)

        var now = Date(timeIntervalSince1970: 1_000)
        // A long offline spell: many retryable failures, all with backoff.
        let many = DurableQueueItem<TestPayload>.maxPermanentAttempts * 4
        for _ in 1...many {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "offline",
                classification: .retryable,
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedAfterOffline = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedAfterOffline, 0)

        // First and second permanent rejections: NOT quarantined yet — the
        // full bounded window starts now, not at the pre-existing attempt
        // count.
        for _ in 1..<DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            let quarantinedBeforeCap = await queue.quarantinedCount(for: user)
            XCTAssertEqual(
                quarantinedBeforeCap,
                0,
                "permanent rejection before the cap must not quarantine"
            )
            now = now.addingTimeInterval(30)
        }

        // Third permanent rejection — the permanent budget is spent,
        // regardless of how many retryable failures preceded it.
        try await queue.markFailure(
            id: item.id,
            accountUserID: user,
            error: "constraint",
            classification: .permanent,
            code: "23514",
            now: now
        )
        let quarantinedAfterCap = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedAfterCap, 1)
        let quarantined = await queue.quarantinedItems(for: user)
        XCTAssertEqual(quarantined.first?.quarantined?.kind, .permanent)
    }

    /// #675 F2: a PARKED rejection (403/RLS) behaves exactly like auth — it
    /// never quarantines, no matter how many times it fires.
    func testParkedFailuresNeverQuarantine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "mine"))
        try await queue.enqueue(item)

        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...(DurableQueueItem<TestPayload>.maxPermanentAttempts * 2) {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "permission denied",
                classification: .parked,
                code: "42501",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let parkedQuarantined = await queue.quarantinedCount(for: user)
        XCTAssertEqual(parkedQuarantined, 0)
        let due = await queue.items(for: user, dueAt: now.addingTimeInterval(1_000))
        XCTAssertEqual(due.count, 1)
        XCTAssertNil(due.first?.quarantined)
    }

    /// #675 F6: a concurrent drain and manual retry can both snapshot the same
    /// due entry before the first `markFailure` quarantines it — the second
    /// `markFailure` on an already-quarantined entry must be a NO-OP, not a
    /// thrown `alreadyQuarantined`, and must not corrupt the quarantine stamp.
    func testMarkFailureOnAlreadyQuarantinedIsANoOp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)

        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedBefore = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedBefore, 1)
        let stamp = (await queue.quarantinedItems(for: user)).first?.quarantined

        // A late, racing markFailure lands on the now-quarantined entry.
        try await queue.markFailure(
            id: item.id,
            accountUserID: user,
            error: "constraint again",
            classification: .permanent,
            code: "23514",
            now: now
        )
        // No throw, no re-armoring, stamp intact, still exactly one quarantined.
        let quarantined = await queue.quarantinedItems(for: user)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(quarantined.first?.quarantined, stamp)
        XCTAssertEqual(quarantined.first?.quarantined?.kind, .permanent)
        // And the active path still never sees it.
        let active = await queue.items(for: user)
        XCTAssertTrue(active.isEmpty)
    }

    /// #273 interaction: an `auth` failure never quarantines — it parks on the
    /// retry path (mirroring the web's never-destroy-data-on-auth-failure
    /// rule), so a revoked token can never turn into a discarded recording.
    func testAuthFailureParksNotQuarantines() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "mine"))
        try await queue.enqueue(item)

        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...(DurableQueueItem<TestPayload>.maxPermanentAttempts * 2) {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "token expired",
                classification: .auth,
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let authQuarantined = await queue.quarantinedCount(for: user)
        let authActive = await queue.count(for: user)
        XCTAssertEqual(authQuarantined, 0)
        XCTAssertEqual(authActive, 1)
        let due = await queue.items(for: user, dueAt: now.addingTimeInterval(1_000))
        XCTAssertEqual(due.count, 1)
    }

    /// An expired access token is an active, durable failure rather than a
    /// verdict about the payload. The class/detail survive relaunch, and a
    /// later authenticated drain can still select and remove the item.
    func testAuthFailureDiagnosticSurvivesRelaunchAndLaterRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(
            accountUserID: user,
            createdAt: now,
            payload: TestPayload(value: "preserve-me")
        )
        try await queue.enqueue(item)

        try await queue.markFailure(
            id: item.id,
            accountUserID: user,
            error: "access token expired",
            classification: .auth,
            code: "401",
            now: now
        )

        let reloaded = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let parked = await reloaded.items(for: user, includeQuarantined: true)
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(parked.first?.lastFailure?.kind, .auth)
        XCTAssertEqual(parked.first?.lastFailure?.code, "401")
        XCTAssertEqual(parked.first?.lastFailure?.detail, "access token expired")
        XCTAssertEqual(parked.first?.lastError, "access token expired")
        XCTAssertEqual(parked.first?.rejectionClass, .auth)
        let quarantinedCount = await reloaded.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedCount, 0)

        // A valid later sign-in is modeled by a forced/manual revalidation;
        // the item remains selectable despite its automatic backoff.
        let recovered = await reloaded.activeItem(
            id: item.id,
            accountUserID: user,
            dueAt: nil
        )
        XCTAssertNotNil(recovered)
        try await reloaded.remove(id: item.id, accountUserID: user, reason: "uploaded")
        let finalItems = await reloaded.items(for: user, includeQuarantined: true)
        XCTAssertTrue(finalItems.isEmpty)
    }

    /// Explicit Retry bypasses automatic backoff, while the normal drain
    /// remains due-date gated. This is the queue contract AppModel's manual
    /// retry path relies on when a foreground drain is already in flight.
    func testManualRetryRevalidatesBackedOffItemWithoutQuarantine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let now = Date(timeIntervalSince1970: 2_000)
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(
            accountUserID: user,
            createdAt: now,
            payload: TestPayload(value: "retry-now")
        )
        try await queue.enqueue(item)
        try await queue.markFailure(
            id: item.id,
            accountUserID: user,
            error: "offline",
            classification: .retryable,
            now: now
        )

        let notDue = await queue.activeItem(id: item.id, accountUserID: user, dueAt: now)
        let manualCandidate = await queue.activeItem(id: item.id, accountUserID: user, dueAt: nil)
        XCTAssertNil(notDue)
        XCTAssertNotNil(manualCandidate)
        XCTAssertEqual(QueueUploadMode.automatic.revalidationDueAt(now: now), now)
        XCTAssertNil(QueueUploadMode.manual.revalidationDueAt(now: now))
        XCTAssertFalse(QueueUploadMode.manual.countsTowardQuarantine)
        let quarantinedCount = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedCount, 0)
    }

    /// Pending-session deletion is one durable transaction: the captured
    /// upsert revision is canceled and a distinct delete identity is
    /// installed. Reloading before and after completion must never restore the
    /// canceled upsert.
    func testPendingDeleteReplacementSurvivesRefreshAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let sessionID = UUID()
        let deleteID = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let insert = DurableQueueItem(
            id: sessionID,
            accountUserID: user,
            payload: TestPayload(value: "upsert")
        )
        try await queue.enqueue(insert)
        let capturedItem = await queue.item(id: sessionID, accountUserID: user)
        let captured = try XCTUnwrap(capturedItem)
        let delete = DurableQueueItem(
            id: deleteID,
            accountUserID: user,
            payload: TestPayload(value: "delete")
        )

        let installed = try await queue.enqueueReplacing(
            delete,
            canceling: [
                DurableQueueRemoval(
                    id: captured.id,
                    accountUserID: captured.accountUserID,
                    expectedRevision: captured.revision
                )
            ]
        )
        XCTAssertTrue(installed)
        let afterTransaction = await queue.items(for: user, includeQuarantined: true)
        XCTAssertEqual(afterTransaction.map(\.id), [deleteID])

        let relaunched = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let afterRelaunch = await relaunched.items(for: user, includeQuarantined: true)
        XCTAssertEqual(afterRelaunch.map(\.id), [deleteID])
        XCTAssertFalse(afterRelaunch.contains { $0.id == sessionID })

        try await relaunched.remove(id: deleteID, accountUserID: user, reason: "uploaded")
        let afterCompletion = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let completedItems = await afterCompletion.items(for: user, includeQuarantined: true)
        XCTAssertTrue(completedItems.isEmpty)
    }

    /// If a newer upsert replaces the captured revision while delete is
    /// racing it, the conditional cancel must leave that replacement durable;
    /// an unconditional remove would lose the latest write.
    func testPendingDeleteDoesNotCancelNewerReplacementRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let sessionID = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let original = DurableQueueItem(
            id: sessionID,
            accountUserID: user,
            payload: TestPayload(value: "old")
        )
        try await queue.enqueue(original)
        let newer = original.replacingPayload(TestPayload(value: "new"))
        try await queue.enqueue(newer)

        let delete = DurableQueueItem(
            id: UUID(),
            accountUserID: user,
            payload: TestPayload(value: "delete")
        )
        let installed = try await queue.enqueueReplacing(
            delete,
            canceling: [
                DurableQueueRemoval(
                    id: sessionID,
                    accountUserID: user,
                    expectedRevision: original.revision
                )
            ]
        )
        XCTAssertTrue(installed)
        let items = await queue.items(for: user, includeQuarantined: true)
        XCTAssertTrue(items.contains { $0.id == sessionID && $0.payload.value == "new" })
        XCTAssertTrue(items.contains { $0.id == delete.id })
    }

    /// AC-2: a quarantined entry is recoverable by hand — retry clears the
    /// stamp and resets attempts so the next drain treats it as fresh.
    func testRetryQuarantinedRecoversTheEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)

        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedAfterCap = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedAfterCap, 1)
        let activeAfterCap = await queue.items(for: user)
        XCTAssertTrue(activeAfterCap.isEmpty)

        let retried = try await queue.retryQuarantined(id: item.id, accountUserID: user, now: now)
        XCTAssertNotNil(retried)
        let quarantinedAfterRetry = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedAfterRetry, 0)
        let active = await queue.items(for: user, dueAt: now.addingTimeInterval(1))
        XCTAssertEqual(active.count, 1)
        XCTAssertNil(active.first?.quarantined)
        XCTAssertEqual(active.first?.attempts, 0)

        // The fresh budget restarts: a single permanent rejection no longer
        // quarantines immediately (attempts were reset).
        try await queue.markFailure(
            id: item.id,
            accountUserID: user,
            error: "constraint",
            classification: .permanent,
            code: "23514",
            now: now
        )
        let quarantinedAfterFreshRejection = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedAfterFreshRejection, 0)

        // Retrying an entry that is not quarantined is a no-op, not an error.
        let again = try await queue.retryQuarantined(id: item.id, accountUserID: user, now: now)
        XCTAssertNil(again)
    }

    /// AC-2: a quarantined entry can be discarded per-item (account-scoped,
    /// quarantine-only), leaving a breadcrumb behind.
    func testDiscardQuarantinedRemovesOnlyThatEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let bad = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        let good = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "good"))
        try await queue.enqueue(bad)
        try await queue.enqueue(good)

        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: bad.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedBeforeDiscard = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedBeforeDiscard, 1)

        // Not quarantined → discard is a no-op, active entry stays.
        let nonQuarantined = try await queue.discardQuarantined(id: good.id, accountUserID: user, now: now)
        XCTAssertFalse(nonQuarantined)
        let activeCountAfterNonDiscard = await queue.count(for: user)
        XCTAssertEqual(activeCountAfterNonDiscard, 1)

        let discarded = try await queue.discardQuarantined(id: bad.id, accountUserID: user, now: now)
        XCTAssertTrue(discarded)
        let quarantinedAfterDiscard = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedAfterDiscard, 0)
        let breadcrumbs = await queue.breadcrumbs(for: user)
        XCTAssertEqual(breadcrumbs.count, 1)
        XCTAssertEqual(breadcrumbs.first?.reason, "quarantine-discarded")

        // Account scoping: the other account cannot discard this account's item.
        let other = UUID()
        try await queue.enqueue(DurableQueueItem(accountUserID: user, payload: TestPayload(value: "again")))
        // Re-quarantine a new entry for the scoping check.
        let scoped = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "scoped"))
        try await queue.enqueue(scoped)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: scoped.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        do {
            _ = try await queue.discardQuarantined(id: scoped.id, accountUserID: other, now: now)
            XCTFail("Expected account mismatch")
        } catch {
            XCTAssertEqual(error as? DurableQueueError, .accountMismatch)
        }
        let quarantinedAfterMismatch = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedAfterMismatch, 1)
    }

    /// A permanent rejection stamp persists across a reload (the queue file
    /// round-trips `quarantined`), so a quarantined entry stays quarantined
    /// across launches.
    func testQuarantineSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23505",
                now: now
            )
            now = now.addingTimeInterval(30)
        }

        let reloaded = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let quarantined = await reloaded.quarantinedItems(for: user)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(quarantined.first?.quarantined?.code, "23505")
        let reloadedActive = await reloaded.items(for: user)
        XCTAssertTrue(reloadedActive.isEmpty)
    }

    /// Backward compatibility: pre-#675 queue files (no `quarantined` key)
    /// decode with `quarantined == nil`, so an upgrade never re-rejects
    /// existing entries.
    func testLegacyQueueFileDecodesWithoutQuarantine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let user = UUID()
        let legacyItem: [String: Any] = [
            "id": UUID().uuidString,
            "accountUserID": user.uuidString,
            "createdAt": "2026-08-01T00:00:00Z",
            "updatedAt": "2026-08-01T00:00:00Z",
            "attempts": 2,
            "nextAttemptAt": "2026-08-01T00:00:00Z",
            "payload": ["value": "legacy"],
        ]
        let store: [String: Any] = ["items": [legacyItem], "breadcrumbs": []]
        let data = try JSONSerialization.data(withJSONObject: store)
        try data.write(to: directory.appendingPathComponent("queue.json"))

        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let items = await queue.items(for: user)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.quarantined)
        XCTAssertNil(items.first?.permanentAttempts)
        XCTAssertEqual(items.first?.payload, TestPayload(value: "legacy"))
    }

    /// #675 F5: a MANUAL retry's failure must NOT count toward the quarantine
    /// budget — the user's own remediation attempt is an explicit action, and
    /// tapping "Retry now" three times must never be what quarantines the
    /// entry they were trying to save.
    func testManualRetryFailuresDoNotSpendQuarantineBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)

        var now = Date(timeIntervalSince1970: 1_000)
        // Many MANUAL retries, all permanent-classified but explicitly opted
        // out of the quarantine count.
        for _ in 1...(DurableQueueItem<TestPayload>.maxPermanentAttempts * 2) {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now,
                countsTowardQuarantine: false
            )
            now = now.addingTimeInterval(30)
        }
        let quarantined = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantined, 0)
        let active = await queue.items(for: user)
        XCTAssertNil(active.first?.quarantined)
        XCTAssertNil(active.first?.permanentAttempts)
    }

    /// #675 F1: `items(for:includeQuarantined: true)` is the VISIBILITY read
    /// `restorePendingWrites` uses — it returns quarantined entries too, so a
    /// rejected write stays visible in History/Force after a relaunch. The hot
    /// drain path (`items(for:)` without the flag) still never sees them.
    func testIncludeQuarantinedReturnsQuarantinedForVisibilityOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }

        // The drain read (default) excludes it.
        let drain = await queue.items(for: user)
        XCTAssertTrue(drain.isEmpty)
        // The visibility read includes it.
        let visible = await queue.items(for: user, includeQuarantined: true)
        XCTAssertEqual(visible.count, 1)
        XCTAssertNotNil(visible.first?.quarantined)
    }

    /// An insert completion can race a drain that quarantines its matching
    /// Undo delete. The completion's pre-await snapshot is stale by the time
    /// it follows the insert, so the production active-item read must refuse
    /// to hand that quarantined delete back to upload.
    func testConcurrentInsertCompletionAndDrainCannotRetryDeleteAfterQuarantine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let insert = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "insert"))
        let delete = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "delete"))
        try await queue.enqueue(insert)
        try await queue.enqueue(delete)

        let staleDelete = await queue.items(for: user, includeQuarantined: true)
            .first { $0.id == delete.id }
        guard let staleDelete else {
            XCTFail("Expected the delete snapshot before the race")
            return
        }
        XCTAssertNil(staleDelete.quarantined)

        let finished = AsyncStream<Void>.makeStream()
        let drainTask = Task {
            var now = Date(timeIntervalSince1970: 10_000)
            for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
                try? await queue.markFailure(
                    id: delete.id,
                    accountUserID: user,
                    error: "constraint",
                    classification: .permanent,
                    code: "23514",
                    now: now
                )
                now = now.addingTimeInterval(30)
            }
            finished.continuation.yield(())
            finished.continuation.finish()
        }
        let insertCompletionTask = Task {
            for await _ in finished.stream { break }
            // The insert completion has now removed its own queue item and is
            // following the stale delete snapshot into the normal upload
            // path. Revalidation must see quarantine, not the old snapshot.
            try? await queue.remove(id: insert.id, accountUserID: user, reason: "uploaded")
            return await queue.activeItem(
                id: staleDelete.id,
                accountUserID: user,
                dueAt: Date.distantFuture
            )
        }

        await drainTask.value
        let selectedAfterRace = await insertCompletionTask.value
        XCTAssertNil(selectedAfterRace)
        let quarantinedCount = await queue.quarantinedCount(for: user)
        let activeCount = await queue.count(for: user)
        XCTAssertEqual(quarantinedCount, 1)
        XCTAssertEqual(activeCount, 0)
    }

    /// #675 F7: a failed MANUAL retry must re-stamp the quarantine
    /// immediately — the entry never sits active on the hot drain path
    /// re-arming free automatic attempts behind the user's back.
    func testRequarantineRestoresQuarantinedState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedBeforeRetry = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedBeforeRetry, 1)

        // Manual retry clears the stamp and resets the budget.
        let cleared = try await queue.retryQuarantined(id: item.id, accountUserID: user, now: now)
        XCTAssertNotNil(cleared)
        XCTAssertEqual(cleared?.code, "23514")
        let activeAfterRetry = await queue.items(for: user)
        XCTAssertTrue(activeAfterRetry.contains { $0.id == item.id })
        XCTAssertNil(activeAfterRetry.first { $0.id == item.id }?.quarantined)

        // The upload failed → re-stamp. The entry is quarantined again, and
        // the hot drain path cannot touch it.
        let restamped = try await queue.requarantine(
            id: item.id,
            accountUserID: user,
            previous: cleared,
            classification: .retryable,
            detail: "Manual retry failed",
            now: now
        )
        XCTAssertTrue(restamped)
        let quarantinedCount = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedCount, 1)
        let activeAfterRestamp = await queue.items(for: user)
        XCTAssertTrue(activeAfterRestamp.isEmpty)
        let quarantine = await queue.quarantinedItems(for: user)
        // #675 N1: a transient failure on the retry restores the prior stamp
        // verbatim — the passed-in detail is NOT stamped.
        XCTAssertEqual(quarantine.first?.quarantined, cleared)

        // Re-stamping an already-quarantined entry is a no-op (it may have
        // been uploaded by a racing drain).
        let second = try await queue.requarantine(
            id: item.id,
            accountUserID: user,
            previous: cleared,
            classification: .retryable,
            detail: "too late",
            now: now
        )
        XCTAssertFalse(second)
    }

    /// #675 N1: a failed MANUAL retry preserves the rejection diagnostic. A
    /// transient (network) failure on the retry says NOTHING new about the
    /// payload — the entry was quarantined for a server rejection that still
    /// stands — so `requarantine` restores the prior stamp VERBATIM (code,
    /// detail AND `at`). Only a FRESH `.permanent` rejection replaces it.
    func testFailedManualRetryPreservesRejectionDiagnostic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "new row violates check constraint sessions_date_sane",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let originalStamp = (await queue.quarantinedItems(for: user)).first?.quarantined
        XCTAssertEqual(originalStamp?.code, "23514")

        // Manual retry clears the stamp...
        let cleared = try await queue.retryQuarantined(id: item.id, accountUserID: user, now: now)
        XCTAssertNotNil(cleared)
        // ...and the retry fails with a TRANSIENT (offline) error.
        let restamped = try await queue.requarantine(
            id: item.id,
            accountUserID: user,
            previous: cleared,
            classification: .retryable,
            code: nil,
            detail: "The Internet connection appears to be offline.",
            now: now
        )
        XCTAssertTrue(restamped)

        // The stamp survives VERBATIM: kind, code, detail, and the original
        // `at` (the retry's `now` is much later than the original quarantine).
        let stamp = (await queue.quarantinedItems(for: user)).first?.quarantined
        XCTAssertEqual(stamp, originalStamp)
        XCTAssertEqual(stamp?.kind, .permanent)
        XCTAssertEqual(stamp?.code, "23514")
        XCTAssertEqual(stamp?.detail, "new row violates check constraint sessions_date_sane")
        XCTAssertEqual(stamp?.at, originalStamp?.at)
    }

    /// #675 N1: a fresh `.permanent` rejection ON the manual retry DOES
    /// replace the stamp — the new diagnostic is the accurate one.
    func testFreshPermanentOnManualRetryReplacesStamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestPayload>(directoryURL: directory, filename: "queue.json")
        let item = DurableQueueItem(accountUserID: user, payload: TestPayload(value: "bad"))
        try await queue.enqueue(item)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestPayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: item.id,
                accountUserID: user,
                error: "old constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let cleared = try await queue.retryQuarantined(id: item.id, accountUserID: user, now: now)
        XCTAssertNotNil(cleared)

        // The retry is rejected with a DIFFERENT constraint code.
        let restamped = try await queue.requarantine(
            id: item.id,
            accountUserID: user,
            previous: cleared,
            classification: .permanent,
            code: "23502",
            detail: "new row violates not-null constraint",
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(restamped)
        let stamp = (await queue.quarantinedItems(for: user)).first?.quarantined
        XCTAssertEqual(stamp?.code, "23502")
        XCTAssertEqual(stamp?.detail, "new row violates not-null constraint")
        XCTAssertEqual(stamp?.kind, .permanent)
    }
}
