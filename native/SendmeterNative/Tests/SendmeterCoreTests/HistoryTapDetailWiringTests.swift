import Foundation
import XCTest

/// #815/#843: every History row kind must tap through to the EXISTING
/// read-only detail surface (the one long-press already revealed) — never
/// straight into the editor — and the Send Conditions card must present its
/// detail sheet on tap. These are source invariants because the SwiftUI
/// views live in the Xcode app target, outside SwiftPM; the hosted
/// Xcode compile gate covers type checking.
final class HistoryTapDetailWiringTests: XCTestCase {
    func testSessionRowsTapToReadOnlyDetailForEveryKind() {
        let history = code(source("Sources/Features/History/HistoryView.swift"))
        let row = exactBlock(history, startingWith: "private func sessionRow(")

        // One single tap target for Tindeq grouped, workout, manual/plain,
        // pending and rejected rows alike: the read-only detail.
        XCTAssertEqual(
            countOccurrences("NavigationLink {", in: row),
            1,
            "the session row tap target must be exactly one NavigationLink"
        )
        XCTAssertEqual(
            countOccurrences("SessionDetailView(session: session)", in: row),
            1,
            "every session row kind must navigate to the existing read-only detail"
        )
        XCTAssertEqual(
            countOccurrences("SessionEditorSheet", in: row),
            0,
            "a session row tap must never open the editor directly"
        )
        XCTAssertEqual(
            countOccurrences("editingSession = session", in: row),
            1,
            "the editor must be armed only by the explicit Edit swipe action"
        )
        XCTAssertFalse(
            history.contains("isExpandable"),
            "#815 removed the expandable/non-expandable tap split: no one row kind gets a different tap target"
        )
        // The editor surface itself survives for the explicit swipe path.
        XCTAssertTrue(
            history.contains("SessionEditorSheet(session: session)"),
            "the explicit Edit path must still present the session editor"
        )
    }

    func testRecordingRowsTapToReadOnlyDetail() {
        let history = code(source("Sources/Features/History/HistoryView.swift"))
        let row = exactBlock(history, startingWith: "private func recordingRow(")

        XCTAssertEqual(
            countOccurrences("NavigationLink {", in: row),
            1,
            "the force-recording row tap target must be exactly one NavigationLink"
        )
        XCTAssertEqual(
            countOccurrences("ForceRecordingDetailView(recording: recording)", in: row),
            1,
            "the force-recording row must navigate to the existing read-only detail"
        )
    }

    func testSessionRowKeepsFullRowHitTargetAndAccessibility() {
        let history = code(source("Sources/Features/History/HistoryView.swift"))
        let row = exactBlock(history, startingWith: "private func sessionRow(")

        XCTAssertTrue(row.contains("HistorySessionRow("))
        XCTAssertTrue(row.contains(".hapticButtonStyle(.plain)"))
        XCTAssertTrue(row.contains(".swipeActions(edge: .trailing, allowsFullSwipe: false)"))
        XCTAssertTrue(
            history.contains(".contentShape(Rectangle())"),
            "the row label must keep a full-hit-shape content shape"
        )
        XCTAssertTrue(
            history.contains(".accessibilityElement(children: .combine)"),
            "the row label must stay a single combined accessibility element"
        )
    }

    func testSendConditionsCardTapPresentsDetailSheet() {
        let dashboard = code(source("Sources/Features/Dashboard/DashboardView.swift"))
        let card = exactBlock(dashboard, startingWith: "private struct SendConditionsCard: View")
        let content = exactBlock(dashboard, startingWith: "private struct SendConditionsCardContent: View")

        // Chevron/header AND the populated body both wire the same tap.
        XCTAssertEqual(
            countOccurrences(".onTapGesture(perform: open)", in: content),
            2,
            "the card header/chevron and the populated body must both present the detail"
        )
        XCTAssertTrue(card.contains(".sheet(isPresented: $showSendConditions)"))
        XCTAssertTrue(card.contains("SendConditionsDetailSheet()"))
        XCTAssertTrue(card.contains(".accessibilityAction { openSheet() }"))
        XCTAssertTrue(card.contains(".accessibilityAddTraits(.isButton)"))
    }

    // MARK: source helpers (duplicated from EmptyStateWiringTests; the
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
