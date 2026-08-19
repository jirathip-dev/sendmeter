import XCTest
@testable import SendmeterCore

final class RoutineUndoTests: XCTestCase {
    private let account = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let otherAccount = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let sessionID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testDeleteFailureKeepsTheAccountScopedIntentAfterUploadCompletion() {
        let receipt = SessionLogReceipt(sessionID: sessionID, accountUserID: account)
        var state = RoutineUndoState()

        XCTAssertTrue(state.claim(receipt, currentUserID: account))
        // The server insert may already have completed, and the soft-delete
        // may fail. Until a later durable retry succeeds, the local marker
        // must continue hiding the row instead of allowing a refresh to
        // resurrect it.
        XCTAssertTrue(state.hasPendingDelete(sessionID: sessionID, accountUserID: account))
        XCTAssertFalse(state.claim(receipt, currentUserID: account))
        XCTAssertTrue(state.hasPendingDelete(sessionID: sessionID, accountUserID: account))
    }

    func testAccountSwitchCannotCompleteOrApplyAnotherAccountsDeleteIntent() {
        let receipt = SessionLogReceipt(sessionID: sessionID, accountUserID: account)
        var state = RoutineUndoState()

        XCTAssertTrue(state.claim(receipt, currentUserID: account))
        XCTAssertFalse(state.markDeleteCompleted(receipt, currentUserID: otherAccount))
        XCTAssertFalse(state.hasPendingDelete(sessionID: sessionID, accountUserID: otherAccount))
        XCTAssertTrue(state.hasPendingDelete(sessionID: sessionID, accountUserID: account))
        XCTAssertFalse(state.claim(receipt, currentUserID: otherAccount))
    }

    func testRestoredDeleteIntentClaimsTheMatchingInsertAndCompletesOnlyForItsAccount() {
        let receipt = SessionLogReceipt(sessionID: sessionID, accountUserID: account)
        var state = RoutineUndoState()

        state.restorePendingDelete(receipt, currentUserID: account)
        XCTAssertTrue(state.isClaimed(receipt))
        XCTAssertFalse(state.claim(receipt, currentUserID: account))
        XCTAssertTrue(state.markDeleteCompleted(receipt, currentUserID: account))
        XCTAssertFalse(state.hasPendingDelete(sessionID: sessionID, accountUserID: account))
    }

    func testDiscardedDeleteIntentReleasesTheClaimForItsQueuedInsert() {
        let receipt = SessionLogReceipt(sessionID: sessionID, accountUserID: account)
        var state = RoutineUndoState()

        XCTAssertTrue(state.claim(receipt, currentUserID: account))
        XCTAssertTrue(state.discardPendingDelete(receipt, currentUserID: account))
        XCTAssertFalse(state.isClaimed(receipt))
        XCTAssertFalse(state.hasPendingDelete(sessionID: sessionID, accountUserID: account))
        XCTAssertFalse(state.discardPendingDelete(receipt, currentUserID: otherAccount))
    }
}
