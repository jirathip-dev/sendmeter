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

    /// Models an A→B→A switch while A's first upload is suspended. The old
    /// task's deferred release runs after the new A task has claimed the same
    /// account/item key; it must not remove the replacement claim.
    func testSuspendedAccountAReleaseCannotRemoveReplacementAfterABASwitch() {
        let keyA = QueueUploadKey(itemID: itemID, accountUserID: accountA)
        let keyB = QueueUploadKey(itemID: itemID, accountUserID: accountB)
        var coordinator = QueueUploadClaimCoordinator()

        let originalA = coordinator.claim(keyA)
        XCTAssertNotNil(originalA)

        // clearLoadedData() while switching to B invalidates the old loaded
        // state, then B briefly owns its own account-scoped item key.
        coordinator.reset()
        let claimB = coordinator.claim(keyB)
        XCTAssertNotNil(claimB)

        // Switching back to A permits a fresh A claim while the original A
        // task is still suspended.
        coordinator.reset()
        let replacementA = coordinator.claim(keyA)
        XCTAssertNotNil(replacementA)
        XCTAssertNotEqual(originalA, replacementA)

        if let originalA {
            coordinator.release(originalA)
        }
        XCTAssertTrue(coordinator.isClaimed(keyA))

        if let claimB {
            coordinator.release(claimB)
        }
        XCTAssertTrue(coordinator.isClaimed(keyA))

        if let replacementA {
            coordinator.release(replacementA)
        }
        XCTAssertFalse(coordinator.isClaimed(keyA))
    }
}
