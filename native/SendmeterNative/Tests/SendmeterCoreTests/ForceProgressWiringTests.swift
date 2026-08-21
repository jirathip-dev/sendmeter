import Foundation
import XCTest

final class ForceProgressWiringTests: XCTestCase {
    func testAppModelPublishesAfterAwaitedUploadSampleRemoval() {
        let appModel = code(source("Sources/App/AppModel.swift"))

        XCTAssertTrue(
            appModel.contains(
                "@Published public private(set) var forceProgressRevision: UInt64 = 0"
            )
        )

        let publishBody = region(
            appModel,
            from: "private func publishForceProgressInputMutation",
            to: "private func storePendingCurveSamples"
        )
        XCTAssertTrue(publishBody.contains("forceProgressRevision = revision"))

        let curvePublicationBody = region(
            appModel,
            from: "private func publishTagCurves",
            to: "private func refreshTagCurvesForRPE"
        )
        XCTAssertTrue(curvePublicationBody.contains(".curveModel"))

        let sampleRemovalBody = region(
            appModel,
            from: "private func removePendingCurveSamples",
            to: "private func clearPendingCurveSamples"
        )
        XCTAssertTrue(
            sampleRemovalBody.contains("publishForceProgressInputMutation(.localSamples)")
        )

        let uploadBody = region(
            appModel,
            from: "case let .recording(recording):",
            to: "case let .recordingEdit(edit):"
        )
        let awaitedFit = uploadBody.range(of: "await refreshTagCurvesForRPE")
        let localRemoval = uploadBody.range(
            of: "removePendingCurveSamples(for: recording.id)"
        )
        XCTAssertNotNil(awaitedFit)
        XCTAssertNotNil(localRemoval)
        if let awaitedFit, let localRemoval {
            XCTAssertLessThan(awaitedFit.lowerBound, localRemoval.lowerBound)
            let validationBeforeRemoval = uploadBody[..<localRemoval.lowerBound]
            XCTAssertTrue(validationBeforeRemoval.contains("accountFetch.canApply"))
        }
    }

    func testForceViewUsesRevisionKeyedEquatableBoundaryWithoutFullArrayEquality() {
        let forceView = code(source("Sources/Features/Force/ForceView.swift"))
        let card = code(source("Sources/Features/Force/ForceProgressCard.swift"))
        let boundary = region(
            card,
            from: "struct ForceProgressCardBoundary: View, Equatable",
            to: "struct ForceProgressCard: View"
        )

        XCTAssertTrue(forceView.contains(".task(id: progressCurveKey)"))
        XCTAssertTrue(forceView.contains("ForceProgressCardBoundary("))
        XCTAssertTrue(forceView.contains(".equatable()"))
        XCTAssertTrue(forceView.contains("progressRevision: model.forceProgressRevision"))
        XCTAssertTrue(forceView.contains("curveRevision: sideScopedForceCurveRevision"))
        XCTAssertTrue(forceView.contains("sideScopedForceCurveRevision"))
        let loadCurveBody = region(
            forceView,
            from: "private func loadProgressCurve()",
            to: "private func resolveSelectedTarget()"
        )
        XCTAssertTrue(loadCurveBody.contains("sideScopedForceCurve = nil"))
        XCTAssertTrue(loadCurveBody.contains("sideScopedForceCurve = curve"))
        XCTAssertTrue(loadCurveBody.contains("sideScopedForceCurveRevision &+= 1"))
        XCTAssertTrue(card.contains("ForceProgressCardKey("))
        XCTAssertTrue(card.contains("static func == (lhs: Self, rhs: Self) -> Bool"))
        XCTAssertTrue(card.contains("@State private var detail: Detail?"))
        XCTAssertTrue(boundary.contains("ForceProgressCard("))
        XCTAssertFalse(boundary.contains("ForceProgress.staticCapacityProgress"))
        XCTAssertFalse(boundary.contains("ForceProgress.movementProgress"))
        XCTAssertFalse(boundary.contains("recordings =="))
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

    private func region(_ source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(
                  of: end,
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant region: \(start) → \(end)")
            return ""
        }
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }
}
