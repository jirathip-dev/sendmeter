import XCTest
@testable import SendmeterCore

final class AccountScopedFetchTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    /// Models the recording request suspending for account A, then the model
    /// being reset for account B before A's completion resumes. The stale
    /// completion must not publish rows or claim that B's history is loaded.
    func testSuspendedAccountACompletionCannotPublishIntoAccountB() {
        let fetch = AccountScopedFetch(accountUserID: accountA)
        var publishedRows: [Int] = []
        var hasLoadedRecordings = false

        if fetch.canApply(to: accountB) {
            publishedRows = [1]
            hasLoadedRecordings = true
        }

        XCTAssertTrue(publishedRows.isEmpty)
        XCTAssertFalse(hasLoadedRecordings)
    }

    func testCompletionForTheCapturedAccountCanPublish() {
        let fetch = AccountScopedFetch(accountUserID: accountA)
        var publishedRows: [Int] = []
        var hasLoadedRecordings = false

        if fetch.canApply(to: accountA) {
            publishedRows = [1]
            hasLoadedRecordings = true
        }

        XCTAssertEqual(publishedRows, [1])
        XCTAssertTrue(hasLoadedRecordings)
    }
}
