import Foundation
import XCTest
@testable import Sendmeter

/// The SwiftUI gesture itself needs a device to exercise. These invariants pin
/// the source-level boundary so a future refactor cannot silently make the
/// diagnostic flag production-capable or turn B into a global haptic mute.
final class StructuralHapticsWiringTests: XCTestCase {
    func testLaunchSelectionIsDebugOnlyAndBoundAtTheRoot() {
        let app = code(source("Sources/App/SendmeterNativeApp.swift"))

        XCTAssertTrue(app.contains("#if DEBUG"))
        XCTAssertTrue(app.contains("arguments: CommandLine.arguments"))
        XCTAssertTrue(app.contains("debugBuild: true"))
        XCTAssertTrue(app.contains("structuralHapticMode = .normal"))
        XCTAssertTrue(
            app.contains("RootView(structuralHapticMode: structuralHapticMode)")
        )
        XCTAssertTrue(
            app.contains("StructuralDefaultButtonStyle(mode: structuralHapticMode)")
        )
        XCTAssertTrue(
            app.contains(
                ".environment(\\.structuralHapticTapPolicy, structuralHapticMode.tapPolicy)"
            )
        )
    }

    func testRootAndExplicitGestureSourcesRemainSeparate() {
        let structural = code(source("Sources/App/StructuralHaptics.swift"))
        let modifier = exactBlock(
            structural,
            startingWith: "public struct HapticTapModifier: ViewModifier"
        )
        let style = exactBlock(
            structural,
            startingWith: "public struct StructuralDefaultButtonStyle: PrimitiveButtonStyle"
        )

        XCTAssertTrue(modifier.contains("@Environment(\\.structuralHapticTapPolicy)"))
        XCTAssertTrue(modifier.contains("private let source: HapticTapSource"))
        XCTAssertTrue(modifier.contains("guard policy.allows(source)"))
        XCTAssertTrue(modifier.contains("self.source = .explicit"))
        XCTAssertTrue(style.contains("mode.tapPolicy.rootDefaultEnabled"))
        XCTAssertTrue(style.contains(".structuralHapticTap()"))
        XCTAssertFalse(
            style.contains(".hapticTap()"),
            "the root path must not be indistinguishable from explicit call sites"
        )
        XCTAssertTrue(structural.contains("buttonStyle(style).hapticTap()"))
    }

    func testDiagnosticLabelCannotCaptureTouchesAndOverlaysHaveBoundedShapes() {
        let app = code(source("Sources/App/SendmeterNativeApp.swift"))
        XCTAssertTrue(app.contains("StructuralHapticDiagnosticBanner(label: label)"))
        XCTAssertTrue(app.contains(".allowsHitTesting(false)"))

        let design = code(source("Sources/App/DesignSystem.swift"))
        let errorBanner = exactBlock(
            design,
            startingWith: "public struct ErrorBanner: View"
        )
        let toast = exactBlock(design, startingWith: "public struct AppToast: View")

        XCTAssertTrue(
            errorBanner.contains(
                ".contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))"
            )
        )
        XCTAssertTrue(toast.contains(".contentShape(Capsule())"))
        XCTAssertFalse(errorBanner.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(toast.contains(".contentShape(Rectangle())"))
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

    private func exactBlock(_ source: String, startingWith marker: String) -> String {
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
}
