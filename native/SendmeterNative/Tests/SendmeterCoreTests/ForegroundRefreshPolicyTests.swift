import XCTest
@testable import SendmeterCore

final class ForegroundRefreshPolicyTests: XCTestCase {
    private let policy = ForegroundRefreshPolicy(staleAfter: 60)

    // MARK: Baseline / account bootstrap

    func testNeverLoadedDataAlwaysRefreshes() {
        // A cold launch or account switch has no baseline to trust — a full
        // refresh is mandatory even if realtime is connected and a recent
        // timestamp somehow exists.
        XCTAssertTrue(policy.shouldRefreshOnForeground(
            lastFullRefreshAt: 10,
            now: 20,
            realtimeConnected: true,
            hasLoadedData: false
        ))
    }

    func testNilLastRefreshRefreshes() {
        XCTAssertTrue(policy.shouldRefreshOnForeground(
            lastFullRefreshAt: nil,
            now: 20,
            realtimeConnected: true,
            hasLoadedData: true
        ))
    }

    // MARK: Realtime convergence fallback

    func testRealtimeDownRefreshesEvenWhenRecentlyLoaded() {
        // A dropped socket degrades to foreground refetch — the documented
        // convergence fallback — so a no-op foreground while realtime is down
        // could miss remote edits.
        XCTAssertTrue(policy.shouldRefreshOnForeground(
            lastFullRefreshAt: 20,
            now: 40,
            realtimeConnected: false,
            hasLoadedData: true
        ))
    }

    // MARK: Staleness window

    func testFreshLoadedConnectedForegroundSkips() {
        // The headline #673 acceptance: a no-change foreground (data loaded,
        // realtime healthy, last full refresh inside the window) issues 0
        // full-table fetches.
        XCTAssertFalse(policy.shouldRefreshOnForeground(
            lastFullRefreshAt: 20,
            now: 40,
            realtimeConnected: true,
            hasLoadedData: true
        ))
    }

    func testExactWindowBoundaryRefreshes() {
        // At exactly `staleAfter` seconds the data is considered stale.
        XCTAssertTrue(policy.shouldRefreshOnForeground(
            lastFullRefreshAt: 20,
            now: 80,
            realtimeConnected: true,
            hasLoadedData: true
        ))
    }

    func testBeyondWindowRefreshes() {
        XCTAssertTrue(policy.shouldRefreshOnForeground(
            lastFullRefreshAt: 20,
            now: 200,
            realtimeConnected: true,
            hasLoadedData: true
        ))
    }

    // MARK: Clock semantics

    func testMonotonicClockNeverGoesBackward() {
        // The caller uses a monotonic clock (systemUptime), so the delta can
        // never go negative and suppress every refresh for an NTP step. A
        // `now` == `lastFullRefreshAt` delta of 0 is fresh (not stale).
        XCTAssertFalse(policy.shouldRefreshOnForeground(
            lastFullRefreshAt: 40,
            now: 40,
            realtimeConnected: true,
            hasLoadedData: true
        ))
    }

    func testZeroStaleWindowAlwaysRefreshes() {
        let always = ForegroundRefreshPolicy(staleAfter: 0)
        XCTAssertTrue(always.shouldRefreshOnForeground(
            lastFullRefreshAt: 40,
            now: 40,
            realtimeConnected: true,
            hasLoadedData: true
        ))
    }
}
