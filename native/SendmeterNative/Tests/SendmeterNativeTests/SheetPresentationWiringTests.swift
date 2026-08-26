import Foundation
import XCTest
@testable import Sendmeter

/// Source-level coverage for the presentation seam. SwiftUI's `.sheet`
/// modifier is compiled into the application target, while the Core package
/// tests the lifecycle policy; this invariant keeps a future sheet from
/// silently bypassing the shared chrome and haptic lifecycle.
final class SheetPresentationWiringTests: XCTestCase {
    func testEveryNativeSheetUsesTheSharedTreatment() {
        let featureSources = swiftSources(in: "Sources/Features")
        let combined = featureSources.values.joined(separator: "\n")
        let sheetCount = count(#"\.sheet\s*\("#, in: combined)
        let treatmentCount = count(#"\.sendmeterSheetPresentation\s*\("#, in: combined)

        XCTAssertEqual(
            sheetCount,
            treatmentCount,
            "every native .sheet must apply exactly one shared presentation treatment"
        )
        XCTAssertFalse(
            combined.contains(".presentationDragIndicator"),
            "sheet chrome must not be reimplemented beside an individual sheet"
        )
        XCTAssertFalse(
            combined.contains(".presentationCornerRadius"),
            "sheet radius must come from the shared presentation treatment"
        )
        XCTAssertFalse(
            containsSheetDismissalHaptic(in: combined),
            "sheet dismissal haptics must be centralized in the treatment"
        )
    }

    func testSharedTreatmentOwnsChromeAndLifecycleCallbacks() {
        let treatment = source("Sources/App/SheetPresentation.swift")

        XCTAssertTrue(treatment.contains(".presentationDragIndicator(.visible)"))
        XCTAssertTrue(treatment.contains(".presentationCornerRadius(CGFloat(SheetPresentationPolicy.cornerRadius))"))
        XCTAssertTrue(treatment.contains("lifecycle.appeared(id: presentationID)"))
        XCTAssertTrue(treatment.contains("lifecycle.disappeared(id: presentationID)"))
        XCTAssertTrue(treatment.contains("Haptics.shared.sheetPresented()"))
        XCTAssertTrue(treatment.contains("Haptics.shared.sheetDismissed()"))
        XCTAssertFalse(
            treatment.contains("interactiveDismissDisabled"),
            "the shared treatment must preserve each sheet's existing dismiss policy"
        )
    }

    func testExecutionFullScreensDoNotUseSheetTreatment() {
        let workout = source("Sources/Features/Workout/WorkoutView.swift")
        let force = source("Sources/Features/Force/ForceView.swift")

        XCTAssertFalse(fullScreenClosureContainsTreatment(in: workout))
        XCTAssertFalse(fullScreenClosureContainsTreatment(in: force))
    }

    private func fullScreenClosureContainsTreatment(in source: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\.fullScreenCover\s*\("#) else {
            return true
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: range)
        for match in matches {
            let start = match.range.location
            let suffix = String(source.dropFirst(start))
            if suffix.contains(".sendmeterSheetPresentation(") {
                return true
            }
        }
        return false
    }

    private func containsSheetDismissalHaptic(in source: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"\.sheet\s*\([^\n]*onDismiss\s*:[^\n]*Haptics\.shared\.sheetDismissed"#
        ) else {
            return true
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.firstMatch(in: source, range: range) != nil
    }

    private func swiftSources(in relativeDirectory: String) -> [String: String] {
        let root = packageRoot.appendingPathComponent(relativeDirectory)
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        var sources: [String: String] = [:]
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift",
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            else { continue }
            sources[fileURL.path] = contents
        }
        return sources
    }

    private func source(_ relativePath: String) -> String {
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func count(_ pattern: String, in source: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.numberOfMatches(in: source, range: range)
    }
}
