import XCTest
@testable import SendmeterCore

/// The SwiftUI App target is intentionally not part of the host SwiftPM
/// package. These source invariants keep the user-visible motion policy wired
/// to the tested Core values until the hosted Xcode compile gate runs.
final class ForceMotionWiringTests: XCTestCase {
    func testForcePhaseSurfacesUseTheSharedSpringAndReduceMotionGate() {
        let guided = code(source("Sources/Features/Force/ForceView.swift"))
        let manual = code(source("Sources/Features/Force/ManualForceFullscreen.swift"))
        let deviceCard = exactType(guided, startingWith: "private struct ForceDeviceCard: View")

        for surface in [guided, manual, deviceCard] {
            let normalizedSurface = normalizeWhitespace(surface)
            XCTAssertTrue(normalizedSurface.contains("ForceMotionPolicy.phaseResponseSeconds"))
            XCTAssertTrue(normalizedSurface.contains("ForceMotionPolicy.phaseDampingFraction"))
            XCTAssertTrue(normalizedSurface.contains("reduceMotion ? nil : .spring("))
        }
        XCTAssertTrue(guided.contains("value: presentation.phase"))
        XCTAssertTrue(manual.contains("value: phase"))
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
        XCTAssertTrue(style.contains("Haptics.shared.playGesture(structuralHapticLevel)"))
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

    func testForceFullscreensRenderProtocolAndHonestTargetContext() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let manual = code(source("Sources/Features/Force/ManualForceFullscreen.swift"))
        let forceView = exactType(force, startingWith: "struct ForceView: View")
        let forceBody = exactFunction(forceView, startingWith: "var body: some View {")
        let guidedView = exactType(force, startingWith: "private struct GuidedForceProtocolView: View")
        let guidedSections = exactFunction(guidedView, startingWith: "private func protocolSections(")
        let guidedTargetCoach = exactBlock(force, startingWith: "private var targetCoach: some View", missingMessage: "property")
        let outsideView = exactType(force, startingWith: "private struct ForceContextSummaryCard: View")
        let outsideSummary = exactFunction(outsideView, startingWith: "private func protocolSummary(")
        let guidedSummary = exactFunction(guidedView, startingWith: "private func protocolSummary(")
        let manualBody = exactFunction(manual, startingWith: "var body: some View {")
        let manualDetails = exactBlock(manual, startingWith: "private var protocolDetails: some View", missingMessage: "property")
        let manualSummary = exactFunction(manual, startingWith: "private func protocolSummary(")

        XCTAssertTrue(guidedSections.contains("protocolIdentityHeader"))
        XCTAssertTrue(guidedSections.contains("targetCoach"))
        XCTAssertTrue(guidedTargetCoach.contains("No target configured for this protocol"))
        XCTAssertTrue(guidedTargetCoach.contains("else"))
        XCTAssertTrue(forceBody.contains("ForceContextSummaryCard("))
        XCTAssertTrue(forceBody.contains("DisclosureGroup(\"Protocol details\""))
        XCTAssertTrue(forceBody.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertTrue(manualBody.contains("protocolDetails"))
        XCTAssertTrue(manualBody.contains("targetCoach"))
        XCTAssertTrue(manualDetails.contains("No target configured for this protocol"))
        XCTAssertTrue(manualDetails.contains("else"))

        for summary in [guidedSummary, outsideSummary, manualSummary] {
            let branches = protocolSummaryBranches(summary)
            XCTAssertTrue(branches.staticBranch.contains("preset.holdScheduleSummary"))
            XCTAssertTrue(branches.staticBranch.contains("preset.restBetweenRepetitionsSeconds"))
            XCTAssertTrue(branches.staticBranch.contains("preset.restBetweenSetsSeconds"))
            XCTAssertTrue(branches.movementBranch.contains("preset.cadenceOutSeconds"))
            XCTAssertTrue(branches.movementBranch.contains("preset.cadenceReturnSeconds"))
            XCTAssertTrue(branches.movementBranch.contains("preset.restBetweenSetsSeconds"))
            XCTAssertFalse(branches.movementBranch.contains("preset.restBetweenRepetitionsSeconds"))
        }

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
