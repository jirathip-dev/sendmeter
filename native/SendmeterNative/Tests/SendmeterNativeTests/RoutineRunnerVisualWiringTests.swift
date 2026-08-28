import Foundation
import SendmeterCore
import XCTest
@testable import Sendmeter

/// Source-level seams for the two reviewable visual contracts that cannot be
/// proven by SendmeterCore's platform-neutral tests: the SwiftUI ring's local
/// geometry and the material appearance used by the phase foregrounds. The
/// contrast assertions also exercise the pure compositing contract so a
/// readable-looking implementation string cannot stand in for AA evidence.
final class RoutineRunnerVisualWiringTests: XCTestCase {
    func testRemainingRingRotatesItsLocalGradientSeamToTwelveOClock() {
        let source = workoutSource
        let ring = section(
            source,
            startingAt: ".trim(from: 0, to: remainingFraction)",
            endingAt: "VStack(spacing: 5)"
        )

        XCTAssertTrue(ring.contains("startAngle: .degrees(0)"))
        XCTAssertTrue(ring.contains("endAngle: .degrees(360 * remainingFraction)"))
        XCTAssertTrue(ring.contains("lineCap: .round"))
        XCTAssertTrue(
            ring.contains(".rotationEffect(.degrees(-90))"),
            "the trim's 3 o'clock local start and its gradient seam must rotate together to 12 o'clock"
        )
        XCTAssertFalse(ring.contains("startAngle: .degrees(-90)"))
        XCTAssertFalse(ring.contains("endAngle: .degrees(-90 + 360 * remainingFraction)"))
    }

    func testGlassUsesForegroundCompatibleMaterialAppearanceWithoutChangingIdentityHues() {
        let runner = section(
            workoutSource,
            startingAt: "private func runnerScreen(",
            endingAt: "private func topContext("
        )

        XCTAssertTrue(
            runner.contains(".environment(\\.colorScheme, snapshot.visualState == .rest ? .light : .dark)"),
            "light appearance needs a light material behind REST's dark text and dark material behind the other white-text states"
        )

        let visualState = section(
            workoutSource,
            startingAt: "private extension RoutineRunnerVisualState",
            endingAt: "private struct RoutineRunnerGlassButtonStyle"
        )
        XCTAssertTrue(
            visualState.contains("RoutineRunnerContrastPalette.glassShadeOpacity(for: self)"),
            "DONE's glass panels need a restrained shade so secondary white copy clears body-text contrast"
        )

        let buttonStyle = section(
            workoutSource,
            startingAt: "private struct RoutineRunnerGlassButtonStyle",
            endingAt: "extension RoutineRunnerGlassButtonStyle"
        )
        XCTAssertTrue(buttonStyle.contains(".overlay { Capsule().fill(state.materialShade) }"))
        XCTAssertTrue(buttonStyle.contains(".foregroundStyle(state.foregroundColor)"))

        XCTAssertTrue(workoutSource.contains("RoutineRunnerContrastPalette.bodyTextOpacity"))
        let topContext = section(
            workoutSource,
            startingAt: "private func topContext(",
            endingAt: "private func phaseHeader("
        )
        let phaseHeader = section(
            workoutSource,
            startingAt: "private func phaseHeader(",
            endingAt: "private func countdownDisc("
        )
        XCTAssertTrue(phaseHeader.contains("completionForegroundColor"))
        XCTAssertTrue(
            topContext.contains("Image(systemName: \"xmark\")")
                && topContext.contains("foregroundStyle(SendmeterStyle.alert)"),
            "Close keeps its alert meaning in the glyph while its label uses the phase foreground"
        )

        // #791 W1: the canonical identity hues moved to `SendmeterSemanticHue`
        // (WatchDesign.swift, shared by phone/watch/widget) and the design
        // system now derives from that seam. Pin each hue against its real
        // home: four live in the canonical source, #565D6D (paused) is
        // deliberately kept as the design system's own literal.
        let designSystem = source("Sources/App/DesignSystem.swift")
        let canonicalHues = source("../../ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift")
        for identityHue in ["#5B5FC7", "#2E96F0", "#DDB13A", "#7B83EB"] {
            XCTAssertTrue(
                canonicalHues.contains(identityHue),
                "approved identity hue \(identityHue) must remain in the canonical semantic hue source"
            )
        }
        XCTAssertTrue(
            designSystem.contains("#565D6D"),
            "approved identity hue #565D6D must remain in the design system"
        )
        for semanticCase in ["primary", "optimal", "caution", "execution"] {
            XCTAssertTrue(
                designSystem.contains("SendmeterSemanticHue.\(semanticCase).hex"),
                "design system must derive its \(semanticCase) identity hue from SendmeterSemanticHue"
            )
        }

        for state in [RoutineRunnerVisualState.working, .rest, .paused, .done] {
            let glass = RoutineRunnerContrastPalette.treatedGlassSurface(for: state)
            let foreground = RoutineRunnerContrastPalette.foreground(for: state)
            XCTAssertGreaterThanOrEqual(
                RoutineRunnerContrastPalette.bodyText(on: glass, state: state)
                    .contrastRatio(to: glass),
                RoutineRunnerContrastPalette.minimumBodyContrast,
                "\(state) computed glass body contrast"
            )
            XCTAssertGreaterThanOrEqual(
                foreground.contrastRatio(to: RoutineRunnerContrastPalette.field(for: state)),
                RoutineRunnerContrastPalette.minimumLargeTextContrast,
                "\(state) computed countdown contrast"
            )
        }

        XCTAssertGreaterThanOrEqual(
            RoutineRunnerContrastPalette.doneCompletionForeground
                .contrastRatio(to: RoutineRunnerContrastPalette.field(for: .done)),
            RoutineRunnerContrastPalette.minimumBodyContrast
        )
    }

    private var workoutSource: String {
        source("Sources/Features/Workout/WorkoutView.swift")
    }

    private func section(_ source: String, startingAt start: String, endingAt end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
        else {
            XCTFail("Could not locate source section \(start) … \(end)")
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func source(_ relativePath: String) -> String {
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
