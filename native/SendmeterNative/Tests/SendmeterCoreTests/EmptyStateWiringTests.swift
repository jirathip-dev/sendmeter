import Foundation
import XCTest

/// #787: the SwiftUI application target is outside SwiftPM, so these source
/// invariants pin the product empty-state seam and every owning action until
/// the hosted Xcode compile gate runs.
final class EmptyStateWiringTests: XCTestCase {
    func testSharedEmptyStateUsesSendmeterArtAndOneActionControl() {
        let design = code(source("Sources/App/DesignSystem.swift"))
        let emptyState = exactBlock(
            design,
            startingWith: "public struct ProductEmptyState: View"
        )

        XCTAssertTrue(emptyState.contains("Image(\"SplashCaveBackground\")"))
        XCTAssertTrue(emptyState.contains("Image(\"SplashKangaroo\")"))
        XCTAssertTrue(emptyState.contains("Button(actionTitle, action: action)"))
        XCTAssertEqual(
            countOccurrences("Button(actionTitle, action: action)", in: emptyState),
            1,
            "an empty state must expose exactly one primary next action"
        )
        XCTAssertTrue(emptyState.contains(".hapticButtonStyle(PrimaryActionButtonStyle())"))
        XCTAssertTrue(emptyState.contains(".accessibilityHidden(true)"))
    }

    func testDashboardRecentSessionsHasHonestLoadStateAndWorkoutAction() {
        let dashboard = code(source("Sources/Features/Dashboard/DashboardView.swift"))
        let recent = exactBlock(
            dashboard,
            startingWith: "private struct RecentSessionsCard: View"
        )

        XCTAssertTrue(recent.contains("if !model.hasLoadedSessions"))
        XCTAssertTrue(recent.contains("if model.isRefreshing"))
        XCTAssertTrue(recent.contains("ProductEmptyState("))
        XCTAssertTrue(recent.contains("actionTitle: \"Start a workout\""))
        XCTAssertTrue(recent.contains("model.selectedTab = .workout"))
        XCTAssertTrue(recent.contains("if !model.recentSessions.isEmpty"))
        XCTAssertFalse(recent.contains("ContentUnavailableView"))
        XCTAssertFalse(recent.contains("No sessions yet"))
    }

    func testHistoryPinsLoadedBranchesAndContextActions() {
        let history = code(source("Sources/Features/History/HistoryView.swift"))

        XCTAssertFalse(history.contains("ForceModel"))
        XCTAssertTrue(history.contains("if !model.hasLoadedSessions"))
        XCTAssertTrue(history.contains("historyLoadState(progressLabel: \"Loading history…\")"))
        XCTAssertTrue(history.contains("historyLoadState(progressLabel: \"Loading sessions…\")"))
        XCTAssertTrue(history.contains("historyLoadState(progressLabel: \"Loading force history…\")"))
        XCTAssertTrue(history.contains("action: startWorkout"))
        XCTAssertTrue(history.contains("action: openForce"))
        XCTAssertTrue(history.contains("action: clearHistoryFilters"))
        XCTAssertTrue(history.contains("model.selectedTab = .workout"))
        XCTAssertTrue(history.contains("model.selectedTab = .force"))
        XCTAssertTrue(history.contains("ProductEmptyState("))
        XCTAssertFalse(history.contains("No history yet"))
        XCTAssertFalse(history.contains("No sessions yet"))
        XCTAssertFalse(history.contains("No force recordings yet"))
    }

    func testForceProgressPinsEmptyDataWithoutNestingActionsInTiles() {
        let card = code(source("Sources/Features/Force/ForceProgressCard.swift"))
        let boundary = exactBlock(
            card,
            startingWith: "struct ForceProgressCardBoundary: View, Equatable"
        )
        let tile = exactBlock(card, startingWith: "private func tile<Content: View>(")

        XCTAssertTrue(boundary.contains("let emptyActionTitle: String"))
        XCTAssertTrue(boundary.contains("let emptyAction: () -> Void"))
        XCTAssertTrue(boundary.contains("emptyActionTitle: emptyActionTitle"))
        XCTAssertTrue(card.contains("staticProgress.totalCount == 0"))
        XCTAssertTrue(card.contains("movementProgress.latestMetrics == nil"))
        XCTAssertTrue(card.contains("ProductEmptyState("))
        XCTAssertTrue(tile.contains("if isEmpty"))
        XCTAssertTrue(tile.contains("ProductEmptyState("))
        XCTAssertTrue(tile.contains("} else {"))
        XCTAssertTrue(tile.contains("Button(action:"))
        XCTAssertFalse(tile.contains("Button(action: emptyAction"))

        let core = code(source("Sources/Core/ForceProgress.swift"))
        let key = exactBlock(core, startingWith: "public struct ForceProgressCardKey: Hashable, Sendable")
        XCTAssertTrue(key.contains("public let emptyActionTitle: String"))
    }

    func testNativeCurvePinsEmptySamplesAndItsRecordAction() {
        let curve = code(source("Sources/Features/Force/NativeForceCurveCard.swift"))

        XCTAssertTrue(curve.contains("let emptyActionTitle: String"))
        XCTAssertTrue(curve.contains("let emptyAction: () -> Void"))
        XCTAssertTrue(curve.contains("if let model, !model.points.isEmpty"))
        XCTAssertTrue(curve.contains("} else if hasLoadedRecordings {"))
        XCTAssertTrue(curve.contains("ProductEmptyState("))
        XCTAssertTrue(curve.contains("actionTitle: emptyActionTitle"))
        XCTAssertTrue(curve.contains("action: emptyAction"))
        XCTAssertTrue(curve.contains("ProgressView(\"Loading force-duration curve…\")"))
    }

    func testDisconnectedProgressorUsesOneIllustratedConnectAction() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let device = exactBlock(force, startingWith: "private struct ForceDeviceCard: View")

        XCTAssertTrue(device.contains("private var showsDisconnectedEmptyState: Bool"))
        XCTAssertTrue(device.contains("ProductEmptyState("))
        XCTAssertTrue(device.contains("actionTitle: \"Connect Progressor\""))
        XCTAssertTrue(device.contains("action: connect"))
        XCTAssertTrue(device.contains("if showsDisconnectedEmptyState {\n                EmptyView()"))
        XCTAssertTrue(force.contains("private var forceEmptyActionTitle: String"))
        XCTAssertTrue(force.contains("private func performForceEmptyAction()"))
        XCTAssertTrue(force.contains("case .connected:\n            startMeasurement()"))
        XCTAssertTrue(force.contains("case .unavailable:\n            model.selectedTab = .settings"))
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
