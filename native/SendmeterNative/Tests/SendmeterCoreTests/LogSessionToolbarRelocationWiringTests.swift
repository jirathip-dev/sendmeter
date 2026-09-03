import Foundation
import XCTest

/// #834 (reopen, Build 50): the circular top-right "+ Log Session"
/// (plus.circle.fill) toolbar action was relocated from DashboardView to
/// WorkoutView — relocation, not redesign. These assertions pin the ACTUAL
/// toolbar blocks of both views: Workout's `.toolbar` (topBarTrailing) must
/// hold the action with its haptic tick and `showLog` arm, the sheet must
/// present LogSessionSheet with the same presentation treatment, and
/// Dashboard's body must no longer carry the action, its state, or the sheet
/// type. String-presence checks elsewhere in the file would not prove which
/// toolbar owns the action; these read the real modifier blocks.
final class LogSessionToolbarRelocationWiringTests: XCTestCase {
    func testWorkoutToolbarWiresLogSessionAction() {
        let workout = code(source("Sources/Features/Workout/WorkoutView.swift"))
        let body = exactBlock(workout, startingWith: "var body: some View")

        XCTAssertEqual(
            countOccurrences(".toolbar {", in: body),
            1,
            "the Workout tab root must own exactly one toolbar: the relocated Log Session action"
        )
        let toolbar = exactBlock(body, startingWith: ".toolbar {")
        XCTAssertEqual(
            countOccurrences("ToolbarItem(placement: .topBarTrailing)", in: toolbar),
            1,
            "the relocated action must sit in the top-right toolbar"
        )
        XCTAssertTrue(
            toolbar.contains("Label(\"Log Session\", systemImage: \"plus.circle.fill\")"),
            "the toolbar action must keep the Log Session plus-circle label"
        )
        XCTAssertTrue(
            toolbar.contains("Haptics.shared.tap()"),
            "the toolbar action must keep its structural haptic tick"
        )
        XCTAssertTrue(
            toolbar.contains("showLog = true"),
            "the toolbar action must arm the LogSessionSheet presentation state"
        )

        let sheet = exactBlock(body, startingWith: ".sheet(isPresented: $showLog)")
        XCTAssertTrue(
            sheet.contains("LogSessionSheet()"),
            "the relocated sheet must present LogSessionSheet"
        )
        XCTAssertTrue(
            sheet.contains(".sendmeterSheetPresentation()"),
            "the relocated sheet must keep the shared sheet presentation treatment"
        )
    }

    func testDashboardNoLongerExposesLogSessionAction() {
        let dashboard = code(source("Sources/Features/Dashboard/DashboardView.swift"))
        let body = exactBlock(dashboard, startingWith: "var body: some View")

        XCTAssertEqual(
            countOccurrences(".toolbar {", in: body),
            0,
            "the Log Session toolbar must be gone from Dashboard's body"
        )
        XCTAssertEqual(
            countOccurrences("plus.circle.fill", in: body),
            0,
            "no Log Session plus-circle action may remain in Dashboard's body"
        )
        XCTAssertEqual(
            countOccurrences("LogSessionSheet", in: dashboard),
            0,
            "the LogSessionSheet type must move out of DashboardView.swift with the action"
        )
        XCTAssertEqual(
            countOccurrences("showLog", in: dashboard),
            0,
            "Dashboard must not keep dead Log Session sheet state"
        )
        XCTAssertEqual(
            countOccurrences("Log Session", in: dashboard),
            0,
            "no Log Session label may remain anywhere in DashboardView.swift"
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
