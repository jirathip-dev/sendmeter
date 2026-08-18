import XCTest
@testable import SendmeterCore

final class SignOutQueuePolicyTests: XCTestCase {
    func testDrainRunsBeforeSignOutInOrder() async {
        let user = UUID()
        var calls: [String] = []
        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { _ in
                calls.append("drain")
                return 2
            },
            countRemaining: { _ in
                calls.append("count")
                return 0
            },
            askAboutRemainder: { _ in
                calls.append("ask")
                return .cancel
            },
            signOut: {
                calls.append("signOut")
            }
        )
        XCTAssertEqual(calls, ["drain", "count", "signOut"])
        XCTAssertEqual(result.outcome?.uploaded, 2)
        XCTAssertEqual(result.outcome?.remaining, 0)
        XCTAssertEqual(result.outcome?.timedOut, false)
        XCTAssertNil(result.signOutError)
    }

    func testRemainderPromptAskedOnceWithCountThenSignOutProceeds() async {
        let user = UUID()
        var askedCounts: [Int] = []
        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { _ in 1 },
            countRemaining: { _ in 3 },
            askAboutRemainder: { count in
                askedCounts.append(count)
                return .signOut
            },
            signOut: {}
        )
        XCTAssertEqual(askedCounts, [3])
        XCTAssertEqual(result.outcome?.uploaded, 1)
        XCTAssertEqual(result.outcome?.remaining, 3)
        XCTAssertNotNil(result.outcome)
    }

    func testCancelAtRemainderPromptAbandonsSignOut() async {
        let user = UUID()
        var signOutCalled = false
        var drainCalled = false
        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { _ in
                drainCalled = true
                return 0
            },
            countRemaining: { _ in 2 },
            askAboutRemainder: { _ in .cancel },
            signOut: { signOutCalled = true }
        )
        XCTAssertTrue(drainCalled)
        XCTAssertFalse(signOutCalled)
        XCTAssertNil(result.outcome)
        XCTAssertNil(result.signOutError)
    }

    /// #632 review: cancel must be a HARD STOP — `outcome == nil` is the
    /// signal the AppModel wiring keys on (the "stay signed in" choice must
    /// not even reach the watch relay, let alone `signOut`), so the queued
    /// entries the prompt was about stay exactly where they were.
    func testCancelLeavesQueuedEntriesInPlace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestQueuePayload>(directoryURL: directory, filename: "queue.json")
        try await queue.enqueue(DurableQueueItem(accountUserID: user, payload: TestQueuePayload(value: "a1")))
        try await queue.enqueue(DurableQueueItem(accountUserID: user, payload: TestQueuePayload(value: "a2")))

        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { _ in 0 },
            countRemaining: { await queue.count(for: $0) },
            askAboutRemainder: { _ in .cancel },
            signOut: { XCTFail("signOut must not run after cancel") }
        )
        XCTAssertNil(result.outcome)
        let stillQueued = await queue.count(for: user)
        XCTAssertEqual(stillQueued, 2)
    }

    func testEmptyQueueSkipsRemainderPrompt() async {
        let user = UUID()
        var asked = false
        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { _ in 0 },
            countRemaining: { _ in 0 },
            askAboutRemainder: { _ in
                asked = true
                return .cancel
            },
            signOut: {}
        )
        XCTAssertFalse(asked)
        XCTAssertEqual(result.outcome?.remaining, 0)
        XCTAssertNotNil(result.outcome)
    }

    func testDrainDeadlineDoesNotHangSignOut() async {
        let user = UUID()
        let start = Date()
        var signOutCalled = false
        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { _ in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return 1
            },
            countRemaining: { _ in 1 },
            askAboutRemainder: { _ in .signOut },
            signOut: { signOutCalled = true },
            timeout: 0.05
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.9, "sign-out must not wait for a dead drain")
        XCTAssertTrue(result.outcome?.timedOut == true)
        XCTAssertEqual(result.outcome?.uploaded, 0)
        XCTAssertEqual(result.outcome?.remaining, 1)
        XCTAssertTrue(signOutCalled)
    }

    func testSignOutErrorIsReturnedNotSwallowed() async {
        struct SignOutFailure: Error, Equatable {}
        let user = UUID()
        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { _ in 1 },
            countRemaining: { _ in 0 },
            askAboutRemainder: { _ in .signOut },
            signOut: { throw SignOutFailure() }
        )
        XCTAssertNotNil(result.outcome)
        XCTAssertEqual(result.signOutError as? SignOutFailure, SignOutFailure())
    }

    func testDrainAndRemainderAreAccountScopedThroughTheRealQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstUser = UUID()
        let secondUser = UUID()
        let queue = try DurableQueue<TestQueuePayload>(directoryURL: directory, filename: "queue.json")
        try await queue.enqueue(DurableQueueItem(accountUserID: firstUser, payload: TestQueuePayload(value: "a1")))
        try await queue.enqueue(DurableQueueItem(accountUserID: firstUser, payload: TestQueuePayload(value: "a2")))
        try await queue.enqueue(DurableQueueItem(accountUserID: secondUser, payload: TestQueuePayload(value: "b1")))

        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: firstUser,
            drain: { userID in
                var uploaded = 0
                for item in await queue.items(for: userID) {
                    try? await queue.remove(id: item.id, accountUserID: userID, reason: "uploaded")
                    uploaded += 1
                }
                return uploaded
            },
            countRemaining: { await queue.count(for: $0) },
            askAboutRemainder: { _ in .signOut },
            signOut: {}
        )
        XCTAssertEqual(result.outcome?.uploaded, 2)
        XCTAssertEqual(result.outcome?.remaining, 0)
        // The other account's entry is never drained, never counted, never touched.
        let firstRemaining = await queue.count(for: firstUser)
        let secondRemaining = await queue.count(for: secondUser)
        XCTAssertEqual(firstRemaining, 0)
        XCTAssertEqual(secondRemaining, 1)
    }

    /// #675: the pre-sign-out drain and its remainder count run over the
    /// ACTIVE entries only (`queue.items` / `queue.count` exclude quarantined),
    /// so a user-initiated sign-out never attempts, counts, or discards a
    /// quarantined item — it stays on the device for the same account to
    /// recover (retry/discard) on its next sign-in, exactly like the accepted
    /// residual for entries that can't upload. A quarantined item is
    /// "rejected, not retrying", NOT "waiting to upload", so it must not
    /// inflate the #273 remainder prompt either.
    func testSignOutDrainLeavesQuarantinedItemsUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestQueuePayload>(directoryURL: directory, filename: "queue.json")
        let active = DurableQueueItem(accountUserID: user, payload: TestQueuePayload(value: "active"))
        let poison = DurableQueueItem(accountUserID: user, payload: TestQueuePayload(value: "poison"))
        try await queue.enqueue(active)
        try await queue.enqueue(poison)
        // Push `poison` into quarantine: 3 permanent rejections.
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestQueuePayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: poison.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedCountBeforeDrain = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedCountBeforeDrain, 1)

        var drainTouched = 0
        let result = await SignOutQueuePolicy.drainBeforeSignOut(
            userId: user,
            drain: { userID in
                var uploaded = 0
                for item in await queue.items(for: userID) {
                    try? await queue.remove(id: item.id, accountUserID: userID, reason: "uploaded")
                    uploaded += 1
                    drainTouched += 1
                }
                return uploaded
            },
            countRemaining: { await queue.count(for: $0) },
            askAboutRemainder: { _ in .signOut },
            signOut: {}
        )
        // Only the active entry was drained; the quarantined one was never
        // touched by the drain, never counted as remaining.
        XCTAssertEqual(drainTouched, 1)
        XCTAssertEqual(result.outcome?.uploaded, 1)
        XCTAssertEqual(result.outcome?.remaining, 0)
        let stillQuarantined = await queue.quarantinedItems(for: user)
        XCTAssertEqual(stillQuarantined.count, 1)
        XCTAssertEqual(stillQuarantined.first?.id, poison.id)
        XCTAssertEqual(stillQuarantined.first?.quarantined?.kind, .permanent)
    }

    /// #675: the account-deletion discard (`DurableQueue.discardAll`) DOES
    /// cover quarantined entries — deleting the account deletes its data, and
    /// a quarantine is a retention state, not a protection.
    func testAccountDeletionDiscardsQuarantinedEntriesToo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let queue = try DurableQueue<TestQueuePayload>(directoryURL: directory, filename: "queue.json")
        let poison = DurableQueueItem(accountUserID: user, payload: TestQueuePayload(value: "poison"))
        try await queue.enqueue(poison)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 1...DurableQueueItem<TestQueuePayload>.maxPermanentAttempts {
            try await queue.markFailure(
                id: poison.id,
                accountUserID: user,
                error: "constraint",
                classification: .permanent,
                code: "23514",
                now: now
            )
            now = now.addingTimeInterval(30)
        }
        let quarantinedBeforeDelete = await queue.quarantinedCount(for: user)
        XCTAssertEqual(quarantinedBeforeDelete, 1)

        try await queue.discardAll(accountUserID: user, reason: "account-deleted", now: now)
        let activeAfterDelete = await queue.count(for: user)
        let quarantinedAfterDelete = await queue.quarantinedCount(for: user)
        XCTAssertEqual(activeAfterDelete, 0)
        XCTAssertEqual(quarantinedAfterDelete, 0)
    }
}

private struct TestQueuePayload: Codable, Equatable, Sendable {
    let value: String
}
