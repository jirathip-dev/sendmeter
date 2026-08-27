import XCTest
@testable import SendmeterCore

final class HealthRefreshPolicyTests: XCTestCase {
    private let policy = HealthRefreshPolicy(coalescingWindow: 10)

    private func started(_ offset: TimeInterval, from base: TimeInterval = 1000) -> TimeInterval {
        base + offset
    }

    func testFirstRefreshAlwaysRuns() {
        let base: TimeInterval = 1000
        XCTAssertTrue(policy.shouldRefresh(trigger: .appear, lastStartedAt: nil, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .foreground, lastStartedAt: nil, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .background, lastStartedAt: nil, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .manual, lastStartedAt: nil, now: base))
    }

    func testAppearWithinWindowIsCoalesced() {
        let base: TimeInterval = 1000
        let last = started(-3, from: base)
        XCTAssertFalse(policy.shouldRefresh(trigger: .appear, lastStartedAt: last, now: base))
        XCTAssertFalse(policy.shouldRefresh(trigger: .foreground, lastStartedAt: last, now: base))
        XCTAssertFalse(policy.shouldRefresh(trigger: .background, lastStartedAt: last, now: base))
    }

    func testRefreshStrictlyOutsideWindowRuns() {
        let base: TimeInterval = 1000
        // Strictly beyond the window, unlike the boundary case.
        let last = started(-(policy.coalescingWindow + 1), from: base)
        XCTAssertTrue(policy.shouldRefresh(trigger: .appear, lastStartedAt: last, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .foreground, lastStartedAt: last, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .background, lastStartedAt: last, now: base))
    }

    func testManualRefreshAlwaysRunsEvenInsideWindow() {
        let base: TimeInterval = 1000
        let last = started(-1, from: base)
        XCTAssertTrue(policy.shouldRefresh(trigger: .manual, lastStartedAt: last, now: base))
    }

    func testExactlyAtWindowBoundaryRuns() {
        let base: TimeInterval = 1000
        let last = started(-policy.coalescingWindow, from: base)
        XCTAssertTrue(policy.shouldRefresh(trigger: .foreground, lastStartedAt: last, now: base))
    }

    /// #844 trigger→toast decision matrix: only a genuinely user-initiated
    /// sync may confirm with a toast. Automatic appear/foreground/background
    /// refreshes must stay silent (sync progress lives in state only).
    func testOnlyUserInitiatedTriggerMayShowSyncConfirmationToast() {
        XCTAssertTrue(HealthRefreshTrigger.manual.isUserInitiated)
        XCTAssertFalse(HealthRefreshTrigger.appear.isUserInitiated)
        XCTAssertFalse(HealthRefreshTrigger.foreground.isUserInitiated)
        XCTAssertFalse(HealthRefreshTrigger.background.isUserInitiated)
    }
}
