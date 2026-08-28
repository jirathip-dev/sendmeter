import Foundation
import XCTest
@testable import SendmeterCore

/// The SwiftUI Force surfaces are outside the host SwiftPM module. These
/// source invariants keep their user-facing accessibility and contrast seams
/// wired to the tested Core contracts until the hosted Xcode compile gate runs.
final class ForceAccessibilityWiringTests: XCTestCase {
    func testForceTraceUsesTheContrastAwareChartRecipe() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let trace = exactType(force, startingWith: "struct ForceTraceChart: View")
        let normalized = normalizeWhitespace(trace)

        XCTAssertTrue(normalized.contains("ChartToken.forceTraceGridColor(scheme)"))
        XCTAssertTrue(normalized.contains("ChartToken.forceTraceBandOpacity(scheme)"))
        XCTAssertTrue(normalized.contains(".background(ChartToken.forceTraceBackground(scheme), in:"))
    }

    func testEveryLiveForceTraceAnnouncesItsPeakSummary() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let manual = code(source("Sources/Features/Force/ManualForceFullscreen.swift"))

        XCTAssertEqual(
            countOccurrences("ForceTraceAccessibility.liveSummary(", in: force),
            3,
            "guided, Progressor, and Watch live traces must all announce a peak"
        )
        XCTAssertEqual(
            countOccurrences("ForceTraceAccessibility.liveSummary(", in: manual),
            1,
            "manual fullscreen's live trace must announce a peak"
        )
        XCTAssertFalse(force.contains(".accessibilityLabel(\"Live force trace\")"))
        XCTAssertFalse(manual.contains(".accessibilityLabel(\"Live force trace\")"))
    }

    func testLiveSummaryNamesPeakForceInKilograms() {
        let summary = ForceTraceAccessibility.liveSummary(peakKilograms: 22.4)

        XCTAssertTrue(summary.contains("Live force trace"))
        XCTAssertTrue(summary.contains("peak force"))
        XCTAssertTrue(summary.contains("22.4"))
        XCTAssertTrue(summary.contains("kilograms"))
        XCTAssertEqual(
            ForceTraceAccessibility.liveSummary(peakKilograms: nil),
            "Live force trace, no peak recorded yet"
        )
        XCTAssertEqual(
            ForceTraceAccessibility.liveSummary(peakKilograms: .infinity),
            "Live force trace, no peak recorded yet"
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

    private func exactType(_ source: String, startingWith marker: String) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant type: \(marker)")
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

        XCTFail("Unclosed source invariant type: \(marker)")
        return ""
    }

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
