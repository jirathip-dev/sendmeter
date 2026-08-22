import Foundation
import XCTest

/// #672: structural proof that the force-stream state lives in its own
/// observable model, so a force publish no longer invalidates the cold
/// History/Dashboard/Settings rows. iOS 16 `@EnvironmentObject`/`@ObservedObject`
/// subscribe to the WHOLE object's `objectWillChange` — there is no
/// per-property observation. The only way to isolate is to hoist the hot domain
/// into its own `ObservableObject` and observe it only from the Force surface.
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
