import Foundation
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

    func testEqualizedRowHeightIncludesTheFetchingReservation() {
        let settledStates: [CGFloat] = [112, 174, 236]
        let fetchingState: CGFloat = 252
        let rowHeight = DashboardCardLayout.equalizedRowHeight([132] + settledStates + [fetchingState])

        XCTAssertEqual(rowHeight, fetchingState)
        XCTAssertTrue((settledStates + [fetchingState]).allSatisfy { $0 <= rowHeight })
    }

    func testDashboardReservesEveryStateWithTheFetchingProgressViewFootprint() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let dashboardSourceURL = testFile
            .deletingLastPathComponent() // SendmeterCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SendmeterNative
            .appendingPathComponent("Sources/Features/Dashboard/DashboardView.swift")
        let source = try String(contentsOf: dashboardSourceURL, encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "isFetching: true").count - 1, 3)
        XCTAssertTrue(source.contains("if isFetching {\n                    ProgressView()"))
    }

    func testEqualizedRowHeightIsZeroWithoutChildren() {
        XCTAssertEqual(DashboardCardLayout.equalizedRowHeight([]), 0)
    }
}
