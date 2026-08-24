import XCTest
@testable import SendmeterCore

final class QueueRetryPolicyTests: XCTestCase {
    func testBeforeUploadWaitsForOwnerAndStopsOnlyForMissingOrQuarantinedItems() {
        XCTAssertEqual(
            QueueRetryPolicy.beforeUpload(
                isClaimed: true,
                hasItem: true,
                isQuarantined: false
            ),
            .waitForOwner
        )
        XCTAssertEqual(
            QueueRetryPolicy.beforeUpload(
                isClaimed: false,
                hasItem: false,
                isQuarantined: false
            ),
            .stop
        )
        XCTAssertEqual(
            QueueRetryPolicy.beforeUpload(
                isClaimed: false,
                hasItem: true,
                isQuarantined: true
            ),
            .stop
        )
        XCTAssertEqual(
            QueueRetryPolicy.beforeUpload(
                isClaimed: false,
                hasItem: true,
                isQuarantined: false
            ),
            .upload
        )
    }

    func testAfterUploadWaitsOnlyForACompetingOwnerAndStopsOnFailureOrSuccess() {
        XCTAssertEqual(
            QueueRetryPolicy.afterUpload(
                uploaded: false,
                recordedFailure: false,
                ownerIsClaimed: true
            ),
            .waitForOwner
        )
        XCTAssertEqual(
            QueueRetryPolicy.afterUpload(
                uploaded: false,
                recordedFailure: true,
                ownerIsClaimed: true
            ),
            .stop
        )
        XCTAssertEqual(
            QueueRetryPolicy.afterUpload(
                uploaded: true,
                recordedFailure: false,
                ownerIsClaimed: false
            ),
            .stop
        )
        XCTAssertEqual(
            QueueRetryPolicy.afterUpload(
                uploaded: false,
                recordedFailure: false,
                ownerIsClaimed: false
            ),
            .stop
        )
    }
}
