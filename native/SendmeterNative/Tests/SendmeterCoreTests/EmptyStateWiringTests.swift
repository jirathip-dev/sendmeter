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

        let normalizedRecent = normalizeWhitespace(recent)
        XCTAssertTrue(normalizedRecent.contains("!model.hasLoadedSessions"))
        XCTAssertTrue(normalizedRecent.contains("model.isLoadingData || model.isRefreshing"))
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
        let normalizedHistory = normalizeWhitespace(history)
        XCTAssertTrue(normalizedHistory.contains("!model.hasLoadedSessions"))
        XCTAssertTrue(normalizedHistory.contains("!model.hasLoadedRecordings"))
        XCTAssertTrue(history.contains("model.isLoadingData || model.isRefreshing"))
        XCTAssertTrue(history.contains("historyLoadState(progressLabel: \"Loading history…\")"))
        XCTAssertTrue(history.contains("historyLoadState(progressLabel: \"Loading sessions…\")"))
        XCTAssertTrue(history.contains("historyLoadState(progressLabel: \"Loading force history…\")"))
        XCTAssertTrue(history.contains("action: startWorkout"))
        XCTAssertTrue(history.contains("action: openForce"))
        XCTAssertTrue(history.contains("action: clearHistoryFilters"))
        XCTAssertTrue(history.contains("model.selectedTab = .workout"))
        XCTAssertTrue(history.contains("model.selectedTab = .force"))
        XCTAssertTrue(history.contains("ProductEmptyState("))
        XCTAssertTrue(history.contains("ScrollView {"))
        XCTAssertFalse(history.contains("No history yet"))
        XCTAssertFalse(history.contains("No sessions yet"))
        XCTAssertFalse(history.contains("No force recordings yet"))

        let combined = exactBlock(history, startingWith: "private var combinedList: some View")
        XCTAssertTrue(
            normalizeWhitespace(combined).contains(
                "if timelineItems.isEmpty, !model.hasLoadedSessions || !model.hasLoadedRecordings"
            )
        )
        let forceList = exactBlock(history, startingWith: "private var forceList: some View")
        XCTAssertTrue(
            normalizeWhitespace(forceList).contains(
                "if model.recordings.isEmpty, !model.hasLoadedRecordings"
            )
        )
    }

    func testForceProgressPinsEmptyDataWithoutNestingActionsInTiles() {
        let card = code(source("Sources/Features/Force/ForceProgressCard.swift"))
        let boundary = exactBlock(
            card,
            startingWith: "struct ForceProgressCardBoundary: View, Equatable"
        )
        let tile = exactBlock(card, startingWith: "private func tile<Content: View>(")
        let staticTile = exactBlock(card, startingWith: "private func staticTile(")
        let movementTile = exactBlock(card, startingWith: "private func movementTile(")

        XCTAssertTrue(boundary.contains("let emptyActionTitle: String"))
        XCTAssertTrue(boundary.contains("let emptyActionKey: String"))
        XCTAssertTrue(boundary.contains("let showsPrimaryEmptyState: Bool"))
        XCTAssertTrue(boundary.contains("let emptyAction: () -> Void"))
        XCTAssertTrue(boundary.contains("emptyActionKey: emptyActionKey"))
        XCTAssertTrue(boundary.contains("showsPrimaryEmptyState: showsPrimaryEmptyState"))
        XCTAssertTrue(boundary.contains("connectionPending: connectionPending"))
        XCTAssertTrue(card.contains("staticProgress.totalCount == 0"))
        XCTAssertTrue(card.contains("movementProgress.latestMetrics == nil"))
        XCTAssertTrue(card.contains("ProductEmptyState("))
        XCTAssertTrue(card.contains("No saved pulls match this exercise and side."))
        XCTAssertTrue(tile.contains("tileSurface("))
        XCTAssertEqual(
            countButtonInvocations(in: tile),
            1,
            "a progress tile must have one sheet-opening button, including its empty content"
        )
        XCTAssertFalse(tile.contains("ProductEmptyState("))
        XCTAssertEqual(countButtonInvocations(in: staticTile), 0)
        XCTAssertEqual(countButtonInvocations(in: movementTile), 0)

        let core = code(source("Sources/Core/ForceProgress.swift"))
        let key = exactBlock(core, startingWith: "public struct ForceProgressCardKey: Hashable, Sendable")
        XCTAssertTrue(key.contains("public let emptyActionKey: String"))
        XCTAssertTrue(key.contains("public let connectionPending: Bool"))
    }

    func testNativeCurvePinsEmptySamplesAndItsRecordAction() {
        let curve = code(source("Sources/Features/Force/NativeForceCurveCard.swift"))

        XCTAssertTrue(curve.contains("let emptyActionTitle: String"))
        XCTAssertTrue(curve.contains("let emptyAction: () -> Void"))
        XCTAssertTrue(curve.contains("let connectionPending: Bool"))
        XCTAssertTrue(curve.contains("let showsPrimaryEmptyState: Bool"))
        XCTAssertTrue(curve.contains("if let model, !model.points.isEmpty"))
        XCTAssertTrue(curve.contains("} else if hasLoadedRecordings {"))
        XCTAssertTrue(curve.contains("if connectionPending"))
        XCTAssertTrue(curve.contains("ProductEmptyState("))
        XCTAssertTrue(curve.contains("actionTitle: emptyActionTitle"))
        XCTAssertTrue(curve.contains("action: emptyAction"))
        XCTAssertTrue(curve.contains("Keep recording long pulls"))
        XCTAssertTrue(curve.contains("ProgressView(\"Loading force-duration curve…\")"))
    }

    func testDisconnectedProgressorUsesOneIllustratedConnectAction() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let device = exactBlock(force, startingWith: "private struct ForceDeviceCard: View")

        XCTAssertTrue(device.contains("private var showsDisconnectedEmptyState: Bool"))
        XCTAssertTrue(device.contains("ProductEmptyState("))
        XCTAssertEqual(
            countOccurrences("ProductEmptyState(", in: device),
            1,
            "the Progressor card must own the single global Force empty state"
        )
        XCTAssertTrue(device.contains("private var showsPrimaryEmptyState: Bool"))
        XCTAssertTrue(device.contains("actionTitle: emptyActionTitle"))
        XCTAssertTrue(device.contains("action: emptyAction"))
        XCTAssertTrue(device.contains("Reconnect to your force progress"))
        let forceDataEmpty = exactBlock(
            device,
            startingWith: "private var showsForceDataEmptyState: Bool"
        )
        XCTAssertTrue(forceDataEmpty.contains("hasLoadedRecordings"))
        XCTAssertTrue(forceDataEmpty.contains("!hasForceRecordings"))
        XCTAssertTrue(forceDataEmpty.contains("case .connected:"))
        XCTAssertTrue(forceDataEmpty.contains("return true"))
        let normalizedDevice = normalizeWhitespace(device)
        XCTAssertTrue(
            normalizedDevice.contains(
                "if showsPrimaryEmptyState, device.status != .connected { EmptyView()"
            )
        )
        XCTAssertTrue(force.contains("private var forceEmptyActionTitle: String"))
        XCTAssertTrue(force.contains("private func performForceEmptyAction()"))
        let normalizedForce = normalizeWhitespace(force)
        XCTAssertTrue(normalizedForce.contains("case .connected: startPrimaryForceAction()"))
        XCTAssertTrue(normalizedForce.contains("case .measuring: stopAndSave()"))
        XCTAssertTrue(normalizedForce.contains("case .unavailable: openBluetoothSettings()"))
        XCTAssertTrue(normalizedForce.contains("UIApplication.openSettingsURLString"))
        XCTAssertTrue(normalizedForce.contains("case .scanning, .connecting: model.tindeq.disconnect()"))
        XCTAssertFalse(force.contains("model.selectedTab = .settings"))

        let controls = exactBlock(force, startingWith: "private var controls: some View")
        let normalizedControls = normalizeWhitespace(controls)
        XCTAssertTrue(
            normalizedControls.contains(
                "if showsPrimaryEmptyState, device.status != .connected { EmptyView()"
            )
        )
        XCTAssertTrue(controls.contains("case .connected:"))
        XCTAssertTrue(controls.contains("try device.tare()"))
        XCTAssertTrue(controls.contains("Label(\"Battery\""))
        XCTAssertTrue(controls.contains("device.disconnect()"))
        XCTAssertTrue(controls.contains("$handsFreeEnabled"))
    }

    func testForceDetailSheetsOwnTheirEmptyStateAction() {
        let detail = code(source("Sources/Features/Force/StaticCapacityDetailView.swift"))
        XCTAssertTrue(detail.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertTrue(detail.contains("actionTitle: \"Back to Force\""))
        XCTAssertTrue(normalizeWhitespace(detail).contains("action: { dismiss() }"))
        XCTAssertTrue(normalizeWhitespace(detail).contains("emptyAction: { dismiss() }"))
        XCTAssertFalse(detail.contains("let emptyActionTitle: String"))
        XCTAssertFalse(detail.contains("let emptyAction: () -> Void"))

        let progress = code(source("Sources/Features/Force/ForceProgressCard.swift"))
        let sheetCall = exactBlock(progress, startingWith: "StaticCapacityDetailView(")
        XCTAssertTrue(sheetCall.contains("connectionPending: connectionPending"))
        XCTAssertFalse(sheetCall.contains("emptyAction:"))
    }

    func testAppModelOwnsIndependentRecordingBoundaryAndRefreshLoadingState() {
        let appModel = code(source("Sources/App/AppModel.swift"))

        XCTAssertTrue(appModel.contains("public private(set) var hasLoadedRecordings = false"))
        XCTAssertTrue(appModel.contains("public private(set) var isLoadingData = false"))
        XCTAssertTrue(appModel.contains("private func markRecordingsLoaded()"))
        XCTAssertTrue(appModel.contains("hasLoadedSessions = true"))
        XCTAssertTrue(appModel.contains("private func cacheHasCompletedSync("))
        XCTAssertTrue(appModel.contains("markRecordingsLoaded()"))
        XCTAssertTrue(appModel.contains("dataRefreshOwners.removeAll()"))
        XCTAssertTrue(appModel.contains("hasLoadedRecordings = false"))
        XCTAssertTrue(appModel.contains("forceModel.hasLoadedRecordings = false"))
        let cacheHydration = exactBlock(
            appModel,
            startingWith: "private func hydrateCachedWorkspace(accountUserID: UUID)"
        )
        XCTAssertTrue(cacheHydration.contains("sessionsWereSynced"))
        XCTAssertTrue(cacheHydration.contains("recordingsWereSynced"))
        XCTAssertTrue(cacheHydration.contains("hasLoadedSessions = sessionsWereSynced"))
        XCTAssertTrue(cacheHydration.contains("hasLoadedRecordings = recordingsWereSynced"))
        XCTAssertFalse(cacheHydration.contains("markRecordingsLoaded()"))
        let refresh = exactBlock(
            appModel,
            startingWith: "private func refreshAll(\n"
        )
        XCTAssertTrue(refresh.contains("fetchedRecordings.activeValues"))
        XCTAssertTrue(refresh.contains("markRecordingsLoaded()"))
        let background = exactBlock(
            appModel,
            startingWith: "private func publishBackgroundSyncSnapshot("
        )
        XCTAssertTrue(background.contains("let sessionsWereSynced"))
        XCTAssertTrue(background.contains("let recordingsWereSynced"))
        XCTAssertTrue(background.contains("markLoaded: sessionsWereSynced"))
        XCTAssertTrue(background.contains("hasLoadedSessions = sessionsWereSynced"))
        XCTAssertTrue(background.contains("hasLoadedRecordings = recordingsWereSynced"))
        XCTAssertFalse(background.contains("markRecordingsLoaded()"))
        let realtime = exactBlock(
            appModel,
            startingWith: "private func refreshReconcileSlices(_ slices: Set<ReconcileSlice>) async"
        )
        XCTAssertTrue(realtime.contains("markRecordingsLoaded()"))
        let reset = exactBlock(appModel, startingWith: "private func resetAccountState()")
        XCTAssertTrue(reset.contains("hasLoadedRecordings = false"))
        XCTAssertTrue(reset.contains("forceModel.hasLoadedRecordings = false"))
        XCTAssertTrue(
            normalizeWhitespace(appModel).contains(
                "let dataRefreshOwner = dataRefreshOwner ?? beginDataRefresh() defer { endDataRefresh(dataRefreshOwner) }"
            )
        )
        XCTAssertTrue(appModel.contains("let bootstrapRefreshOwner = beginDataRefresh()"))
        XCTAssertTrue(appModel.contains("dataRefreshOwner: bootstrapRefreshOwner"))
        XCTAssertFalse(appModel.contains("isLoadingData = true\n                // Adopt persisted"))
    }

    func testRemainingProductEmptyStatesKeepARealNextStep() {
        let consistency = code(source("Sources/Features/Force/ForceConsistencyCard.swift"))
        XCTAssertTrue(consistency.contains("ProductEmptyState("))
        XCTAssertTrue(consistency.contains("compact: true"))
        XCTAssertTrue(consistency.contains("actionTitle: emptyActionTitle"))
        XCTAssertTrue(consistency.contains("let showsPrimaryEmptyState: Bool"))
        XCTAssertTrue(consistency.contains("No recent force recordings match this view."))
        XCTAssertFalse(consistency.contains("No force recordings in the last 8 weeks"))

        let acwr = code(source("Sources/Features/Dashboard/AcwrProjectionCard.swift"))
        XCTAssertTrue(acwr.contains("title: \"Your next workout shapes the forecast\""))
        XCTAssertTrue(acwr.contains("actionTitle: \"Start a workout\""))
        XCTAssertTrue(acwr.contains("model.selectedTab = .workout"))
        XCTAssertFalse(acwr.contains("Text(\"Log a few sessions"))
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

    private func countButtonInvocations(in source: String) -> Int {
        let expression = try! NSRegularExpression(pattern: #"\bButton\s*(?:\(|\{)"#)
        return expression.numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
    }

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
