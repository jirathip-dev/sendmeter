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
