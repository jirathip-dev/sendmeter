@testable import SendmeterCore
import XCTest

/// #1038 G4 / G5 / Safety: source-level witnesses for the Force view wiring
/// that a SwiftUI View with @Environment/@AppStorage cannot be constructed
/// for in a unit test. Each assertion pins the exact call site and an
/// XCTAssertFalse on the shape it replaced.
final class Force1038WiringTests: XCTestCase {

    /// G5: the picker is a regular bottom sheet (grabber = swipe-to-cancel),
    /// never the old full-screen modal with its own Close.
    func testThePickerIsASheetThatCommitsAndCloses() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let normalized = normalizeWhitespace(force)

        XCTAssertTrue(normalized.contains(".sheet(isPresented: $movementPickerPresented"))
        XCTAssertFalse(normalized.contains(".fullScreenCover(isPresented: $movementPickerPresented"))
        // The only write path is the commit, and it closes the sheet.
        XCTAssertTrue(normalized.contains("onCommit: { pair in tag = pair.movement side = pair.side movementPickerPresented = false }"))
        XCTAssertFalse(normalized.contains("tag: $tag, side: Binding("), "the picker must not edit the live context directly")
        XCTAssertTrue(normalized.contains("lastSideProvider: { lastSides[$0] }"))
        XCTAssertTrue(normalized.contains("MovementSidePickerPolicy.lastSides(from: model.recordings)"))
    }

    /// G5 + H: no X, no "Updates instantly", no numbered rows, no column
    /// headers, no checkbox squares; one Policy-driven commit path.
    func testThePickerHasNoCloseButtonAndNoSpreadsheetChrome() {
        let card = code(source("Sources/Features/Force/ForceRecordingContextCard.swift"))
        let picker = exactBlock(card, startingWith: "struct ForceMovementSidePicker: View")

        XCTAssertFalse(picker.contains("\"xmark\""))
        XCTAssertFalse(picker.contains("\"Updates instantly\""))
        XCTAssertFalse(picker.contains("\"SIDE POLICY\""))
        XCTAssertFalse(picker.contains("String(format: \"%02d\""))
        XCTAssertFalse(picker.contains("onClose"))
        XCTAssertFalse(card.contains("enum SidePolicyBadge"), "the all-rows 'Either' column is gone (H2)")
        XCTAssertTrue(picker.contains("MovementSideBadge.badge(for: mode)"))
        XCTAssertTrue(picker.contains("MovementAreaHint.hint(for: name)"))
        XCTAssertTrue(picker.contains("MovementSidePickerPolicy.tapMovement("))
        XCTAssertTrue(picker.contains("MovementSidePickerPolicy.tapSide("))
        XCTAssertTrue(picker.contains("swipe down to keep"))
        // The side control renders BEFORE the movement list.
        let body = exactBlock(picker, startingWith: "var body: some View")
        guard let side = body.range(of: "sideControl"),
              let list = body.range(of: "movementGroup(")
        else { return XCTFail("picker body lost its side control or list") }
        XCTAssertLessThan(side.lowerBound, list.lowerBound)
    }

    /// G4: picking a protocol from the card selects Guided — the bar's
    /// switch follows — even from Free hold, except mid-pull.
    func testPickingAProtocolSwitchesTheBarToGuided() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let handler = normalizeWhitespace(
            exactBlock(force, startingWith: "private func handleSelectTarget(_ tapped: ForceProtocolSelection)")
        )
        XCTAssertTrue(handler.contains("ForceProtocolSelectionRouting.mode(afterSelecting: next) == .guided"))
        XCTAssertTrue(handler.contains("handsFreeEnabled = false"))
        XCTAssertTrue(handler.contains("!model.handsFree.isMeasuring"))
    }

    /// Safety (#678 salvage): armed-idle no longer locks the card, so the
    /// recording context is frozen at the TRUE recording start.
    func testTheSalvageLockIsTakenWhenAPullStartsRecording() {
        let force = normalizeWhitespace(code(source("Sources/Features/Force/ForceView.swift")))
        XCTAssertTrue(
            force.contains(".onChange(of: model.handsFree.isMeasuring) { measuring in if measuring { model.lockForceRecordingContext(model.freePullContext) }")
        )
    }

    // MARK: Helpers

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

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The brace-balanced block that opens at `marker`.
    private func exactBlock(_ source: String, startingWith marker: String) -> String {
        guard let start = source.range(of: marker),
              let open = source.range(of: "{", range: start.upperBound..<source.endIndex)
        else {
            XCTFail("Missing block: \(marker)")
            return ""
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        XCTFail("Unbalanced block: \(marker)")
        return ""
    }
}
