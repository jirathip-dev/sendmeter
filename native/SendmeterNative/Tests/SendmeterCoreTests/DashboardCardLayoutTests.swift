import XCTest
@testable import SendmeterCore

/// Pins the measured Dashboard context-row height used by both native cards
/// without requiring a simulator layout pass.
final class DashboardCardLayoutTests: XCTestCase {
    func testContextRowCardHeightMatchesTrainingBlockBaseline() {
        XCTAssertEqual(DashboardCardLayout.contextRowCardHeight, 314)
    }
}
