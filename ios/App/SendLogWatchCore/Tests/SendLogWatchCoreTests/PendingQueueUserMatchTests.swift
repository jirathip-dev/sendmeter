import XCTest
import SendLogWatchCore

/// Regression coverage for issue #158: neither OfflineQueue nor
/// PendingSessionQueue used to be aware of which account was signed in when
/// an item was persisted to disk, so an item queued under Account A could
/// silently upload under Account B if the watch signed out/in before the
/// queue drained (Supabase RLS attributes inserts to `auth.uid()` at INSERT
/// time, not enqueue time). `shouldDrain` is the pure decision extracted
/// from both queues' `drain()` so it's testable without an actor/async
/// context or a live Supabase session.
final class PendingQueueUserMatchTests: XCTestCase {
    private let accountA = UUID()
    private let accountB = UUID()

    func testSameAccountDrains() {
        XCTAssertTrue(shouldDrain(itemUserId: accountA, currentUserId: accountA))
    }

    func testDifferentAccountsDoNotDrain() {
        XCTAssertFalse(shouldDrain(itemUserId: accountA, currentUserId: accountB))
    }

    func testLegacyNilStampIsQuarantinedWithoutAnOwnerProof() {
        // Pre-fix on-disk items never stamped a user id. Assigning them to the
        // current session would make an A→B transition a silent data leak.
        XCTAssertFalse(shouldDrain(itemUserId: nil, currentUserId: accountA))
    }

    func testStampedItemDoesNotDrainWhileSignedOut() {
        XCTAssertFalse(shouldDrain(itemUserId: accountA, currentUserId: nil))
    }

    func testSignedOutKeepsLegacyItemQuarantined() {
        // Nobody signed in means nothing drains, even an unstamped legacy
        // item — the signed-out boundary is still explicit even though the
        // ownerless legacy policy would quarantine it while signed in too.
        XCTAssertFalse(shouldDrain(itemUserId: nil, currentUserId: nil))
    }
}
