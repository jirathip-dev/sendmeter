import XCTest
import SendLogWatchCore

/// Issue #472b: the watch surfaces the QUARANTINE count (#475) but had no
/// signal at all for "we have not synced in a while" — a healthy-looking,
/// non-quarantined queue could sit unsynced indefinitely with nothing on
/// screen to say so. These pin the honest-states rule: unknown (never
/// synced) must never render the same as "fine" (`.current`).
final class SyncFreshnessPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoPendingItemsIsAlwaysCurrentRegardlessOfLastSync() {
        XCTAssertEqual(
            SyncFreshnessPolicy.evaluate(lastSuccessfulSyncAt: nil, hasPending: false, now: now),
            .current
        )
        let longAgo = now.addingTimeInterval(-100_000)
        XCTAssertEqual(
            SyncFreshnessPolicy.evaluate(lastSuccessfulSyncAt: longAgo, hasPending: false, now: now),
            .current
        )
    }

    /// The core honest-states assertion: items are waiting, and nothing has
    /// EVER synced successfully — this must read as stale, not as current
    /// just because there's no elapsed duration to compare.
    func testPendingWithNoSuccessfulSyncEverIsStaleNotCurrent() {
        let result = SyncFreshnessPolicy.evaluate(lastSuccessfulSyncAt: nil, hasPending: true, now: now)
        XCTAssertEqual(result, .stale(lastSuccessfulSyncAt: nil))
    }

    func testPendingWithARecentSyncIsCurrent() {
        let recent = now.addingTimeInterval(-60)
        XCTAssertEqual(
            SyncFreshnessPolicy.evaluate(lastSuccessfulSyncAt: recent, hasPending: true, now: now),
            .current
        )
    }

    func testPendingWithAnOldSyncIsStale() {
        let old = now.addingTimeInterval(-SyncFreshnessPolicy.staleAfterS - 1)
        XCTAssertEqual(
            SyncFreshnessPolicy.evaluate(lastSuccessfulSyncAt: old, hasPending: true, now: now),
            .stale(lastSuccessfulSyncAt: old)
        )
    }

    func testExactlyAtTheStaleThresholdIsStale() {
        let boundary = now.addingTimeInterval(-SyncFreshnessPolicy.staleAfterS)
        XCTAssertEqual(
            SyncFreshnessPolicy.evaluate(lastSuccessfulSyncAt: boundary, hasPending: true, now: now),
            .stale(lastSuccessfulSyncAt: boundary)
        )
    }
}
