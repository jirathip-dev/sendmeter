import Foundation
import XCTest
@testable import Sendmeter

/// Source-level coverage for the presentation seam. SwiftUI's `.sheet`
/// modifier is compiled into the application target, while the Core package
/// tests the lifecycle policy; these invariants keep a future presentation
/// from silently bypassing the shared chrome or haptic lifecycle.
final class SheetPresentationWiringTests: XCTestCase {
    func testEveryNativeSheetUsesTheSharedTreatmentPerPresentation() {
        let sources = swiftSources(in: "Sources")
        let sheets = presentations(named: "sheet", in: sources)
        let combined = sources.values.joined(separator: "\n")

        XCTAssertEqual(
            sheets.count,
            count(#"\.sheet\s*\("#, in: combined),
            "the source parser must account for every native .sheet invocation"
        )
        XCTAssertFalse(sheets.isEmpty, "the native app should have an inventory of sheets")

        for sheet in sheets {
            let label = sheet.label
            XCTAssertEqual(
                count(#"\.sendmeterSheetPresentation\s*\("#, in: sheet.closureBody),
                1,
                "\(label) must apply exactly one shared presentation treatment in its own closure"
            )
            XCTAssertFalse(
                sheet.closureBody.contains(".presentationDragIndicator"),
                "\(label) must not reimplement sheet chrome"
            )
            XCTAssertFalse(
                sheet.closureBody.contains(".presentationCornerRadius"),
                "\(label) must not reimplement sheet radius"
            )
            for cue in ["Haptics.shared.sheetPresented()", "Haptics.shared.sheetDismissed()"] {
                XCTAssertFalse(
                    sheet.invocation.contains(cue) || sheet.closureBody.contains(cue),
                    "\(label) must centralize \(cue) in the shared treatment"
                )
            }
        }
    }

    func testSharedTreatmentOwnsChromeAndLifecycleCallbacks() {
        let treatment = source("Sources/App/SheetPresentation.swift")
        let designSystem = source("Sources/App/DesignSystem.swift")

        XCTAssertTrue(treatment.contains(".presentationDragIndicator(dragToDismiss ? .visible : .hidden)"))
        XCTAssertTrue(treatment.contains(".presentationCornerRadius(CGFloat(SheetPresentationPolicy.cornerRadius))"))
        XCTAssertTrue(treatment.contains("lifecycle.appeared(id: presentationID)"))
        XCTAssertTrue(treatment.contains("lifecycle.disappeared(id: presentationID)"))
        XCTAssertTrue(treatment.contains("Haptics.shared.sheetPresented()"))
        XCTAssertTrue(treatment.contains("Haptics.shared.sheetDismissed()"))
        XCTAssertTrue(treatment.contains("dragToDismiss: Bool = true"))
        XCTAssertFalse(
            treatment.contains(".interactiveDismissDisabled()"),
            "the shared treatment must preserve each sheet's existing dismiss policy"
        )
        XCTAssertTrue(
            designSystem.contains("public static let radius: CGFloat = CGFloat(SheetPresentationPolicy.cornerRadius)"),
            "the app radius token must reuse the shared sheet radius"
        )
    }

    func testRoutineRunnerFullscreenPreservesTheClassifiedClosePath() {
        let workoutPath = "Sources/Features/Workout/WorkoutView.swift"
        let workout = source(workoutPath)
        let fullScreens = presentations(named: "fullScreenCover", in: [workoutPath: workout])
        let routineSheet = fullScreens.first { $0.closureBody.contains("RoutineRunnerSheet(") }

        XCTAssertNotNil(routineSheet, "the routine runner must remain an execution full screen")
        XCTAssertTrue(
            routineSheet?.invocation.contains(".fullScreenCover(item:") == true,
            "the routine runner must use the execution full-screen presentation"
        )
        XCTAssertTrue(
            workout.contains(".interactiveDismissDisabled()"),
            "the routine runner must keep its classified Close safety gate"
        )
        XCTAssertTrue(
            workout.contains("classified Close path"),
            "the routine runner's non-dismissible behavior must stay documented"
        )
    }

    func testExecutionFullScreensDoNotUseSheetTreatment() {
        let sources = swiftSources(in: "Sources")
        let fullScreens = presentations(named: "fullScreenCover", in: sources)

        XCTAssertFalse(fullScreens.isEmpty, "the native app should have an execution full-screen inventory")
        for fullScreen in fullScreens {
            XCTAssertFalse(
                fullScreen.closureBody.contains(".sendmeterSheetPresentation("),
                "\(fullScreen.label) must not use regular-sheet treatment"
            )
        }
    }

    func testFullScreenScanIsBoundedToTheActualClosure() {
        let emojiBeforePresentation = """
        let title = "🧗‍♀️"
        .fullScreenCover(isPresented: $show) {
            Text(title)
        }
        .sendmeterSheetPresentation()
        """
        XCTAssertFalse(fullScreenClosureContainsTreatment(in: emojiBeforePresentation))

        let treatmentInsidePresentation = """
        .fullScreenCover(isPresented: $show) {
            Text("execution").sendmeterSheetPresentation()
        }
        """
        XCTAssertTrue(fullScreenClosureContainsTreatment(in: treatmentInsidePresentation))
    }

    private struct PresentationRegion {
        let file: String
        let invocation: String
        let closureBody: String

        var label: String { file }
    }

    private func fullScreenClosureContainsTreatment(in source: String) -> Bool {
        let regions = presentations(named: "fullScreenCover", in: ["fixture.swift": source])
        guard !regions.isEmpty else { return true }
        return regions.contains { $0.closureBody.contains(".sendmeterSheetPresentation(") }
    }

    private func presentations(
        named name: String,
        in sources: [String: String]
    ) -> [PresentationRegion] {
        guard let regex = try? NSRegularExpression(
            pattern: "\\." + NSRegularExpression.escapedPattern(for: name) + "\\s*\\("
        ) else { return [] }

        var regions: [PresentationRegion] = []
        for (file, source) in sources.sorted(by: { $0.key < $1.key }) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard let matchRange = Range(match.range, in: source),
                      let opening = source[matchRange.lowerBound...].firstIndex(of: "("),
                      let closing = matchingDelimiter(
                          in: source,
                          from: opening,
                          openingCharacter: "(",
                          closingCharacter: ")"
                      ),
                      let closureOpening = nextCodeIndex(in: source, after: closing),
                      source[closureOpening] == "{",
                      let closureClosing = matchingDelimiter(
                          in: source,
                          from: closureOpening,
                          openingCharacter: "{",
                          closingCharacter: "}"
                      )
                else { continue }

                let bodyStart = source.index(after: closureOpening)
                regions.append(
                    PresentationRegion(
                        file: file,
                        invocation: String(source[matchRange.lowerBound...closing]),
                        closureBody: String(source[bodyStart..<closureClosing])
                    )
                )
            }
        }
        return regions
    }

    private enum LexicalMode {
        case code
        case lineComment
        case blockComment
        case string
        case multilineString
    }

    private func matchingDelimiter(
        in source: String,
        from opening: String.Index,
        openingCharacter: Character,
        closingCharacter: Character
    ) -> String.Index? {
        var cursor = opening
        var depth = 0
        var mode = LexicalMode.code

        while cursor < source.endIndex {
            switch mode {
            case .code:
                if source[cursor...].hasPrefix("//") {
                    mode = .lineComment
                    cursor = advance(cursor, by: 2, in: source)
                    continue
                }
                if source[cursor...].hasPrefix("/*") {
                    mode = .blockComment
                    cursor = advance(cursor, by: 2, in: source)
                    continue
                }
                if source[cursor...].hasPrefix("\"\"\"") {
                    mode = .multilineString
                    cursor = advance(cursor, by: 3, in: source)
                    continue
                }
                if source[cursor] == "\"" {
                    mode = .string
                    cursor = source.index(after: cursor)
                    continue
                }
                if source[cursor] == openingCharacter {
                    depth += 1
                } else if source[cursor] == closingCharacter {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
                cursor = source.index(after: cursor)

            case .lineComment:
                if source[cursor] == "\n" { mode = .code }
                cursor = source.index(after: cursor)

            case .blockComment:
                if source[cursor...].hasPrefix("*/") {
                    mode = .code
                    cursor = advance(cursor, by: 2, in: source)
                } else {
                    cursor = source.index(after: cursor)
                }

            case .string:
                if source[cursor] == "\\" {
                    cursor = advance(cursor, by: 2, in: source)
                } else if source[cursor] == "\"" {
                    mode = .code
                    cursor = source.index(after: cursor)
                } else {
                    cursor = source.index(after: cursor)
                }

            case .multilineString:
                if source[cursor...].hasPrefix("\"\"\"") {
                    mode = .code
                    cursor = advance(cursor, by: 3, in: source)
                } else {
                    cursor = source.index(after: cursor)
                }
            }
        }
        return nil
    }

    private func nextCodeIndex(in source: String, after index: String.Index) -> String.Index? {
        var cursor = source.index(after: index)
        while cursor < source.endIndex {
            if source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
                continue
            }
            if source[cursor...].hasPrefix("//") {
                while cursor < source.endIndex, source[cursor] != "\n" {
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if source[cursor...].hasPrefix("/*") {
                cursor = advance(cursor, by: 2, in: source)
                while cursor < source.endIndex, !source[cursor...].hasPrefix("*/") {
                    cursor = source.index(after: cursor)
                }
                if cursor < source.endIndex { cursor = advance(cursor, by: 2, in: source) }
                continue
            }
            return cursor
        }
        return nil
    }

    private func advance(
        _ index: String.Index,
        by offset: Int,
        in source: String
    ) -> String.Index {
        var cursor = index
        for _ in 0..<offset {
            guard cursor < source.endIndex else { return source.endIndex }
            cursor = source.index(after: cursor)
        }
        return cursor
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
