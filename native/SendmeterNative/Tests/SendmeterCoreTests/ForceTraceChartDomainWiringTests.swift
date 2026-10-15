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
        // #1038: one y-mapping for the trace, the line and the gridlines;
        // the guided domain is untouched, Free hold opts into the fit.
        XCTAssertTrue(
            trace.contains("FreeHoldChartDomain.fraction(of: kilograms, lower: domain.lower, upper: domain.upper)"),
            "every mark must go through the one shared mapping"
        )
        XCTAssertTrue(
            trace.contains("FreeHoldChartDomain.holdExtent(of: sampleRange.map { self.sample(at: $0).kilograms })"),
            "the fitted axis must fit the hold, not the ramp (a saved pull starts at 0 kg)"
        )
        XCTAssertFalse(
            trace.contains("max(0, kilograms) / maxValue"),
            "a second, private mapping would let the trace and its gridlines disagree"
        )
        let freeHoldView = code(source("Sources/Features/Force/FreeHoldFullscreenView.swift"))
        for flag in ["showsKilogramScale: true", "fitsDomainToData: true", "targetLabel: bestKilograms.map"] {
            XCTAssertTrue(freeHoldView.contains(flag), "Free hold chart must pass \(flag) (#1028 F4 scale, fitted axis, labelled Best line)")
        }
        XCTAssertTrue(
            trace.contains(".onChange(of: domainFeedStamp)"),
            "the live window must feed the domain tracker on window changes"
        )
        XCTAssertFalse(
            trace.contains("max(10, max(maxSample"),
            "the old per-frame auto-scale formula must be gone"
        )
    }

    /// #1038 G1: the guided fullscreen feed, the Free hold feed and the watch
    /// mirror all construct the same shared `ForceTraceChart`, so every
    /// surface draws the band at the identical level from the identical
    /// domain. The tab's inline Progressor feed is gone with the live gauge.
    func testEveryForceViewTraceFeedUsesTheSharedChart() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))

        XCTAssertEqual(
            countOccurrences("ForceTraceChart(", in: force),
            2,
            "the guided fullscreen and the watch mirror must render through the one shared chart"
        )
        let freeHold = code(source("Sources/Features/Force/FreeHoldFullscreenView.swift"))
        XCTAssertEqual(
            countOccurrences("ForceTraceChart(", in: freeHold),
            1,
            "the Free hold full screen must render through the same shared chart"
        )
        XCTAssertEqual(
            countOccurrences("ForceChartYDomain.maxValue(", in: force),
            1,
            "the domain computation must live inside the shared chart, not per surface"
        )
    }

    /// #1038 Conductor review: the Free hold controls stay AA and the
    /// recording action reads as THE action; the Force tab's collapsed title
    /// sits on an opaque bar (the iOS 26 scroll-edge blur showed the tiles).
    func testFreeHoldControlsAndForceTitleBarContracts() {
        let freeHold = code(source("Sources/Features/Force/FreeHoldFullscreenView.swift"))
        XCTAssertTrue(
            freeHold.contains("GuidedGlassButtonStyle(tint: SendmeterStyle.alert, label: SendmeterStyle.alertPillText)"),
            "enabled Finish must use the AA pill label, not the raw danger hue (2.1:1 light)"
        )
        XCTAssertFalse(
            freeHold.contains("GuidedGlassButtonStyle(tint: SendmeterStyle.alert))"),
            "Finish must not fall back to the raw danger label"
        )
        XCTAssertTrue(
            freeHold.contains("GuidedGlassButtonStyle(tint: SendmeterStyle.textDisabled)"),
            "disabled Finish takes the palette's disabled text"
        )
        let controls = exactBlock(freeHold, startingWith: "private var controls: some View")
        XCTAssertTrue(
            controls.contains(".foregroundStyle(SendmeterStyle.onPrimary)")
                && controls.contains("SendmeterStyle.primary,"),
            "Stop & save is the filled primary action while recording"
        )
        XCTAssertFalse(
            controls.contains("GuidedGlassButtonStyle"),
            "Stop & save must not use the 12 % glass fill (read as disabled in light)"
        )
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        XCTAssertTrue(force.contains(".modifier(OpaqueCanvasNavigationBar())"))
        XCTAssertTrue(force.contains(".toolbarBackground(SendmeterStyle.canvas, for: .navigationBar)"))
        XCTAssertTrue(force.contains("bar.scrollEdgeEffectHidden(true, for: .top)"))
        XCTAssertFalse(
            force.contains(".toolbarBackground(.visible, for: .navigationBar)"),
            "a forced-visible bar background hid the large \"Force\" title"
        )
    }

    private func exactBlock(_ source: String, startingWith marker: String) -> String {
        guard let start = source.range(of: marker),
              let open = source.range(of: "{", range: start.upperBound..<source.endIndex)
        else {
            XCTFail("Missing source block: \(marker)")
            return ""
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        return String(source[start.lowerBound...])
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
