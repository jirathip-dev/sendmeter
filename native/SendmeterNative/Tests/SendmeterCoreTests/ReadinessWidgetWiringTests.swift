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
