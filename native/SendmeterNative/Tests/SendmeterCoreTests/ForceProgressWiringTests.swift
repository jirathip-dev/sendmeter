import Foundation
import XCTest

final class ForceProgressWiringTests: XCTestCase {
    func testAppModelPublishesAfterAwaitedUploadSampleRemoval() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        let forceModel = code(source("Sources/App/ForceModel.swift"))

        XCTAssertTrue(
            forceModel.contains(
                "@Published public internal(set) var forceProgressRevision: UInt64 = 0"
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

    func testCurveGuardsStayOnBothSidesOfTheAwaitedModelFit() {
        let appModel = code(source("Sources/App/AppModel.swift"))
        let curveFunction = exactFunction(
            appModel,
            startingWith: "public func forceCurveModel("
        )
        let fitAwait = curveFunction.range(of: "await fetchForceCurveModel(")
        XCTAssertNotNil(fitAwait)
        guard let fitAwait else { return }

        let beforeAwait = String(curveFunction[..<fitAwait.lowerBound])
        let afterAwait = String(curveFunction[fitAwait.upperBound...])
        let inputKeyCheck = "forceProgressCurveInputKey(tag: tag, side: side) == requestKey"

        XCTAssertEqual(occurrences(of: "!Task.isCancelled", in: beforeAwait), 1)
        XCTAssertEqual(occurrences(of: inputKeyCheck, in: beforeAwait), 1)
        XCTAssertTrue(
            normalizeWhitespace(beforeAwait).contains(
                "guard !Task.isCancelled, side != .unspecified, let userID = currentUserID else { return nil }"
            )
        )

        XCTAssertEqual(occurrences(of: "!Task.isCancelled", in: afterAwait), 1)
        XCTAssertEqual(occurrences(of: inputKeyCheck, in: afterAwait), 1)
        XCTAssertTrue(afterAwait.contains("accountFetch.canApply"))
        XCTAssertTrue(
            normalizeWhitespace(afterAwait).contains(
                "guard !Task.isCancelled, accountFetch.canApply( to: currentUserID, accountEpoch: accountEpoch ), forceProgressCurveInputKey(tag: tag, side: side) == requestKey else { return nil }"
            )
        )
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
        XCTAssertTrue(forceView.contains("progressRevision: forceModel.forceProgressRevision"))
        XCTAssertTrue(forceView.contains("curveRevision: sideScopedForceCurveRevision"))
        XCTAssertTrue(forceView.contains("sideScopedForceCurveRevision"))
        let loadCurveBody = exactFunction(
            forceView,
            startingWith: "private func loadProgressCurve() async"
        )
        XCTAssertTrue(loadCurveBody.contains("sideScopedForceCurve = nil"))
        XCTAssertTrue(loadCurveBody.contains("sideScopedForceCurve = curve"))
        XCTAssertTrue(loadCurveBody.contains("sideScopedForceCurveRevision &+= 1"))
        let modelFitAwait = loadCurveBody.range(of: "await model.forceCurveModel(")
        XCTAssertNotNil(modelFitAwait)
        if let modelFitAwait {
            let afterModelFit = String(loadCurveBody[modelFitAwait.upperBound...])
            XCTAssertEqual(occurrences(of: "!Task.isCancelled", in: afterModelFit), 1)
            XCTAssertEqual(occurrences(of: "progressCurveKey == requestKey", in: afterModelFit), 1)
            let postFitGuard = loadCurveBody.range(
                of: "guard !Task.isCancelled, progressCurveKey == requestKey else { return }"
            )
            XCTAssertNotNil(postFitGuard)
            if let postFitGuard {
                XCTAssertEqual(
                    normalizeWhitespace(String(loadCurveBody[postFitGuard.lowerBound..<postFitGuard.upperBound])),
                    "guard !Task.isCancelled, progressCurveKey == requestKey else { return }"
                )
            }
        }
        XCTAssertTrue(card.contains("ForceProgressCardKey("))
        let equalityFunction = exactFunction(
            card,
            startingWith: "static func == (lhs: Self, rhs: Self) -> Bool"
        )
        XCTAssertEqual(
            normalizeWhitespace(equalityFunction),
            "static func == (lhs: Self, rhs: Self) -> Bool { lhs.renderKey == rhs.renderKey }"
        )
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

    private func exactFunction(_ source: String, startingWith marker: String) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant function: \(marker)")
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

        XCTFail("Unclosed source invariant function: \(marker)")
        return ""
    }

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
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
