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
        try await queue.markFailure(id: item.id, accountUserID: user, error: "offline", now: now)
        let notDue = await queue.items(for: user, dueAt: now)
        let due = await queue.items(for: user, dueAt: now.addingTimeInterval(5))
        XCTAssertTrue(notDue.isEmpty)
        XCTAssertEqual(due.count, 1)
        try await queue.remove(id: item.id, accountUserID: user, reason: "uploaded", now: now)
        let breadcrumbs = await queue.breadcrumbs(for: user)
        XCTAssertEqual(breadcrumbs.count, 1)
    }
}
