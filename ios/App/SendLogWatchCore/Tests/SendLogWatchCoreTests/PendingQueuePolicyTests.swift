import XCTest
import SendLogWatchCore

final class PendingQueuePolicyTests: XCTestCase {
    func testSuccessfulPersistStartsBackgroundDrain() {
        XCTAssertEqual(PendingQueuePolicy.actionAfterPersist(true), .drainQueued)
    }

    func testFailedPersistFallsBackToDirectUpload() {
        XCTAssertEqual(PendingQueuePolicy.actionAfterPersist(false), .uploadDirect)
    }

    func testSuccessfulDirectFallbackReportsUploaded() {
        XCTAssertEqual(
            PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: true),
            .uploadedDirect
        )
    }

    func testFailedDirectFallbackReportsLoss() {
        XCTAssertEqual(
            PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: false),
            .lost
        )
    }
}
