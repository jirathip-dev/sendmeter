import XCTest
@testable import SendmeterCore

final class AccountScopedFetchTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    /// The production publication seam models a request suspending for
    /// account A, then the model being reset for account B before A's
    /// completion resumes. The stale completion must not publish rows or
    /// claim that B's history is loaded.
    func testSuspendedAccountACompletionCannotPublishIntoAccountB() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)
        var publishedRows: [Int] = []
        var hasLoadedRecordings = false

        let published = fetch.publishIfCurrent(to: accountB, accountEpoch: 1) {
            publishedRows = [1]
            hasLoadedRecordings = true
        }

        XCTAssertFalse(published)
        XCTAssertTrue(publishedRows.isEmpty)
        XCTAssertFalse(hasLoadedRecordings)
    }

    func testCompletionForTheCapturedAccountCanPublish() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)
        var publishedRows: [Int] = []
        var hasLoadedRecordings = false

        let published = fetch.publishIfCurrent(to: accountA, accountEpoch: 0) {
            publishedRows = [1]
            hasLoadedRecordings = true
        }

        XCTAssertTrue(published)
        XCTAssertEqual(publishedRows, [1])
        XCTAssertTrue(hasLoadedRecordings)
    }

    func testStaleRecordingCompletionCannotReplaceTheCurrentRows() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)
        var recordings = [2]

        let published = fetch.publishIfCurrent(to: accountB, accountEpoch: 1) {
            recordings = [1]
        }

        XCTAssertFalse(published)
        XCTAssertEqual(recordings, [2])
    }

    func testRecordingCompletionForTheCurrentAccountCanReplaceRows() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)
        var recordings = [2]

        let published = fetch.publishIfCurrent(to: accountA, accountEpoch: 0) {
            recordings = [1]
        }

        XCTAssertTrue(published)
        XCTAssertEqual(recordings, [1])
    }

    func testAccountACompletionIsRejectedAfterABASwitch() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)

        XCTAssertFalse(fetch.canApply(to: accountA, accountEpoch: 1))
        XCTAssertFalse(fetch.canApply(to: accountB, accountEpoch: 1))
        XCTAssertFalse(fetch.canApply(to: accountA, accountEpoch: 2))

        let currentA = AccountScopedFetch(accountUserID: accountA, accountEpoch: 2)
        XCTAssertTrue(currentA.canApply(to: accountA, accountEpoch: 2))
    }

    func testOnlyTheActiveCompletionOwnerCanFinishTheRefresh() {
        let first = AccountScopedCompletion(
            fetch: AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)
        )
        let second = AccountScopedCompletion(
            fetch: AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)
        )

        XCTAssertFalse(first.owns(
            currentUserID: accountA,
            accountEpoch: 0,
            activeOwner: second
        ))
        XCTAssertTrue(second.owns(
            currentUserID: accountA,
            accountEpoch: 0,
            activeOwner: second
        ))
        XCTAssertFalse(second.owns(
            currentUserID: accountA,
            accountEpoch: 1,
            activeOwner: second
        ))
    }

    func testOneCapturedQueueScopeRejectsStaleCountAndErrorPublication() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 0)
        var publishedCount: Int?
        var publishedError: String?

        XCTAssertFalse(fetch.publishIfCurrent(to: accountA, accountEpoch: 1) {
            publishedCount = 3
        })
        XCTAssertFalse(fetch.publishIfCurrent(to: accountA, accountEpoch: 1) {
            publishedError = "old account failed"
        })

        XCTAssertNil(publishedCount)
        XCTAssertNil(publishedError)
    }

    func testOneCapturedQueueScopePublishesCountAndErrorForItsOwner() {
        let fetch = AccountScopedFetch(accountUserID: accountA, accountEpoch: 4)
        var publishedCount: Int?
        var publishedError: String?

        XCTAssertTrue(fetch.publishIfCurrent(to: accountA, accountEpoch: 4) {
            publishedCount = 3
        })
        XCTAssertTrue(fetch.publishIfCurrent(to: accountA, accountEpoch: 4) {
            publishedError = "current account failed"
        })

        XCTAssertEqual(publishedCount, 3)
        XCTAssertEqual(publishedError, "current account failed")
    }
}
