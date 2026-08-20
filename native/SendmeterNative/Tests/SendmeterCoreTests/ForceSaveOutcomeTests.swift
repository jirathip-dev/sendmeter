import XCTest
@testable import SendmeterCore

final class ForceSaveOutcomeTests: XCTestCase {
    func testStaleCompletionLeavesHandsFreeOwnedByTheCurrentAccount() {
        let outcome = ForceSaveOutcome.stale

        XCTAssertFalse(outcome.didPersist)
        XCTAssertFalse(outcome.shouldDisarmHandsFree)
        XCTAssertFalse(outcome.shouldReportHandsFreeFailure)
    }

    func testPersistenceFailureDisarmsAndReportsHandsFree() {
        let outcome = ForceSaveOutcome.failed

        XCTAssertFalse(outcome.didPersist)
        XCTAssertTrue(outcome.shouldDisarmHandsFree)
        XCTAssertTrue(outcome.shouldReportHandsFreeFailure)
    }

    func testSavedCompletionRearmsWithoutFailureSurface() {
        let outcome = ForceSaveOutcome.saved

        XCTAssertTrue(outcome.didPersist)
        XCTAssertFalse(outcome.shouldDisarmHandsFree)
        XCTAssertFalse(outcome.shouldReportHandsFreeFailure)
    }
}
