import XCTest
@testable import SendmeterCore

/// The SwiftUI App target is intentionally not part of the host SwiftPM
/// package. These source invariants keep the user-visible motion policy wired
/// to the tested Core values until the hosted Xcode compile gate runs.
final class ForceMotionWiringTests: XCTestCase {
    func testForcePhaseSurfacesUseTheSharedSpringAndReduceMotionGate() {
        let guided = code(source("Sources/Features/Force/ForceView.swift"))
        let deviceCard = exactType(guided, startingWith: "private struct ForceDeviceCard: View")

        for surface in [guided, deviceCard] {
            let normalizedSurface = normalizeWhitespace(surface)
            XCTAssertTrue(normalizedSurface.contains("ForceMotionPolicy.phaseResponseSeconds"))
            XCTAssertTrue(normalizedSurface.contains("ForceMotionPolicy.phaseDampingFraction"))
            XCTAssertTrue(normalizedSurface.contains("reduceMotion ? nil : .spring("))
        }
        XCTAssertTrue(guided.contains("value: presentation.phase"))
        XCTAssertTrue(deviceCard.contains("value: device.status"))
    }

    func testBoulderHeroUsesTheSharedPulseAndLightCue() {
        let workout = code(source("Sources/Features/Workout/ManualWorkoutFullscreen.swift"))
        let action = region(
            workout,
            from: "private func actionButton(",
            to: "private func toggleAttempt()"
        )
        let toggle = exactFunction(workout, startingWith: "private func toggleAttempt()")
        let style = exactType(workout, startingWith: "private struct ForceHeroActionButtonStyle")

        XCTAssertTrue(action.contains("ForceHeroActionButtonStyle()"))
        XCTAssertTrue(toggle.contains("Haptics.shared.playGesture(.light)"))
        XCTAssertFalse(toggle.contains("Haptics.shared.playGesture(.medium)"))
        let normalizedStyle = normalizeWhitespace(style)
        XCTAssertTrue(normalizedStyle.contains("ForceMotionPolicy.heroScale"))
        XCTAssertTrue(normalizedStyle.contains("ForceMotionPolicy.heroActionResponseSeconds"))
        XCTAssertTrue(normalizedStyle.contains("ForceMotionPolicy.heroActionDampingFraction"))
        XCTAssertTrue(normalizedStyle.contains("reduceMotion ? nil : .spring("))
        XCTAssertTrue(style.contains("StructuralHaptics.cue(level: structuralHapticLevel)"))
        XCTAssertFalse(style.contains(".hapticTap(structuralHapticLevel)"))
        XCTAssertTrue(workout.contains("extension ForceHeroActionButtonStyle: StructuralHapticStyle"))
        XCTAssertTrue(workout.contains("var structuralHapticLevel: HapticTapLevel { .normal }"))
    }

    func testForceDeviceCardRoutesRefusalsThroughForceView() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let deviceCard = exactType(force, startingWith: "private struct ForceDeviceCard: View")

        XCTAssertTrue(deviceCard.contains("let refuseAction: (String) -> Void"))
        XCTAssertTrue(deviceCard.contains("refuseAction(UserFacingError.message(for: error))"))
        XCTAssertTrue(force.contains("refuseAction: { message in refuseAction(message) }"))
    }

    func testGuidedRunnerRendersProtocolAndHonestTargetContext() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let contextCardFile = code(source("Sources/Features/Force/ForceRecordingContextCard.swift"))
        let forceView = exactType(force, startingWith: "struct ForceView: View")
        let forceBody = exactFunction(forceView, startingWith: "var body: some View {")
        let contextCardCall = exactBlock(force, startingWith: "private var recordingContextCard: some View", missingMessage: "property")
        let guidedView = exactType(force, startingWith: "private struct GuidedForceProtocolView: View")
        let guidedSections = exactFunction(guidedView, startingWith: "private func protocolSections(")
        let guidedTargetCoach = exactBlock(force, startingWith: "private var targetCoach: some View", missingMessage: "property")
        let guidedSummary = exactFunction(guidedView, startingWith: "private func protocolSummary(")

        XCTAssertTrue(guidedSections.contains("protocolIdentityHeader"))
        XCTAssertTrue(guidedSections.contains("targetCoach"))
        XCTAssertTrue(guidedTargetCoach.contains("No target configured for this protocol"))
        XCTAssertTrue(guidedTargetCoach.contains("else"))
        // #903: the outside recording-context card is a direct stack member
        // (never a collapsed "Protocol details" disclosure) and carries the
        // armed hero's bound target + intensity load module.
        XCTAssertTrue(contextCardCall.contains("ForceRecordingContextCard("))
        XCTAssertTrue(forceBody.contains("recordingContextCard"))
        XCTAssertTrue(normalizeWhitespace(contextCardCall).contains("targetBand: selectedTargetReferenceBand"))
        XCTAssertTrue(normalizeWhitespace(contextCardCall).contains("zoneTarget: armedZoneTarget"))
        XCTAssertFalse(forceBody.contains("DisclosureGroup(\"Protocol details\""))
        XCTAssertTrue(forceBody.contains(".safeAreaInset(edge: .bottom"))
        // The redesigned outside card keeps its own explicit no-target state
        // and renders the module's live readout + intensity dial copy.
        XCTAssertTrue(contextCardFile.contains("No target configured for this protocol"))
        XCTAssertTrue(contextCardFile.contains("Live readout"))
        XCTAssertTrue(contextCardFile.contains("60–110 · 5% steps"))
        XCTAssertTrue(contextCardFile.contains("Intensity"))

        let branches = protocolSummaryBranches(guidedSummary)
        XCTAssertTrue(branches.staticBranch.contains("preset.holdScheduleSummary"))
        XCTAssertTrue(branches.staticBranch.contains("preset.restBetweenRepetitionsSeconds"))
        XCTAssertTrue(branches.staticBranch.contains("preset.restBetweenSetsSeconds"))
        XCTAssertTrue(branches.movementBranch.contains("preset.cadenceOutSeconds"))
        XCTAssertTrue(branches.movementBranch.contains("preset.cadenceReturnSeconds"))
        XCTAssertTrue(branches.movementBranch.contains("preset.restBetweenSetsSeconds"))
        XCTAssertFalse(branches.movementBranch.contains("preset.restBetweenRepetitionsSeconds"))

        let varied = TindeqPreset(
            name: "Varied holds",
            holdSeconds: 10,
            holdSecondsBySet: [7, 10, 12],
            repetitions: 1,
            sets: 3,
            restBetweenRepetitionsSeconds: 0,
            restBetweenSetsSeconds: 0
        )
        XCTAssertEqual(varied.holdScheduleSummary, "7/10/12s holds")
    }

    func testGuidedRunnerRendersNoStopFinishCircleAndKeepsTheEndPill() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let guidedView = exactType(force, startingWith: "private struct GuidedForceProtocolView: View")
        let guidedSections = exactFunction(guidedView, startingWith: "private func protocolSections(")
        let topBar = exactFunction(guidedView, startingWith: "private func topBar(")

        // #899 AC1: the STOP/FINISH action circle is gone from the guided
        // runner — no bottom action inset, no circle control, no
        // STOP/FINISH labels anywhere in the view.
        XCTAssertFalse(guidedView.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertFalse(guidedView.contains("primaryControl"))
        XCTAssertFalse(guidedView.contains("primaryAction"))
        XCTAssertFalse(guidedView.contains("\"FINISH\""))
        XCTAssertFalse(guidedView.contains("\"STOP\""))
        XCTAssertFalse(guidedView.contains("actionDiameter"))
        // The single explicit save+exit stays: the top-bar End pill routes
        // through the same save-in-flight stopOrFinish chain as before.
        XCTAssertTrue(topBar.contains("Button(\"End\", action: endSession)"))
        XCTAssertTrue(guidedView.contains("private func endSession()"))
        XCTAssertTrue(guidedView.contains("await session.stopOrFinish()"))
        // #993: the pause/skip row is still the same `controls(date:)` helper,
        // but it is now rendered by the CONTAINER under the scroll view (so it
        // stays on screen at every chart height) instead of as the stack's
        // last scrolling section.
        XCTAssertTrue(guidedView.contains("controls(date: date)"))
        XCTAssertFalse(guidedSections.contains("controls(date: date)"))
    }

    /// #940: completion is an explicit prompt with its own inline action, and
    /// that action runs the SAME save/close path as the top-bar End
    /// (`endSession`) — never a second finish mechanism, and never a bottom
    /// inset the user has to scroll to. The cue is the success notification,
    /// claimed once per run.
    func testGuidedCompletionPanelCarriesTheInlineDoneAction() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let guidedView = exactType(force, startingWith: "private struct GuidedForceProtocolView: View")
        let completionPanel = exactFunction(guidedView, startingWith: "private func completionPanel(")
        let session = exactType(force, startingWith: "final class GuidedForceProtocolSession")
        let completionHaptic = exactFunction(session, startingWith: "private func fireCompletionHapticIfNeeded()")

        XCTAssertTrue(guidedView.contains("presentation.phase == .complete"))
        XCTAssertTrue(completionPanel.contains("Text(presentation.detail)"))
        XCTAssertTrue(completionPanel.contains("Button(\"Done\", action: endSession)"))
        XCTAssertFalse(completionPanel.contains("formatCountdown"))
        XCTAssertFalse(guidedView.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertTrue(completionHaptic.contains("guard !hasFiredCompletionHaptic else { return }"))
        XCTAssertTrue(completionHaptic.contains("Haptics.shared.play(.success)"))
    }

    // #899 AC2/decision 2: every guided rep starts from the pull — the
    // runner must never auto-start a work stage without load.
    func testGuidedRunnerWorkStagesAreAlwaysLoadTriggeredHandsFree() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let session = exactType(force, startingWith: "final class GuidedForceProtocolSession")
        let startWorkMeasurement = exactFunction(session, startingWith: "private func startWorkMeasurement()")

        XCTAssertTrue(startWorkMeasurement.contains("model.handsFree.arm()"))
        XCTAssertFalse(startWorkMeasurement.contains("startMeasuring"))
        XCTAssertTrue(session.contains("model.handsFree.stopPolicy = .callerOwned"))
        // No per-session hands-free preference remains (the timing policy is
        // called with the constant `handsFreeEnabled: true` only).
        XCTAssertFalse(session.contains("if handsFreeEnabled"))
        XCTAssertFalse(session.contains("self.handsFreeEnabled"))
        XCTAssertFalse(session.contains("let handsFreeEnabled: Bool"))
    }

    // #899 AC4: no orphaned manual-mode symbols or entry points remain in
    // the Force tab owner.
    func testManualForceModeIsFullyRemovedFromTheForceTab() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        XCTAssertFalse(force.contains("startMeasurement"))
        XCTAssertFalse(force.contains("ManualForceFullscreen"))
        XCTAssertFalse(force.contains("manualFullscreen"))
        XCTAssertFalse(force.contains("cancelManualArm"))
        XCTAssertFalse(force.contains("\"Record a pull\""))
        XCTAssertFalse(force.contains("Label(\"Start Pull\""))
        // Empty/connected surfaces route to guided + hands-free.
        XCTAssertTrue(force.contains("return \"Arm Hands-free\""))
        XCTAssertFalse(force.contains("\"Tap Start Pull when ready\""))
    }

    // MARK: - #903 r3: the redesigned recording-context configure card

    /// AC1: the outside (pre-start) recording context renders the protocol
    /// configure surface (recording-context card) directly — never behind a
    /// collapsed, low-emphasis DisclosureGroup — and the collapse state that
    /// shipped in build 50 is gone.
    func testOutsideContextRendersConfigureCardWithoutCollapsedDisclosure() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let forceView = exactType(force, startingWith: "struct ForceView: View")
        let forceBody = exactFunction(forceView, startingWith: "var body: some View {")

        XCTAssertTrue(forceBody.contains("recordingContextCard"))
        XCTAssertFalse(forceBody.contains("DisclosureGroup(\"Protocol details\""))
        XCTAssertFalse(forceView.contains("showProtocolDetails"))
    }

    /// AC1: the redesigned card leads with the "Movement & side" decision
    /// row, arms immediately, and the armed hero is the card's strongest
    /// state — protocol identity (dot + name), timing, and a Change control
    /// back to the protocol list.
    func testOutsideContextCardShowsArmedHeroIdentityAndChange() {
        let card = code(source("Sources/Features/Force/ForceRecordingContextCard.swift"))

        XCTAssertTrue(card.contains("\"Recording context\""))
        XCTAssertTrue(card.contains("\"Nothing armed\""))
        XCTAssertTrue(card.contains("\"Movement & side\""))
        XCTAssertTrue(card.contains("\"Armed protocol\""))
        XCTAssertTrue(card.contains("Text(preset.name)"))
        XCTAssertTrue(card.contains("\"Change\""))
        XCTAssertTrue(card.contains("\"Identity dot · tap to arm\""))
    }

    /// AC2: between the armed-target branch and the hands-free action label
    /// the load module keeps an explicit no-target branch — a missing target
    /// is never a silent gap in the outside context.
    func testOutsideContextCardKeepsExplicitNoTargetState() {
        let card = code(source("Sources/Features/Force/ForceRecordingContextCard.swift"))

        XCTAssertTrue(card.contains("\"No target configured for this protocol\""))
        XCTAssertTrue(card.contains("displayBand"))
    }

    /// AC3 (#899): the card keeps the hands-free next physical action
    /// prominent before starting, and the armed hero renders the load-
    /// triggered readiness copy unconditionally — the tap-to-start variant is
    /// gone with the manual free-pull mode.
    func testOutsideContextCardKeepsHandsFreeNextActionProminence() {
        let card = code(source("Sources/Features/Force/ForceRecordingContextCard.swift"))

        XCTAssertTrue(card.contains("\"Hands-free\""))
        XCTAssertTrue(card.contains("\"Pull to start · release to stop\""))
        XCTAssertFalse(card.contains("\"Tap Start Pull when ready\""))
        XCTAssertFalse(card.contains("handsFreeEnabled"))
        XCTAssertTrue(card.contains("\"Armed now · no confirmation step\""))
        XCTAssertTrue(card.contains("\"MOVEMENT\""))
    }

    private func protocolSummaryBranches(_ source: String) -> (staticBranch: String, movementBranch: String) {
        guard let movementStart = source.range(of: "if preset.protocolMode == .reverseAction {"),
              let staticStart = source.range(of: "return", options: .backwards)
        else {
            XCTFail("Missing protocol summary branches")
            return ("", "")
        }
        return (
            String(source[staticStart.lowerBound..<source.endIndex]),
            String(source[movementStart.lowerBound..<staticStart.lowerBound])
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
        exactBlock(source, startingWith: marker, missingMessage: "function")
    }

    private func exactType(_ source: String, startingWith marker: String) -> String {
        exactBlock(source, startingWith: marker, missingMessage: "type")
    }

    private func exactBlock(
        _ source: String,
        startingWith marker: String,
        missingMessage: String
    ) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant \(missingMessage): \(marker)")
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

        XCTFail("Unclosed source invariant \(missingMessage): \(marker)")
        return ""
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
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
