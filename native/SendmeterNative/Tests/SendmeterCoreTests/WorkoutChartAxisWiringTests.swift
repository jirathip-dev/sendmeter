import XCTest

/// #880: the Workout History HR and effort charts must pin their Y-axis
/// marks to the LEADING edge so the plot fills the full card width. These
/// SwiftUI views live in the Xcode app target, outside SwiftPM, so the
/// invariant is asserted on the source text (the HistoryTapDetailWiringTests
/// pattern); the hosted Xcode compile gate covers type checking.
///
/// A `chartYAxis` whose `AxisMarks` omit `position` lets Swift Charts place
/// the labels automatically — in the workout-detail card that resolves to a
/// trailing axis: a permanently reserved gutter at the plot's right edge,
/// with the value/unit labels ("140 bpm", "10 eff") sitting detached from
/// the data. Every other chart in the app pins `AxisMarks(position: .leading)`.
/// If a trailing gutter ever returns, one of these assertions goes red.
final class WorkoutChartAxisWiringTests: XCTestCase {
    func testHrChartPinsYAxisToLeadingEdge() {
        let hrChart = code(source("Sources/Features/History/WorkoutHrChartView.swift"))
        assertYAxisPinnedLeading(hrChart, fileLabel: "WorkoutHrChartView.swift")
    }

    func testEffortChartPinsYAxisToLeadingEdge() {
        let effortChart = code(source("Sources/Features/History/WorkoutEffortChartView.swift"))
        assertYAxisPinnedLeading(effortChart, fileLabel: "WorkoutEffortChartView.swift")
    }

    /// The plot must keep its value gridlines too — a hidden/empty Y axis
    /// would remove the gutter at the cost of losing the axis the chart
    /// stack's design expects.
    func testChartsKeepYAxisGridlines() {
        let hrChart = code(source("Sources/Features/History/WorkoutHrChartView.swift"))
        let effortChart = code(source("Sources/Features/History/WorkoutEffortChartView.swift"))
        XCTAssertTrue(exactBlock(hrChart, startingWith: ".chartYAxis {").contains("AxisGridLine()"))
        XCTAssertTrue(exactBlock(effortChart, startingWith: ".chartYAxis {").contains("AxisGridLine()"))
    }

    private func assertYAxisPinnedLeading(_ chartSource: String, fileLabel: String) {
        let yAxis = exactBlock(chartSource, startingWith: ".chartYAxis {")
        // Note: no closing paren — the real mark call continues with
        // `, values: …`, so the position parameter alone is the invariant.
        XCTAssertTrue(
            yAxis.contains("AxisMarks(position: .leading"),
            "\(fileLabel) must pin its Y-axis marks to the leading edge — an automatic "
                + "placement reserves a trailing label gutter and detaches the value labels"
        )
        XCTAssertTrue(
            yAxis.contains("AxisValueLabel"),
            "\(fileLabel) must keep rendering Y value labels (readable units, no clipping)"
        )
    }

    // MARK: source helpers (duplicated from HistoryTapDetailWiringTests; the
    // private helpers there are not reusable across test classes).

    private func source(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private func code(_ source: String) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlockComments
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    private func exactBlock(
        _ source: String,
        startingWith marker: String
    ) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant block: \(marker)")
            return ""
        }

        var depth = 0
        var cursor = openBrace.lowerBound
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[startRange.lowerBound...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }

        XCTFail("Unclosed source invariant block: \(marker)")
        return ""
    }

    private func countOccurrences(_ needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchStart = source.startIndex
        while let match = source.range(of: needle, range: searchStart..<source.endIndex) {
            count += 1
            searchStart = match.upperBound
        }
        return count
    }
}
