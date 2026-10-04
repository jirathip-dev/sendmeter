import Foundation
import XCTest

/// Structural coverage for the SwiftUI/Xcode application seams that the
/// Foundation-only widget contract cannot compile by itself. These assertions
/// keep the bootstrap, health batching, account reset, date sharing, timeline,
/// and family-layout fixes from drifting while the app target remains an
/// Xcode-only product.
final class ReadinessWidgetWiringTests: XCTestCase {
    func testSuccessfulRefreshPathGuaranteesBootstrapPublication() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        let refresh = exactBlock(
            appModel,
            startingWith: "private func refreshAll(\n"
        )

        XCTAssertTrue(refresh.contains("guard publishedLists else { return }"))
        XCTAssertEqual(countOccurrences("publishReadinessWidgetSnapshot()", in: refresh), 1)
        guard let warmTagCurves = refresh.range(
            of: "warmTagCurvesIfMissing(capturedBy: accountFetch)"
        ), let publication = refresh.range(of: "publishReadinessWidgetSnapshot()") else {
            XCTFail("Refresh path must warm tag curves before publishing the widget snapshot")
            return
        }
        XCTAssertTrue(warmTagCurves.upperBound < publication.lowerBound)
        XCTAssertTrue(appModel.contains("dataRefreshOwner: bootstrapRefreshOwner"))
    }

    func testHealthReconciliationPublishesOnceAfterTheBatch() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        let compute = exactBlock(
            appModel,
            startingWith: "private func computeAndPublishReadiness(\n"
        )
        let publishMetric = exactBlock(
            appModel,
            startingWith: "private func publishHealthMetric("
        )

        XCTAssertTrue(compute.contains("for upsert in plan.upserts"))
        XCTAssertEqual(countOccurrences("publishReadinessWidgetSnapshot()", in: compute), 1)
        XCTAssertFalse(publishMetric.contains("publishReadinessWidgetSnapshot()"))
    }

    func testResetUsesOwnerAwareWidgetBoundary() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        let reset = exactBlock(
            appModel,
            startingWith: "private func resetAccountState()"
        )

        XCTAssertTrue(reset.contains("accountEpoch &+= 1"))
        XCTAssertTrue(reset.contains("ReadinessWidgetBridge.reset(for: currentUserID)"))
    }

    func testWriterAndWidgetUseOneGregorianDayHelper() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        let publish = exactBlock(
            appModel,
            startingWith: "private func publishReadinessWidgetSnapshot()"
        )
        let widget = code(source("Sources/Widgets/ReadinessWidget.swift"))

        XCTAssertTrue(
            publish.contains(
                "ReadinessWidgetTimelinePolicy.localDayString(for: now)"
            )
        )
        XCTAssertFalse(publish.contains("LocalDateSupport.string(from: now)"))
        XCTAssertTrue(
            widget.contains("ReadinessWidgetTimelinePolicy.localDayString(for: date)")
        )
        XCTAssertFalse(widget.contains("private func readinessWidgetLocalDay"))
    }

    func testTimelineAndFamilyLayoutAreExplicit() {
        let widget = code(source("Sources/Widgets/ReadinessWidget.swift"))

        XCTAssertTrue(widget.contains("@Environment(\\.widgetFamily)"))
        XCTAssertTrue(widget.contains("widgetFamily == .systemLarge"))
        XCTAssertTrue(widget.contains("compact: true"))
        XCTAssertTrue(widget.contains("compact: false"))
        XCTAssertTrue(widget.contains("@ScaledMetric(relativeTo: .largeTitle)"))
        XCTAssertTrue(widget.contains("@ScaledMetric(relativeTo: .title)"))
        XCTAssertTrue(widget.contains("Timeline(entries: [entry, boundary], policy: .atEnd)"))
        XCTAssertTrue(widget.contains(".supportedFamilies([.systemMedium, .systemLarge])"))
        XCTAssertFalse(widget.contains("URL(string: \"sendmeter://dashboard\")!"))
    }

    func testPhonePrivacyManifestsMatchTheAppGroupCallPath() throws {
        let appManifest = try propertyList("native/SendmeterNative/Resources/PrivacyInfo.xcprivacy")
        let widgetManifest = try propertyList("native/SendmeterNative/Resources/Widgets/PrivacyInfo.xcprivacy")
        XCTAssertEqual(
            userDefaultsReasons(in: appManifest),
            Set(["CA92.1", "1C8F.1"])
        )
        XCTAssertEqual(
            userDefaultsReasons(in: widgetManifest),
            Set(["1C8F.1"])
        )

        let contract = code(source(
            "../../native-plugins/sendlog-health-core/Sources/SendLogHealthCore/ReadinessWidgetContract.swift"
        ))
        let bridge = code(source("Sources/App/ReadinessWidgetBridge.swift"))
        let widget = code(source("Sources/Widgets/ReadinessWidget.swift"))
        XCTAssertTrue(contract.contains("public static let appGroup ="))
        // #991: the App Group payload is read and written through an explicit
        // CurrentUser CFPreferences access. The suite APIs
        // (`UserDefaults(suiteName:)`, `addSuiteNamed:`) register AnyUser
        // domains next to the CurrentUser ones, and a containerized process
        // may not read an AnyUser source — the read that detached from
        // cfprefsd on every cold launch.
        XCTAssertTrue(contract.contains("CFPreferencesCopyValue("))
        XCTAssertTrue(contract.contains("kCFPreferencesCurrentUser"))
        XCTAssertFalse(contract.contains("kCFPreferencesAnyUser"))
        XCTAssertFalse(contract.contains("UserDefaults(suiteName:"))
        XCTAssertTrue(widget.contains("ReadinessWidgetStore.appGroupStore"))
        XCTAssertTrue(bridge.contains("store.save(snapshot)"))
    }

    func testWidgetPublicationReloadsAreDedupeAndCoalesced() {
        let bridge = code(source("Sources/App/ReadinessWidgetBridge.swift"))

        XCTAssertTrue(bridge.contains("ReadinessWidgetPublicationPolicy.shouldReload"))
        XCTAssertTrue(bridge.contains("private static var reloadScheduled = false"))
        XCTAssertTrue(bridge.contains("DispatchQueue.main.async"))
        XCTAssertEqual(
            countOccurrences("WidgetCenter.shared.reloadTimelines(ofKind: kind)", in: bridge),
            1
        )
    }

    func testWidgetPresentationAndBoundaryUseTruthfulSharedPolicies() {
        let widget = code(source("Sources/Widgets/ReadinessWidget.swift"))

        XCTAssertTrue(widget.contains("zone: snapshot.readinessZone"))
        XCTAssertTrue(widget.contains(".number.precision(.fractionLength(places))"))
        XCTAssertFalse(widget.contains("Locale(identifier: \"en_US_POSIX\")"))
        XCTAssertTrue(widget.contains("ReadinessWidgetTimelinePolicy.boundarySnapshot"))
        XCTAssertTrue(widget.contains("isDayBoundary"))
        XCTAssertTrue(widget.contains("Waiting for today's score"))
    }

    private func propertyList(_ relativePath: String) throws -> [String: Any] {
        let fileURL = repositoryRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: fileURL)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(value as? [String: Any])
    }

    private func userDefaultsReasons(in manifest: [String: Any]) -> Set<String> {
        guard let types = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
            XCTFail("Privacy manifest is missing NSPrivacyAccessedAPITypes")
            return []
        }
        return Set(
            types.compactMap { type -> [String]? in
                guard type["NSPrivacyAccessedAPIType"] as? String
                    == "NSPrivacyAccessedAPICategoryUserDefaults"
                else { return nil }
                return type["NSPrivacyAccessedAPITypeReasons"] as? [String]
            }
            .flatMap { $0 }
        )
    }

    private var repositoryRoot: URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
