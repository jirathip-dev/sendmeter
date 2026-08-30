import XCTest

final class RecoveryInputsWiringTests: XCTestCase {
    private var source: String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent("Sources/Features/Dashboard/RecoveryInputsSheet.swift")
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func testRecoveryChartsPinContainmentAndBothTrendWiring() {
        XCTAssertTrue(source.contains("yStart: .value(\"Baseline\""))
        XCTAssertTrue(source.contains(".chartPlotStyle { plotArea in"))
        XCTAssertTrue(source.contains("plotArea.clipped()"))
        XCTAssertTrue(source.contains(".value(\"28d EWMA\""))
        XCTAssertTrue(source.contains("StrokeStyle(lineWidth: 1.5, dash:"))
        XCTAssertTrue(source.contains("RecoveryBarGradient.classification"))
        XCTAssertTrue(source.contains("RecoveryBarGradient.position"))
    }
}
