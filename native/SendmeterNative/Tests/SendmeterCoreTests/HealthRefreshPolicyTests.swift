import XCTest
@testable import SendmeterCore

final class HealthRefreshPolicyTests: XCTestCase {
    private let policy = HealthRefreshPolicy(coalescingWindow: 10)

    private func started(_ offset: TimeInterval, from base: Date) -> Date {
        base.addingTimeInterval(offset)
    }

    func testFirstRefreshAlwaysRuns() {
        let base = Date()
        XCTAssertTrue(policy.shouldRefresh(trigger: .appear, lastStartedAt: nil, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .foreground, lastStartedAt: nil, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .manual, lastStartedAt: nil, now: base))
    }

    func testAppearWithinWindowIsCoalesced() {
        let base = Date()
        let last = started(-3, from: base)
        XCTAssertFalse(policy.shouldRefresh(trigger: .appear, lastStartedAt: last, now: base))
        XCTAssertFalse(policy.shouldRefresh(trigger: .foreground, lastStartedAt: last, now: base))
    }

    func testRefreshOutsideWindowRuns() {
        let base = Date()
        let last = started(-policy.coalescingWindow, from: base)
        XCTAssertTrue(policy.shouldRefresh(trigger: .appear, lastStartedAt: last, now: base))
        XCTAssertTrue(policy.shouldRefresh(trigger: .foreground, lastStartedAt: last, now: base))
    }

    func testManualRefreshAlwaysRunsEvenInsideWindow() {
        let base = Date()
        let last = started(-1, from: base)
        XCTAssertTrue(policy.shouldRefresh(trigger: .manual, lastStartedAt: last, now: base))
    }

    func testExactlyAtWindowBoundaryRuns() {
        let base = Date()
        let last = started(-policy.coalescingWindow, from: base)
        XCTAssertTrue(policy.shouldRefresh(trigger: .foreground, lastStartedAt: last, now: base))
    }
}
