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

    func testLegacyNilStampTrustsCurrentSession() {
        // Pre-fix on-disk items never stamped a user id — trust whoever is
        // currently signed in rather than stranding them forever.
        XCTAssertTrue(shouldDrain(itemUserId: nil, currentUserId: accountA))
    }

    func testStampedItemDoesNotDrainWhileSignedOut() {
        XCTAssertFalse(shouldDrain(itemUserId: accountA, currentUserId: nil))
    }

    func testSignedOutBeatsLegacyTrust() {
        // Nobody signed in means nothing drains, even an unstamped legacy
        // item — the "signed out: never drain" guard fires before the
        // "legacy stamp: trust current session" guard is ever reached.
        XCTAssertFalse(shouldDrain(itemUserId: nil, currentUserId: nil))
    }
}
