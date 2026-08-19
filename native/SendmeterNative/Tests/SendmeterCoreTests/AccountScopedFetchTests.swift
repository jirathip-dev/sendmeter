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
        let fetch = AccountScopedFetch(accountUserID: accountA)
        var publishedRows: [Int] = []
        var hasLoadedRecordings = false

        let published = fetch.publishIfCurrent(to: accountB) {
            publishedRows = [1]
            hasLoadedRecordings = true
        }

        XCTAssertFalse(published)
        XCTAssertTrue(publishedRows.isEmpty)
        XCTAssertFalse(hasLoadedRecordings)
    }

    func testCompletionForTheCapturedAccountCanPublish() {
        let fetch = AccountScopedFetch(accountUserID: accountA)
        var publishedRows: [Int] = []
        var hasLoadedRecordings = false

        let published = fetch.publishIfCurrent(to: accountA) {
            publishedRows = [1]
            hasLoadedRecordings = true
        }

        XCTAssertTrue(published)
        XCTAssertEqual(publishedRows, [1])
        XCTAssertTrue(hasLoadedRecordings)
    }

    func testStaleRecordingCompletionCannotReplaceTheCurrentRows() {
        let fetch = AccountScopedFetch(accountUserID: accountA)
        var recordings = [2]

        let published = fetch.publishIfCurrent(to: accountB) {
            recordings = [1]
        }

        XCTAssertFalse(published)
        XCTAssertEqual(recordings, [2])
    }

    func testRecordingCompletionForTheCurrentAccountCanReplaceRows() {
        let fetch = AccountScopedFetch(accountUserID: accountA)
        var recordings = [2]

        let published = fetch.publishIfCurrent(to: accountA) {
            recordings = [1]
        }

        XCTAssertTrue(published)
        XCTAssertEqual(recordings, [1])
    }
}
