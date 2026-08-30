import Foundation
import SendmeterCore
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
        XCTAssertTrue(modifier.contains("if policy.allows(source)"))
        XCTAssertTrue(modifier.contains("self.source = .explicit"))
        XCTAssertTrue(modifier.contains("guard tracking, isEnabled, !muted else { return }"))
        XCTAssertTrue(modifier.contains("tracking = false"))
        XCTAssertTrue(modifier.contains("Haptics.shared.cancelTap()"))
        let productionBody = exactBlock(
            modifier,
            startingWith: "private func scrollSafeBody(content: Content) -> some View"
        )
        XCTAssertFalse(
            productionBody.contains("simultaneousGesture(TapGesture())"),
            "production explicit surfaces must not install a competing tap recognizer"
        )
        XCTAssertTrue(style.contains("mode.usesLegacyStructuralGesture"))
        XCTAssertTrue(style.contains("ScrollSafeStructuralButton(configuration: configuration)"))
        XCTAssertTrue(style.contains(".structuralHapticTap()"), "DEBUG A must retain the legacy control path")
        XCTAssertTrue(structural.contains("buttonStyle(StructuralButtonStyle(style: style))"))
        XCTAssertTrue(structural.contains("buttonStyle(StructuralPrimitiveButtonStyle(style: style))"))
        XCTAssertFalse(productionBody.contains("onTapGesture"))
        XCTAssertFalse(structural.contains("configuration.label.hapticTap"))
    }

    func testProductionPathHasNoGlobalZeroDistanceDragRecognizer() {
        let structuralPath = "Sources/App/StructuralHaptics.swift"
        let structural = code(source(structuralPath))
        let zeroDistanceDrag = "DragGesture(minimumDistance: 0)"
        let occurrenceCount = structural.components(separatedBy: zeroDistanceDrag).count - 1

        XCTAssertEqual(
            occurrenceCount,
            1,
            "the only zero-distance drag must be the DEBUG diagnostic implementation"
        )
        guard let debugRange = structural.range(of: "#if DEBUG"),
              let dragRange = structural.range(of: zeroDistanceDrag)
        else {
            XCTFail("Missing DEBUG legacy drag boundary")
            return
        }
        XCTAssertLessThan(debugRange.lowerBound, dragRange.lowerBound)

        let style = exactBlock(
            structural,
            startingWith: "public struct StructuralDefaultButtonStyle: PrimitiveButtonStyle"
        )
        XCTAssertTrue(style.contains("#if DEBUG"))
        XCTAssertTrue(style.contains("mode.usesLegacyStructuralGesture"))
        XCTAssertTrue(style.contains("ScrollSafeStructuralButton(configuration: configuration)"))

        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )
        var unexpectedFiles: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift",
                  fileURL.path != sourcesRoot.appendingPathComponent("App/StructuralHaptics.swift").path,
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            else { continue }
            if code(contents).contains(zeroDistanceDrag) {
                unexpectedFiles.append(fileURL.path)
            }
        }
        XCTAssertTrue(
            unexpectedFiles.isEmpty,
            "zero-distance structural drag leaked into: \(unexpectedFiles)"
        )
    }

    func testProductionButtonUsesNativeActionPressAndTriggersOnce() {
        let structural = code(source("Sources/App/StructuralHaptics.swift"))
        let press = exactBlock(
            structural,
            startingWith: "private struct ScrollSafeStructuralButton: View"
        )

        XCTAssertTrue(press.contains("Button(role: configuration.role)"))
        XCTAssertTrue(press.contains("Haptics.shared.beginTap"))
        XCTAssertTrue(press.contains("Haptics.shared.completeTap()"))
        XCTAssertTrue(press.contains("configuration.trigger()"))
        XCTAssertTrue(press.contains(".buttonStyle(DefaultButtonStyle())"))
    }

    func testDiagnosticLabelCannotCaptureTouchesAndOverlaysHaveBoundedShapes() {
        let app = code(source("Sources/App/SendmeterNativeApp.swift"))
        XCTAssertTrue(app.contains("StructuralHapticDiagnosticBanner(label: label)"))
        XCTAssertTrue(app.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(app.contains(".overlay(alignment: .top)"))

        guard let errorIndex = app.range(of: "ErrorBanner(message:"),
              let diagnosticIndex = app.range(of: "StructuralHapticDiagnosticBanner(label: label)")
        else {
            XCTFail("Missing diagnostic overlay ordering")
            return
        }
        XCTAssertLessThan(
            errorIndex.lowerBound,
            diagnosticIndex.lowerBound,
            "the diagnostic label must be laid out after the error banner"
        )

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


    func testMenuWiringKeepsTriggerStyleAndRowTick() {
        let source = code(source("Sources/Features/Phases/PhasesView.swift"))
        XCTAssertTrue(source.contains("Menu {"))
        XCTAssertFalse(source.contains(".onTapGesture {\n                                Haptics.shared.playGesture(.light)"))
        XCTAssertTrue(source.contains("Button(candidate.name) {\n                                Haptics.shared.playGesture(.light)\n                                onPropose(candidate.id)\n                            }"))
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
