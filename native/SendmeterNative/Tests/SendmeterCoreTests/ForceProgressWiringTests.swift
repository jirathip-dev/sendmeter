import Foundation
import SendmeterCore
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
        XCTAssertTrue(forceView.contains("targetBand: selectedTargetReferenceBand"))
        XCTAssertTrue(card.contains("targetBand: targetBand"))
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

    func testForceOwnersRouteThroughGuidedHandsFreeAndRefusals() {
        let forceView = code(source("Sources/Features/Force/ForceView.swift"))

        XCTAssertFalse(forceView.contains("ManualForceFullscreen("))
        XCTAssertFalse(forceView.contains("startMeasurement"))
        XCTAssertTrue(forceView.contains("GuidedForceHandsFreeTimingPolicy"))
        XCTAssertTrue(forceView.contains("case .refusedActiveRecording"))
        XCTAssertTrue(forceView.contains("model.handsFree.cancelArm()"))
        XCTAssertTrue(forceView.contains("model.handsFree.stopPolicy = .callerOwned"))
    }

    // MARK: #874/#901 — guided launch keeps an explicit Left through run construction
    //
    // REAL behavior tests (no source-text assertions): they construct the run
    // exactly as `GuidedForceProtocolSession.init` does after #901
    // (`ForceProtocolRun(preset:startingSide:selectedSide:)` with
    // `selectedSide` = the normalized side selection / fallbackSide) and
    // assert the produced stages, so a Left→Both coercion anywhere in the
    // schedule/attribution boundary turns them red, and so a Left/Right
    // selection can never regress into an alternating schedule (#901).

    func testGuidedAlternatingRunFirstWorkStageKeepsExplicitLeft() {
        let run = ForceProtocolRun(
            preset: Self.alternatingPreset(),
            startingSide: .left,
            selectedSide: .left
        )
        let firstWork = run.stages.first(where: { $0.kind == .work })
        XCTAssertEqual(firstWork?.side, .left)
        XCTAssertFalse(run.stages.contains { $0.side == .both })
        // #901: an explicit Left must run LEFT ONLY — no opposite-side work
        // and no switch-hands stages, even though the preset alternates.
        let work = run.stages.filter { $0.kind == .work }
        XCTAssertFalse(work.isEmpty)
        XCTAssertTrue(work.allSatisfy { $0.side == .left })
        XCTAssertFalse(run.stages.contains { $0.kind == .switchSide })
        XCTAssertFalse(run.stages.contains { $0.side == .right })
    }

    func testGuidedSaveAttributionSideStaysLeftForExplicitLeft() {
        let run = ForceProtocolRun(
            preset: Self.alternatingPreset(),
            startingSide: .left,
            selectedSide: .left
        )
        let fallbackSide: TindeqSide = .left
        let firstWork = try? XCTUnwrap(run.stages.first(where: { $0.kind == .work }))
        guard let firstWork else { return }
        // Same rule the session's preserve() uses: a specified stage side wins;
        // the fallback side only fills unspecified stages.
        let savedSide = firstWork.side == .unspecified ? fallbackSide : firstWork.side
        XCTAssertEqual(savedSide, .left)
        XCTAssertNotEqual(savedSide, .both)
    }

    // AC5: invalid Left/Right can never survive a bilateral-only exercise.
    func testBilateralOnlyPolicyNormalizesAndRecordsInvalidLeftAsBoth() {
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.bilateralOnly, .left), .both)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.bilateralOnly, .right), .both)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, .left), .both)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, .right), .both)
    }

    // AC5 run-construction assertion: a bilateralOnly-launched session carries
    // `.both` semantics via fallbackSide and never `.left`. The launch snapshot
    // (`launchSide = normalizeSide(sideMode, side)`) yields `.both`, so the
    // session's fallbackSide is `.both` (threaded through as the run's
    // `selectedSide`), and non-alternating work stages stay `.unspecified` —
    // save attribution therefore resolves to `.both`.
    func testBilateralOnlyLaunchCarriesBothSemanticsViaFallbackSideNeverLeft() {
        let launchSide = ExerciseSidePolicy.normalizeSide(.bilateralOnly, .left)
        XCTAssertEqual(launchSide, .both)

        let run = ForceProtocolRun(
            preset: Self.bilateralOnlyPreset(),
            startingSide: .left, // startSide derivation: launchSide == .right ? .right : .left
            selectedSide: launchSide
        )
        let firstWork = try? XCTUnwrap(run.stages.first(where: { $0.kind == .work }))
        guard let firstWork else { return }
        XCTAssertNotEqual(firstWork.side, .left)
        XCTAssertNotEqual(firstWork.side, .both)

        let savedSide = firstWork.side == .unspecified ? launchSide : firstWork.side
        XCTAssertEqual(savedSide, .both)
        XCTAssertNotEqual(savedSide, .left)
    }

    // AC1 wiring regression (fix round 4): the REAL `ForceView.launch()` state
    // snapshot → helper handoff must stay uncoerced. The app-target behavior
    // tests drive `makeGuidedLaunchSession(side: .left)` directly; this
    // source/wiring assertion closes the remaining caller-side hole (the
    // view-state snapshot at the launch call site) with the accepted repo
    // closure: assert the snapshot lines read the LIVE properties, the
    // delegate passes the SNAPSHOT values through, and no `.both` literal
    // exists anywhere in the launch region. Mutating either the snapshot
    // (`let launchSide = side` → `= .both`) or the delegate argument
    // (`side: launchSide` → `side: .both`) turns this test red.
    func testGuidedLaunchSnapshotAndDelegateHandoffStayUncoerced() {
        let forceView = code(source("Sources/Features/Force/ForceView.swift"))
        let launchBody = exactFunction(
            forceView,
            startingWith: "private func launch(_ preset: TindeqPreset)"
        )

        // The snapshot reads the LIVE view state at the launch call site.
        XCTAssertTrue(launchBody.contains("let launchSideMode = sideMode"))
        XCTAssertTrue(launchBody.contains("let launchSide = side"))
        XCTAssertTrue(launchBody.contains("let launchSelection = selectedSelection"))

        // The delegate passes the SNAPSHOT values through, never a literal.
        // #899: no hands-free preference crosses the guided-launch boundary —
        // every guided session is load-triggered hands-free by construction.
        XCTAssertTrue(launchBody.contains("sideMode: launchSideMode"))
        XCTAssertTrue(launchBody.contains("side: launchSide"))
        XCTAssertTrue(launchBody.contains("selection: launchSelection"))
        XCTAssertFalse(launchBody.contains("launchHandsFreeEnabled"))

        // No `.both` coercion anywhere in the launch region.
        XCTAssertFalse(
            launchBody.contains(".both"),
            "launch() must never stamp a .both literal into the snapshot/delegate handoff"
        )
    }

    func testPresetEditorDocumentsAlternationAsBothModeDeclaration() {
        let forceView = code(source("Sources/Features/Force/ForceView.swift"))
        XCTAssertTrue(forceView.contains("Toggle(\"Alternate sides\", isOn: $draft.alternateSides)"))
        // #901: the toggle is a Both-mode declaration — the UI must say a
        // Left/Right selection overrides it. Mutation: remove/reword the
        // caption line → this test goes red.
        XCTAssertTrue(
            forceView.contains(
                "Alternation applies when you record Both sides; a Left or Right selection runs that side only."
            ),
            "preset editor must document that single-side selections override the Alternate sides toggle"
        )
    }

    private static func alternatingPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Alternating Test",
            holdSeconds: 10,
            repetitions: 2,
            sets: 2,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 120,
            alternateSides: true,
            prepareSeconds: 5
        )
    }

    private static func bilateralOnlyPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Bilateral Test",
            holdSeconds: 10,
            repetitions: 2,
            sets: 2,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 120,
            alternateSides: false,
            prepareSeconds: 5
        )
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
