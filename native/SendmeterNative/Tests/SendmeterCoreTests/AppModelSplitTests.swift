import Foundation
import XCTest

/// #672/#783: structural proof that the force-stream state lives in its own
/// observable model and that AppModel/TindeqBluetooth use Swift Observation,
/// so a force tick does not invalidate unrelated views. The native rewrite is
/// iOS 17+ because `@Observable` and typed `@Environment` are unavailable on
/// older deployment targets.
final class AppModelSplitTests: XCTestCase {
    func testForceStateLivesInDedicatedObservableModel() {
        let forceModel = code(source("Sources/App/ForceModel.swift"))
        for declaration in [
            "@Published public internal(set) var forceProgressRevision: UInt64 = 0",
            "@Published public internal(set) var tagCurves: [TagForceCurve] = []",
            "@Published public internal(set) var guidedProtocolActive = false",
            "@Published public internal(set) var hasLoadedRecordings = false",
        ] {
            XCTAssertTrue(
                forceModel.contains(declaration),
                "ForceModel.swift should own the force-stream state: \(declaration)"
            )
        }
    }

    func testAppModelNoLongerPublishesForceStreamState() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        for declaration in [
            "@Published public private(set) var forceProgressRevision: UInt64 = 0",
            "@Published public private(set) var tagCurves: [TagForceCurve] = []",
            "@Published public private(set) var guidedProtocolActive = false",
            "@Published public private(set) var hasLoadedRecordings = false",
        ] {
            XCTAssertFalse(
                appModel.contains(declaration),
                "AppModel.swift must not publish force-stream state: \(declaration)"
            )
        }
    }

    func testAppModelUsesTypedObservationEnvironment() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        XCTAssertTrue(appModel.contains("import Observation"))
        XCTAssertTrue(appModel.contains("@Observable\npublic final class AppModel"))
        XCTAssertFalse(appModel.contains("ObservableObject"))
        XCTAssertFalse(appModel.contains("@Published public"))

        let root = code(source("Sources/App/SendmeterNativeApp.swift"))
        // The App struct owns exactly one AppModel. Its custom init creates
        // that instance once so #747 can register the same object with the
        // background-sync handler, then installs it into @State's backing
        // storage. Do not regress to a declaration initializer: that can
        // construct a second model before the custom init runs.
        XCTAssertTrue(root.contains("@State private var model: AppModel"))
        XCTAssertFalse(root.contains("@State private var model = AppModel()"))
        XCTAssertTrue(root.contains("let model = AppModel()"))
        XCTAssertTrue(root.contains("_model = State(wrappedValue: model)"))
        XCTAssertTrue(root.contains("BackgroundSyncService.register(model: model)"))
        XCTAssertTrue(root.contains(".environment(model)"))
        XCTAssertTrue(root.contains("@Environment(AppModel.self) private var model"))
        XCTAssertFalse(root.contains("environmentObject(model)"))
        XCTAssertFalse(root.contains("@StateObject private var model"))

        for path in [
            "Sources/Features/Auth/LoginView.swift",
            "Sources/Features/Dashboard/DashboardView.swift",
            "Sources/Features/Force/ForceView.swift",
            "Sources/Features/History/HistoryView.swift",
            "Sources/Features/Phases/PhasesView.swift",
            "Sources/Features/Settings/SettingsView.swift",
            "Sources/Features/Workout/WorkoutView.swift",
        ] {
            let consumer = code(source(path))
            XCTAssertFalse(
                consumer.contains("@EnvironmentObject private var model: AppModel"),
                "(path) must use typed Observation environment"
            )
        }
    }

    func testTindeqUsesRangeBackedObservationStream() {
        let tindeq = code(source("Sources/Platform/TindeqBluetooth.swift"))
        XCTAssertTrue(tindeq.contains("import Observation"))
        XCTAssertTrue(tindeq.contains("@Observable\npublic final class TindeqBluetooth"))
        XCTAssertFalse(tindeq.contains("ObservableObject"))
        XCTAssertFalse(tindeq.contains("@Published"))
        XCTAssertTrue(tindeq.contains("public private(set) var visibleSampleRange: Range<Int>"))
        XCTAssertTrue(tindeq.contains("@ObservationIgnored public let sampleBuffer: ForceSampleBuffer"))
        XCTAssertTrue(tindeq.contains("pendingPublish = true"))
        XCTAssertFalse(tindeq.contains("visibleSamples"))
        XCTAssertFalse(tindeq.contains("Array(accumulator.samples[snapshot.visibleRange])"))

        let forceView = code(source("Sources/Features/Force/ForceView.swift"))
        XCTAssertTrue(forceView.contains("let device: TindeqBluetooth"))
        XCTAssertTrue(forceView.contains("buffer: device.sampleBuffer"))
        XCTAssertTrue(forceView.contains("range: device.visibleSampleRange"))
        XCTAssertTrue(forceView.contains("case buffer(ForceSampleBuffer, Range<Int>)"))
    }

    func testTindeqTimerDeinitAndMainActorBoundaryAreExplicit() {
        let tindeq = code(source("Sources/Platform/TindeqBluetooth.swift"))

        // A @MainActor deinit is nonisolated by language rule. Keep the timer
        // slot explicitly unsafe only at that boundary so deinit can stop a
        // RunLoop.main timer without weakening the rest of the class.
        XCTAssertTrue(
            tindeq.contains("private nonisolated(unsafe) var flushTimer: Timer?")
        )
        XCTAssertTrue(tindeq.contains("deinit {"))
        XCTAssertTrue(tindeq.contains("flushTimer?.invalidate()"))

        // The callback is installed on RunLoop.main and must synchronously
        // enter MainActor. A Task hop here would add one allocation per frame
        // to the 60 Hz display path.
        XCTAssertTrue(tindeq.contains("RunLoop.main.add(timer, forMode: .common)"))
        XCTAssertTrue(tindeq.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(tindeq.contains("self.flushIfDue()"))
    }

    func testWatchCompletionAdoptionKeepsGateClaimThroughCallSite() {
        let appModel = source("Sources/App/AppModel.swift")
        guard let start = appModel.range(of: "private func acceptWatchCompletion(") else {
            return XCTFail("watch completion adoption function is missing")
        }
        guard let end = appModel.range(
            of: "    // MARK: Live workout mirror",
            range: start.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("watch completion adoption function boundary is missing")
        }
        let adoption = code(String(appModel[start.lowerBound..<end.lowerBound]))

        guard let adoptCase = adoption.range(of: "case .adopt:") else {
            return XCTFail("adopt decision case is missing")
        }
        guard let switchEnd = adoption.range(
            of: "\n        }\n",
            range: adoptCase.upperBound..<adoption.endIndex
        ) else {
            return XCTFail("adoption decision switch boundary is missing")
        }
        let adoptCaseBody = adoption[adoptCase.upperBound..<switchEnd.lowerBound]
        XCTAssertTrue(
            adoptCaseBody.contains("break"),
            "the adopt case must fall through to the function-scoped cleanup"
        )
        XCTAssertFalse(
            adoptCaseBody.contains("watchCompletionAdoption.finish"),
            "cleanup inside the switch case fires before adoption"
        )
        XCTAssertTrue(
            adoption.contains(
                "defer { watchCompletionAdoption.finish(completion.identity) }"
            ),
            "the adoption path must release its claim with a function-scoped defer"
        )
    }

    func testWatchCompletionCallSiteRetriesForegroundAndDistinguishesCorruptCache() {
        let appModel = source("Sources/App/AppModel.swift")
        let withoutComments = code(appModel)

        guard let activeStart = withoutComments.range(of: "public func becameActive()") else {
            return XCTFail("becameActive is missing")
        }
        guard let activeEnd = withoutComments.range(
            of: "private func handleAuthEvent",
            range: activeStart.upperBound..<withoutComments.endIndex
        ) else {
            return XCTFail("becameActive boundary is missing")
        }
        XCTAssertTrue(
            withoutComments[activeStart.lowerBound..<activeEnd.lowerBound]
                .contains("await acceptStoredWatchCompletions()"),
            "foreground must retry retained watch completions"
        )

        guard let adoptionStart = withoutComments.range(of: "private func acceptWatchCompletion(") else {
            return XCTFail("watch completion adoption function is missing")
        }
        guard let adoptionEnd = withoutComments.range(
            of: "private func acceptLiveWorkoutMessage",
            range: adoptionStart.upperBound..<withoutComments.endIndex
        ) else {
            return XCTFail("watch completion adoption function boundary is missing")
        }
        let adoption = withoutComments[adoptionStart.lowerBound..<adoptionEnd.lowerBound]
        XCTAssertTrue(adoption.contains("loadOneResult"))
        XCTAssertTrue(adoption.contains(".corrupt"))
        XCTAssertTrue(
            adoption.contains("case .unavailable, .corrupt:"),
            "cache degradation must keep a visible pending overlay while retaining the inbox row"
        )
    }

    func testAccountBoundaryWiresWatchScopeAndDestructiveEpochFence() {
        let appModel = code(source("Sources/App/AppModel.swift"))

        XCTAssertTrue(
            appModel.contains("watch.setAccountScope(currentUserID)"),
            "account reset must move WatchConnectivity onto the new visible account"
        )
        XCTAssertTrue(
            appModel.contains("watch.clearAccountTransientState()"),
            "account reset must clear live/telemetry transport state"
        )
        XCTAssertTrue(
            appModel.contains("trustsUnstamped: false"),
            "the AppModel must fail closed for ownerless legacy live beats"
        )
        XCTAssertTrue(
            appModel.contains("case .signedOut, .wrongAccount, .unscopedLegacy, .inFlightDuplicate:"),
            "ownerless watch completions must not enter the adoption path"
        )

        guard let deleteStart = appModel.range(of: "public func deleteAccount() async") else {
            return XCTFail("deleteAccount is missing")
        }
        guard let deleteEnd = appModel.range(
            of: "private func askAboutSignOutRemainder",
            range: deleteStart.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("deleteAccount boundary is missing")
        }
        let deletion = appModel[deleteStart.lowerBound..<deleteEnd.lowerBound]
        XCTAssertTrue(deletion.contains("accountEpoch: accountEpoch &+ 1"))
        XCTAssertTrue(deletion.contains("try await self.repository.deleteAccount()"))
        XCTAssertTrue(
            deletion.contains("try await self.queue?.discardAll(accountUserID: userID, reason: \"account-deleted\")")
        )
        XCTAssertTrue(
            deletion.contains("self.watch.discardStoredCompletions(for: userID)"),
            "account deletion must purge only the deleted account's durable watch inbox rows"
        )
    }

    func testManualQueueRetryWaitsForInFlightOwnerAndPublishesFailureState() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        XCTAssertTrue(appModel.contains("public private(set) var queuedWriteDiagnostics"))
        XCTAssertTrue(appModel.contains("public var latestQueuedWriteFailure"))
        XCTAssertTrue(appModel.contains("lastFailureAt: lastFailure?.at"))

        guard let retryStart = appModel.range(of: "public func retryAllQueuedWrites() async") else {
            return XCTFail("retryAllQueuedWrites is missing")
        }
        guard let retryEnd = appModel.range(
            of: "private func retryQueuedWrite(",
            range: retryStart.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("retry helper boundary is missing")
        }
        let retry = appModel[retryStart.lowerBound..<retryEnd.lowerBound]
        XCTAssertTrue(retry.contains("await retryQueuedWrite("))
        XCTAssertTrue(retry.contains("await refreshQueueCount(for: accountFetch)"))

        guard let helperEnd = appModel.range(
            of: "public func runBackgroundSync(",
            range: retryEnd.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("retry helper end is missing")
        }
        let helper = appModel[retryEnd.lowerBound..<helperEnd.lowerBound]
        XCTAssertTrue(helper.contains("await waitForQueueUpload(key)"))
        XCTAssertTrue(helper.contains("let current = await queue.item("))
        XCTAssertTrue(helper.contains("QueueRetryPolicy.beforeUpload("))
        XCTAssertTrue(helper.contains("QueueRetryPolicy.afterUpload("))
        XCTAssertTrue(helper.contains("mode: .manual"))
        XCTAssertTrue(helper.contains("recordedFailure: result.failure != nil"))
    }

    func testAuthRecoveryDrainsSameAccountWithoutDiscardingActiveQueue() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        XCTAssertTrue(appModel.contains("queuedWriteDiagnostics"))
        guard let start = appModel.range(of: "private func handleAuthEvent") else {
            return XCTFail("handleAuthEvent is missing")
        }
        guard let end = appModel.range(
            of: "case .passwordRecovery:",
            range: start.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("auth event switch boundary is missing")
        }
        let authHandler = appModel[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(authHandler.contains("case .signedIn, .tokenRefreshed:"))
        XCTAssertTrue(authHandler.contains("await drainQueue(mode: .authRecovery)"))
        XCTAssertFalse(authHandler.contains("discardAll(accountUserID:"))
    }

    func testPendingDeleteCancelsUpsertButUploadedDeleteStillUsesTrashPath() {
        let appModel = code(source("Sources/App/AppModel.swift"))

        guard let deleteStart = appModel.range(of: "public func deleteSession(") else {
            return XCTFail("deleteSession is missing")
        }
        guard let undoStart = appModel.range(
            of: "public func undoSession(",
            range: deleteStart.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("undoSession boundary is missing")
        }
        let delete = appModel[deleteStart.lowerBound..<undoStart.lowerBound]
        XCTAssertTrue(delete.contains("session.pending"))
        XCTAssertTrue(delete.contains("pendingSessions[session.id] != nil"))
        XCTAssertTrue(delete.contains("await undoSession("))
        XCTAssertTrue(delete.contains("PendingSessionDeletePolicy.successMessage"))
        XCTAssertTrue(delete.contains("repository.softDeleteSession(id: session.id)"))

        guard let uploadEnd = appModel.range(
            of: "private func upload(",
            range: undoStart.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("upload boundary is missing")
        }
        let undo = appModel[undoStart.lowerBound..<uploadEnd.lowerBound]
        XCTAssertTrue(undo.contains("enqueueReplacing("))
        XCTAssertTrue(undo.contains("canceling: cancelingInserts"))
        XCTAssertTrue(undo.contains("SessionDeleteQueuePayload"))

        let upload = appModel[uploadEnd.lowerBound..<appModel.endIndex]
        XCTAssertTrue(upload.contains("if waitForSessionInsert"))
        XCTAssertTrue(upload.contains("await waitForQueueUpload("))
        XCTAssertTrue(upload.contains("repository.softDeleteSession(id: deletePayload.sessionID)"))
        XCTAssertTrue(upload.contains("waitForSessionInsert: false"))
        XCTAssertTrue(upload.contains("PendingSessionDeletePolicy.matches("))
        XCTAssertTrue(upload.contains("finishedSessionInsert = .manualWorkout"))
        XCTAssertTrue(upload.contains("case let .workout(draft):"))
        XCTAssertTrue(upload.contains("if routineUndo.isClaimed(receipt)"))

        guard let restoreStart = appModel.range(of: "private func restorePendingWrites(") else {
            return XCTFail("restorePendingWrites is missing")
        }
        let restore = appModel[restoreStart.lowerBound..<appModel.endIndex]
        XCTAssertTrue(restore.contains("PendingSessionDeletePolicy.shouldRestore("))
        XCTAssertTrue(restore.contains(".manualWorkout(sessionID: draft.sessionID)"))
    }

    func testHealthBackfillProductionSeamsUseExactWindowAndLifecycleProgress() {
        let healthKit = code(source("Sources/Platform/HealthKitService.swift"))
        XCTAssertTrue(healthKit.contains("HealthMetricReadWindow.queryLookbackDays"))
        XCTAssertTrue(healthKit.contains("HealthMetricReadWindow.candidateOffsets"))
        XCTAssertTrue(healthKit.contains("HealthMetricReadWindow.baselineOffsets"))
        XCTAssertFalse(healthKit.contains("0...HealthMetricReconciliationPolicy"))

        let appModel = code(source("Sources/App/AppModel.swift"))
        guard let morningStart = appModel.range(
            of: "private func handleHealthBackgroundUpdate()"
        ), let morningEnd = appModel.range(
            of: "private func computeAndPublishReadiness(",
            range: morningStart.upperBound..<appModel.endIndex
        ) else {
            return XCTFail("morning health production seam is missing")
        }
        let morning = appModel[morningStart.lowerBound..<morningEnd.lowerBound]
        XCTAssertTrue(morning.contains("persistMorningHealthProgress"))
        XCTAssertTrue(morning.contains("BackgroundSyncService.schedule"))
        XCTAssertFalse(morning.contains("Task.sleep"))
        XCTAssertFalse(morning.contains("morningHealthRefreshTask"))
        XCTAssertFalse(morning.contains("runMorningHealthRepolls"))
        XCTAssertFalse(morning.contains("await self?.runMorningHealthRepolls"))
        XCTAssertTrue(morning.contains("finishMorningHealthRefresh"))
        XCTAssertTrue(appModel.contains("loadMorningHealthProgress(for:"))
        XCTAssertTrue(appModel.contains(
            "private var morningHealthRefreshState = HealthMorningRefreshStateMachine()"
        ))
        XCTAssertTrue(appModel.contains("mode: .resumePersisted"))
        XCTAssertTrue(appModel.contains("mode: .newWindow"))
        XCTAssertFalse(appModel.contains("pass != 0 || healthMorningRefreshPolicy.shouldStart"))
    }

    func testHealthRepositoryUsesAtomicHistoricalInsertAndTodayMerge() {
        let repository = code(source("Sources/Data/Repositories.swift"))
        XCTAssertTrue(repository.contains("insertHealthMetricIfMissing"))
        XCTAssertTrue(repository.contains("HealthMetricWriteOperation.historicalInsert.preferHeader"))
        XCTAssertTrue(repository.contains("HealthMetricWriteOperation.todayMerge.preferHeader"))
        XCTAssertTrue(repository.contains("return !receipts.isEmpty"))

        let appModel = code(source("Sources/App/AppModel.swift"))
        XCTAssertTrue(appModel.contains("HealthMetricWritePolicy.operation"))
        XCTAssertTrue(appModel.contains("insertHealthMetricIfMissing("))
        XCTAssertTrue(appModel.contains("repository.upsertHealthMetric"))
    }

    func testHealthBackfillCancellationAndTimezoneOwnershipStayInProductionSeams() {
        let healthKit = code(source("Sources/Platform/HealthKitService.swift"))
        XCTAssertTrue(healthKit.contains("HealthKitQueryCancellation"))
        XCTAssertEqual(
            healthKit.components(separatedBy: "withTaskCancellationHandler").count - 1,
            3,
            "each checked HealthKit query must own a cancellation handler"
        )
        XCTAssertTrue(healthKit.contains("store.stop(query)"))
        XCTAssertTrue(healthKit.contains("continuation?.resume(with: result)"))
        XCTAssertTrue(healthKit.contains("continuation?.resume(throwing: CancellationError())"))
        XCTAssertFalse(healthKit.contains("private let calendar: Calendar"))
        XCTAssertTrue(healthKit.contains("timeZone: TimeZone = .current"))
        XCTAssertTrue(healthKit.contains("LocalDateSupport.calendar(timeZone: timeZone)"))

        let appModel = code(source("Sources/App/AppModel.swift"))
        XCTAssertTrue(appModel.contains("timeZoneIdentifier: passTimeZone.identifier"))
        XCTAssertTrue(appModel.contains("health.computeMetrics(\n                    acwrByDate: acwrByDate,\n                    timeZone: passTimeZone"))
        XCTAssertTrue(appModel.contains("guard !Task.isCancelled, accountFetch.canApply"))
        XCTAssertTrue(appModel.contains("if !Task.isCancelled, let observation = progress?.finalObservation"))

        guard let computeStart = appModel.range(
            of: "private func computeAndPublishReadiness("
        ) else {
            return XCTFail("production reconciliation seam is missing")
        }
        let compute = appModel[computeStart.lowerBound...]
        for marker in [
            "insertHealthMetricIfMissing",
            "repository.upsertHealthMetric",
            "cacheUpsertServer",
            "cacheConfirmServerUpsert",
            "publishHealthMetric",
            "watch.publishReadiness",
            "recomputeGate.complete()"
        ] {
            guard let markerStart = compute.range(of: marker) else {
                return XCTFail("reconciliation marker is missing: \(marker)")
            }
            let beforeMarker = compute[..<markerStart.lowerBound]
            XCTAssertTrue(
                beforeMarker.contains("!Task.isCancelled"),
                "reconciliation must fence cancellation before \(marker)"
            )
        }
    }

    func testSwiftPMExcludedSourcesAreSwiftSyntaxParseable() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot.appendingPathComponent("Sources")
        let excludedRoots: Set<String> = [
            "App", "Data", "Features", "Platform", "Shared", "Widgets"
        ]
        let excludedSources = (
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL } ?? []
        )
        .filter { url in
            guard url.pathExtension == "swift" else { return false }
            let relativePath = String(
                url.path.dropFirst(sourcesRoot.path.count + 1)
            )
            guard let root = relativePath.split(separator: "/").first,
                  excludedRoots.contains(String(root)) else {
                return false
            }
            return relativePath != "App/ChartTheme.swift"
                && relativePath != "Platform/WeatherService.swift"
        }
        .sorted { $0.path < $1.path }

        XCTAssertFalse(excludedSources.isEmpty)

        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sendmeter-swift-parse-\(UUID().uuidString).stderr"
            )
        defer { try? FileManager.default.removeItem(at: diagnosticsURL) }
        guard FileManager.default.createFile(
            atPath: diagnosticsURL.path,
            contents: Data()
        ) else {
            return XCTFail("could not create syntax diagnostics file")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "-parse"] + excludedSources.map(\.path)
        let diagnostics = try FileHandle(forWritingTo: diagnosticsURL)
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()
        try diagnostics.close()

        let stderr = try String(
            contentsOf: diagnosticsURL,
            encoding: .utf8
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "SwiftPM-excluded sources must pass a syntax-only parse (\(excludedSources.count) files):\n\(stderr)"
        )
    }

    func testAppModelDeinitCanCancelEveryLifecycleTaskHandle() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        let handles = [
            "authObservationTask",
            "liveMirrorTicker",
            "reconcileFlushTask",
        ]

        // These are the only AppModel task handles touched by deinit. They
        // remain MainActor-owned during normal operation; only the final,
        // thread-safe Task.cancel() signal crosses the nonisolated boundary.
        for handle in handles {
            XCTAssertTrue(
                appModel.contains(
                    "private nonisolated(unsafe) var \(handle): Task<Void, Never>?"
                ),
                "\(handle) must be explicitly safe for nonisolated deinit"
            )
        }

        guard let start = appModel.range(of: "deinit {") else {
            XCTFail("AppModel must keep an explicit deinit lifecycle cleanup")
            return
        }
        let afterStart = appModel[start.upperBound...]
        guard let end = afterStart.firstIndex(of: "}") else {
            XCTFail("AppModel deinit body could not be read")
            return
        }
        let deinitBody = afterStart[..<end]
        for handle in handles {
            XCTAssertTrue(
                deinitBody.contains("\(handle)?.cancel()"),
                "AppModel deinit must cancel \(handle)"
            )
        }
    }

    func testForceModelInjectedAndObservedOnlyByForceSurface() {
        let root = code(source("Sources/App/SendmeterNativeApp.swift"))
        XCTAssertTrue(root.contains("environmentObject(model.forceModel)"))

        let forceView = code(source("Sources/Features/Force/ForceView.swift"))
        XCTAssertTrue(
            forceView.contains("@EnvironmentObject private var forceModel: ForceModel")
        )
        XCTAssertTrue(forceView.contains("forceModel.tagCurves"))
        XCTAssertTrue(forceView.contains("forceModel.forceProgressRevision"))
        XCTAssertTrue(forceView.contains("forceModel.hasLoadedRecordings"))

        // The cold surfaces must NOT observe the Force domain. If any of them
        // declared `@EnvironmentObject var forceModel`, a force publish would
        // invalidate them again — defeating the split.
        for path in [
            "Sources/Features/Dashboard/DashboardView.swift",
            "Sources/Features/History/HistoryView.swift",
            "Sources/Features/Settings/SettingsView.swift",
            "Sources/Features/Workout/WorkoutView.swift",
        ] {
            let cold = code(source(path))
            XCTAssertFalse(
                cold.contains("forceModel"),
                "\(path) must not observe ForceModel (force-stream must not invalidate it)"
            )
        }
    }

    // MARK: source helpers (duplicated from ForceProgressWiringTests; the
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
}
