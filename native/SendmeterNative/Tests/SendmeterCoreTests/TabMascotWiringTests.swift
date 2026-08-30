import Foundation
import XCTest

/// #875: the tab-bar reorder (Dashboard → Force → Workout → History →
/// Settings) and the approved mascot imagesets are presentation wiring in the
/// Xcode app target (outside SwiftPM), so these source invariants pin the real
/// call sites until the hosted Xcode compile gate runs. `AppTab`,
/// `SendmeterIconSymbol`, and the Live Activity widget call sites are
/// intentionally untouched (widgets keep SF Symbols); the assertions below
/// only read the call sites named in the acceptance criteria.
final class TabMascotWiringTests: XCTestCase {
    func testMainTabOrderAndTags() {
        let mainTab = exactBlock(
            code(source("Sources/App/SendmeterNativeApp.swift")),
            startingWith: "struct MainTabView: View"
        )

        let expected: [(destination: String, tag: String)] = [
            ("DashboardView()", ".tag(AppTab.dashboard)"),
            ("ForceView()", ".tag(AppTab.force)"),
            ("WorkoutView()", ".tag(AppTab.workout)"),
            ("HistoryView()", ".tag(AppTab.history)"),
            ("SettingsView()", ".tag(AppTab.settings)")
        ]

        var cursor = mainTab.startIndex
        for (index, item) in expected.enumerated() {
            guard let destinationRange = mainTab.range(
                of: item.destination,
                range: cursor..<mainTab.endIndex
            ) else {
                XCTFail("Missing or out-of-order destination \(item.destination) in MainTabView")
                return
            }
            guard let tagRange = mainTab.range(
                of: item.tag,
                range: destinationRange.upperBound..<mainTab.endIndex
            ) else {
                XCTFail("Missing tag \(item.tag) after \(item.destination)")
                return
            }
            // The tag must pair with ITS destination: it may not appear after
            // the next destination (a swapped tag would otherwise slip past
            // the sequential scan).
            if index + 1 < expected.count,
               let nextDestinationRange = mainTab.range(
                   of: expected[index + 1].destination,
                   range: destinationRange.upperBound..<mainTab.endIndex
               ),
               nextDestinationRange.lowerBound < tagRange.lowerBound {
                XCTFail(
                    "Tag \(item.tag) for \(item.destination) appears after the next destination \(expected[index + 1].destination)"
                )
                return
            }
            cursor = tagRange.upperBound
        }
    }

    func testMascotTabsUseApprovedImagesets() {
        let mainTab = exactBlock(
            code(source("Sources/App/SendmeterNativeApp.swift")),
            startingWith: "struct MainTabView: View"
        )
        let normalized = normalizeWhitespace(mainTab)

        XCTAssertTrue(mainTab.contains("Label(\"Dashboard\", systemImage: SendmeterIconSymbol.status.rawValue)"))
        XCTAssertTrue(mainTab.contains("Label(\"History\", systemImage: \"clock.arrow.circlepath\")"))
        XCTAssertTrue(mainTab.contains("Label(\"Settings\", systemImage: \"gearshape\")"))
        // The mascot tabs use the approved imagesets with explicit template
        // rendering so the tab bar tints them in selected/inactive states.
        XCTAssertTrue(
            normalized.contains(
                "Label { Text(\"Force\") } icon: { Image(\"ForceMascotTab\") .renderingMode(.template) }"
            )
        )
        XCTAssertTrue(
            normalized.contains(
                "Label { Text(\"Workout\") } icon: { Image(\"WorkoutMascotTab\") .renderingMode(.template) }"
            )
        )
        // Never cross-assigned.
        XCTAssertFalse(
            normalized.contains(
                "Label { Text(\"Force\") } icon: { Image(\"WorkoutMascotTab\")"
            )
        )
        XCTAssertFalse(
            normalized.contains(
                "Label { Text(\"Workout\") } icon: { Image(\"ForceMascotTab\")"
            )
        )
    }

    func testStartWorkoutCardUsesApprovedWorkoutMascot() {
        let workout = code(source("Sources/Features/Workout/WorkoutView.swift"))
        let card = exactBlock(
            workout,
            startingWith: "private struct StartWorkoutCard: View"
        )

        XCTAssertTrue(card.contains("Image(\"WorkoutMascotLarge\")"))
        XCTAssertTrue(card.contains("SendmeterStyle.primary"))
        XCTAssertTrue(card.contains(".accessibilityHidden(true)"))
        XCTAssertFalse(card.contains("figure.climbing"))
        XCTAssertTrue(card.contains("Text(\"Manual workout\")"))
        XCTAssertTrue(card.contains("Button(\"Start Manual workout\", action: start)"))
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

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
