import Foundation
import XCTest
@testable import Sendmeter

/// #942: the source invariants of the History merge entry point. The SwiftUI
/// views live outside SwiftPM, so these pins plus the hosted Xcode compile gate
/// are what make the UI half of AC3 ("rejected in UI") checkable: the action is
/// offered only for a session the RPC could accept, and the sheet previews with
/// the same planner the merge itself uses — so the UI cannot offer a merge the
/// API would refuse.
final class MergeSessionsWiringTests: XCTestCase {
    func testHistoryOffersMergeOnlyForEligibleTindeqRows() throws {
        let history = code(source("Sources/Features/History/HistoryView.swift"))
        let row = exactBlock(history, startingWith: "private func sessionRow(")
        let offers = exactBlock(history, startingWith: "private func offersMerge(")

        XCTAssertTrue(row.contains(".contextMenu {"), "the merge action lives on the session row")
        XCTAssertTrue(row.contains("if offersMerge(session)"))
        XCTAssertTrue(row.contains("mergeAnchor = session"))
        XCTAssertTrue(row.contains("Label(\"Merge with…\""))
        // The gate mirrors the RPC's own guardrails.
        XCTAssertTrue(offers.contains("session.type == \"tindeq\""))
        XCTAssertTrue(offers.contains("session.groupID != nil"))
        XCTAssertTrue(offers.contains("!session.pending"))
        XCTAssertTrue(offers.contains("!session.rejected"))

        // Same-day siblings come from the pure planner, never a local filter.
        let candidates = exactBlock(history, startingWith: "private func mergeCandidates(")
        XCTAssertTrue(candidates.contains("TindeqSessionMergePlanner.candidates(for: session, in: model.sessions)"))
    }

    func testMergeSheetPreviewsWithTheSharedPlannerAndConfirmsThroughAppModel() throws {
        let history = code(source("Sources/Features/History/HistoryView.swift"))
        let sheet = exactBlock(history, startingWith: "private struct MergeSessionsSheet: View")

        XCTAssertTrue(
            history.contains(".sheet(item: $mergeAnchor)"),
            "the merge sheet is presented from the tapped session"
        )
        XCTAssertTrue(
            sheet.contains("model.mergePreview(chosen)"),
            "the preview must be the plan the merge will apply"
        )
        XCTAssertTrue(
            sheet.contains("TindeqSessionMergePlanner.eligibility(chosen).refusalMessage"),
            "a refused selection must say why"
        )
        XCTAssertTrue(sheet.contains(".disabled(merging || plan == nil)"))
        XCTAssertTrue(sheet.contains("await model.mergeTindeqSessions(chosen)"))
        XCTAssertTrue(sheet.contains("if merged {"))
        XCTAssertTrue(
            sheet.contains("mergeError = \"Couldn't merge these sessions — try again.\""),
            "a failed merge must be reported, not silently swallowed"
        )
    }

    /// AC2: the merged recordings stay visible because the detail surface
    /// groups them by the surviving session's group id.
    func testSessionDetailStillGroupsRecordingsByTheSurvivingGroup() throws {
        let detail = code(source("Sources/Features/History/SessionDetailView.swift"))
        XCTAssertTrue(
            detail.contains("return model.recordings.filter { $0.groupID == groupID }"),
            "the merged session's detail must list every recording under its group"
        )
    }

    func testAppModelQueuesTheMergeAsADurableWrite() throws {
        let model = code(source("Sources/App/AppModel.swift"))
        let repository = code(source("Sources/Data/Repositories.swift"))

        XCTAssertTrue(model.contains("case sessionMerge(SessionMergeQueuePayload)"))
        XCTAssertTrue(model.contains("sessionIDs: payload.mergedSessionIDs"))
        XCTAssertTrue(model.contains("survivorID: payload.survivorID"))
        XCTAssertTrue(
            model.contains("repository.mergeTindeqSessions("),
            "the upload path must go through the RPC"
        )
        XCTAssertTrue(
            model.contains("pendingMergedAwaySessionIDs[session.id] != currentUserID"),
            "a queued merge must keep its merged-away rows out of the published list"
        )
        XCTAssertTrue(repository.contains("\"rest/v1/rpc/merge_tindeq_sessions\""))
        XCTAssertTrue(repository.contains("case sessionIDs = \"p_session_ids\""))
    }

    // MARK: source helpers (duplicated from HistoryTapDetailWiringTests; the
    // private helpers there are not reusable across classes / targets).

    private func source(_ relativePath: String) -> String {
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

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
