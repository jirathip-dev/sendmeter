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
}

private struct TestQueuePayload: Codable, Equatable, Sendable {
    let value: String
}
