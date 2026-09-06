import Foundation
import XCTest
@testable import SendmeterCore

/// #900: the SwiftUI Force surfaces are outside the host SwiftPM module.
/// These source invariants keep every live force-trace surface on the shared
/// Core Y-domain (`ForceChartYDomain`/`ForceChartYDomainTracker`) until the
/// hosted Xcode compile gate runs — including the #869 trap: they must fail
/// on the broken per-frame auto-scale form, not just pass on the fixed one.
final class ForceTraceChartDomainWiringTests: XCTestCase {
    /// The one shared chart type (used by the guided fullscreen, the inline
    /// Progressor card, the watch mirror, and saved-history charts) draws its
    /// Y-domain through the Core function — never a raw per-frame formula.
    func testForceTraceChartDrawsThroughTheSharedCoreDomain() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let trace = exactType(force, startingWith: "struct ForceTraceChart: View")

        XCTAssertEqual(
            countOccurrences("ForceChartYDomain.maxValue(", in: trace),
            1,
            "the shared chart must compute its Y-domain through ForceChartYDomain exactly once"
        )
        XCTAssertTrue(
            trace.contains("heldPeakKilograms: domainTracker.heldPeakKilograms"),
            "the drawing pass must consult the #900 rep-boundary hold"
        )
        XCTAssertTrue(
            trace.contains(".onChange(of: domainFeedStamp)"),
            "the live window must feed the domain tracker on window changes"
        )
        XCTAssertFalse(
            trace.contains("max(10, max(maxSample"),
            "the old per-frame auto-scale formula must be gone"
        )
    }

    /// The guided fullscreen feed AND the inline Progressor-card feed both
    /// construct the same shared `ForceTraceChart` (with the stage band), so
    /// they draw the band at the identical level from the identical domain.
    /// Three feeds total in ForceView: fullscreen, inline card, watch mirror.
    func testEveryForceViewTraceFeedUsesTheSharedChart() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))

        XCTAssertEqual(
            countOccurrences("ForceTraceChart(", in: force),
            3,
            "fullscreen, inline Progressor card, and watch mirror must all render through the one shared chart"
        )
        XCTAssertEqual(
            countOccurrences("ForceChartYDomain.maxValue(", in: force),
            1,
            "the domain computation must live inside the shared chart, not per surface"
        )
    }

    private func source(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \\(fileURL.path): \\(error)")
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

    private func exactType(_ source: String, startingWith marker: String) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant type: \\(marker)")
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

        XCTFail("Unclosed source invariant type: \\(marker)")
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
