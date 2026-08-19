import XCTest
@testable import SendmeterCore

final class QueueUploadCoordinationTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let itemID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testOneAccountItemIsSingleFlightUntilItsOwnerReleases() {
        let key = QueueUploadKey(itemID: itemID, accountUserID: accountA)
        var coordinator = QueueUploadClaimCoordinator()

        let first = coordinator.claim(key)
        XCTAssertNotNil(first)
        XCTAssertNil(coordinator.claim(key))

        if let first {
            coordinator.release(first)
        }
        XCTAssertFalse(coordinator.isClaimed(key))
        XCTAssertNotNil(coordinator.claim(key))
    }

    /// Models an A→B→A switch while A's first upload is suspended. B can
    /// claim its own account/item key, but returning to A must remain single
    /// flight until A's original owner releases.
    func testSuspendedAccountAClaimSurvivesABASwitchAndBIsIndependent() throws {
        let keyA = QueueUploadKey(itemID: itemID, accountUserID: accountA)
        let keyB = QueueUploadKey(itemID: itemID, accountUserID: accountB)
        var coordinator = QueueUploadClaimCoordinator()

        let originalA = try XCTUnwrap(coordinator.claim(keyA))

        // clearLoadedData() while switching accounts leaves the live A claim
        // alone. B can still claim its distinct account-scoped item key.
        let claimB = try XCTUnwrap(coordinator.claim(keyB))
        XCTAssertTrue(coordinator.isClaimed(keyA))
        XCTAssertTrue(coordinator.isClaimed(keyB))

        // Switching back to A must not permit a duplicate while the original
        // A task is still suspended.
        XCTAssertNil(coordinator.claim(keyA))

        coordinator.release(originalA)
        XCTAssertFalse(coordinator.isClaimed(keyA))

        // Once the original owner releases, A can claim again while B's
        // independent claim is still live.
        let resumedA = try XCTUnwrap(coordinator.claim(keyA))
        XCTAssertTrue(coordinator.isClaimed(keyB))

        coordinator.release(resumedA)
        coordinator.release(claimB)
        XCTAssertFalse(coordinator.isClaimed(keyA))
        XCTAssertFalse(coordinator.isClaimed(keyB))
    }
}
