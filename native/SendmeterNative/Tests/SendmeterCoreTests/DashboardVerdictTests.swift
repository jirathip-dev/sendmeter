@testable import SendmeterCore
import Foundation
import XCTest

/// #1028 E: #1022 one Dashboard verdict, #1023 sparse trend, #1024 no
/// implementation prose in user-facing copy.
final class DashboardVerdictTests: XCTestCase {
    /// #1022: every cell of the readiness × load table has copy.
    func testEveryCellHasCopy() {
        for score in [10, 55, 90] {
            for ratio in [nil, 0.5, 0.66, 1.0, 1.6] as [Double?] {
                let copy = DashboardVerdict.copy(readiness: score, ratio: ratio)
                XCTAssertFalse(copy.headline.isEmpty)
                XCTAssertEqual(copy.loadLine == nil, ratio == nil)
            }
        }
    }

    /// #1022: never "Recover" next to an unqualified "Under-training".
    func testNeverRecoverNextToUnqualifiedUnderTraining() {
        for score in stride(from: 0, through: 100, by: 5) {
            for ratio in stride(from: 0.0, through: 2.0, by: 0.05) {
                let copy = DashboardVerdict.copy(readiness: score, ratio: ratio)
                let all = copy.headline + " " + (copy.loadLine ?? "")
                XCTAssertFalse(all.contains("Under-training"), "\(score)/\(ratio): \(all)")
                if copy.headline.hasPrefix("Recover") {
                    XCTAssertFalse(all.contains("room to build"), "\(score)/\(ratio)")
                    XCTAssertFalse(all.contains("add volume"), "\(score)/\(ratio)")
                }
            }
        }
    }

    /// #1022: recovery advice appears once — the load line never repeats it.
    func testRecoveryAdviceAppearsOnce() {
        for score in stride(from: 0, through: 100, by: 5) {
            for ratio in stride(from: 0.0, through: 2.0, by: 0.1) {
                let copy = DashboardVerdict.copy(readiness: score, ratio: ratio)
                let line = (copy.loadLine ?? "").lowercased()
                XCTAssertFalse(line.contains("recover"), "\(score)/\(ratio): \(line)")
            }
        }
    }

    /// The owner's build-57 state: readiness 38, load ratio 0.66.
    func testOwnersState() {
        let copy = DashboardVerdict.copy(readiness: 38, ratio: 0.66)
        XCTAssertEqual(copy.headline, "Recover today — easy movement only.")
        XCTAssertEqual(copy.loadLine, "Load ratio 0.66 · light week, expected at low readiness")
    }

    func testBands() {
        XCTAssertEqual(DashboardVerdict.ReadinessBand(score: 39), .recover)
        XCTAssertEqual(DashboardVerdict.ReadinessBand(score: 40), .maintain)
        XCTAssertEqual(DashboardVerdict.ReadinessBand(score: 70), .maintain)
        XCTAssertEqual(DashboardVerdict.ReadinessBand(score: 71), .push)
        XCTAssertEqual(DashboardVerdict.LoadBand(ratio: 0.79), .under)
        XCTAssertEqual(DashboardVerdict.LoadBand(ratio: 0.8), .optimal)
        XCTAssertEqual(DashboardVerdict.LoadBand(ratio: 1.3), .optimal)
        XCTAssertEqual(DashboardVerdict.LoadBand(ratio: 1.31), .high)
        XCTAssertEqual(DashboardVerdict.LoadBand(ratio: .nan), .none)
    }

    /// #1023: the sparse threshold and its one line.
    func testSparseTrend() {
        XCTAssertTrue(ReadinessTrendDensity.isSparse(scoredDaysInWindow: 2))
        XCTAssertTrue(ReadinessTrendDensity.isSparse(scoredDaysInWindow: 4))
        XCTAssertFalse(ReadinessTrendDensity.isSparse(scoredDaysInWindow: 5))
        XCTAssertEqual(
            ReadinessTrendDensity.sparseLine(scoredDaysInWindow: 2),
            "2 readiness scores in the last 14 days — the trend needs a few more."
        )
        XCTAssertEqual(ReadinessTrendDensity.sparseLine(scoredDaysInWindow: 1).hasPrefix("1 readiness score "), true)
    }

    /// #1024: no implementation prose in user-facing copy (grep gate).
    func testNoImplementationProseInUserFacingCopy() throws {
        let banned = [
            "atomically", "sets, not sessions", "durable", "durably", "WatchConnectivity",
            "on-device queue", "local save is queued",
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let features = root.appendingPathComponent("Sources/Features")
        guard let files = FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil) else {
            return XCTFail("no Sources/Features")
        }
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // Only string literals rendered as UI text.
                guard trimmed.contains("Text(\"") || trimmed.contains("Label(\"")
                    || trimmed.contains("accessibilityLabel(\"") || trimmed.contains("return \"")
                else { continue }
                for word in banned where line.contains(word) {
                    offenders.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "implementation prose in UI copy (#1024):\n" + offenders.joined(separator: "\n"))
    }
}
