import XCTest
@testable import SendmeterCore

private struct TestPayload: Codable, Equatable, Sendable {
    let value: String
}

final class OfflineQueueTests: XCTestCase {
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
        XCTAssertTrue(retried)
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
        XCTAssertFalse(again)
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
        XCTAssertEqual(items.first?.payload, TestPayload(value: "legacy"))
    }
}
