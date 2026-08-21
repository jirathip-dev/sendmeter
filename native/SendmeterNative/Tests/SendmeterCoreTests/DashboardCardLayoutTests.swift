import XCTest
@testable import SendmeterCore

/// Pins the pure equal-height policy used by the native Dashboard row without
/// requiring a simulator layout pass.
final class DashboardCardLayoutTests: XCTestCase {
    func testEqualizedRowHeightUsesTheTallestMeasuredChild() {
        XCTAssertEqual(
            DashboardCardLayout.equalizedRowHeight([128, 244, 196]),
            244
        )
    }

    func testEqualizedRowHeightNeverShrinksAReservedSendConditionsState() {
        let sendConditionsStates: [CGFloat] = [112, 174, 236]
        let rowHeight = DashboardCardLayout.equalizedRowHeight([132] + sendConditionsStates)

        XCTAssertEqual(rowHeight, 236)
        XCTAssertTrue(sendConditionsStates.allSatisfy { $0 <= rowHeight })
    }

    func testEqualizedRowHeightIsZeroWithoutChildren() {
        XCTAssertEqual(DashboardCardLayout.equalizedRowHeight([]), 0)
    }
}
