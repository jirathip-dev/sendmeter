import Foundation
import XCTest

/// #924: `HistoryView` is app-target code, so its wiring is pinned as a source
/// invariant (the repo's convention for SwiftUI views): the view must read all
/// derived History data from the snapshot and never call the whole-history
/// scan functions itself. The Core call-count test covers the snapshot; this
/// covers the view that consumes it.
final class HistoryDerivedDataWiringTests: XCTestCase {
    func testHistoryViewReadsDerivedDataFromTheSnapshot() {
        let history = code(source("Sources/Features/History/HistoryView.swift"))
        XCTAssertGreaterThan(history.count, 1_000, "HistoryView.swift did not load")

        XCTAssertEqual(
            countOccurrences("derivedCache.data(", in: history),
            1,
            "the view must build its derived data through one memoized snapshot"
        )
        XCTAssertTrue(history.contains("HistoryDerivedDataCache()"))

        for access in [
            "derived.recordingsByGroup",
            "derived.sessionGroupIDs",
            "derived.options",
            "derived.filteredSessions",
            "derived.filteredLooseRecordings",
            "derived.filteredForceRecordings",
            "derived.timelineItems",
            "derived.tindeqSessions",
        ] {
            XCTAssertTrue(history.contains(access), "missing snapshot read: \(access)")
        }
    }

    func testHistoryViewNeverCallsAWholeHistoryScan() {
        let history = code(source("Sources/Features/History/HistoryView.swift"))

        // These are the scans the pre-#924 view re-entered inside per-item
        // loops. They belong to `HistoryDerivedData` now: if one reappears
        // here, the per-item rescan is back.
        for scan in [
            "HistoryFilters.options(",
            "HistoryTimeline.looseRecordings(",
            "HistoryTimeline.combinedItems(",
        ] {
            XCTAssertEqual(
                countOccurrences(scan, in: history),
                0,
                "\(scan) must not be called from HistoryView — it is snapshot work"
            )
        }
    }

    // MARK: source helpers (duplicated from HistoryTapDetailWiringTests; the
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
