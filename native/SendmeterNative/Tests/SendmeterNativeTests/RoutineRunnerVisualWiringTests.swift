import Foundation
import XCTest
@testable import Sendmeter

/// Source-level seams for the two reviewable visual contracts that cannot be
/// proven by SendmeterCore's platform-neutral tests: the SwiftUI ring's local
/// geometry and the material appearance used by the phase foregrounds.
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
            visualState.contains("self == .done ? .black.opacity(0.12) : .clear"),
            "DONE's glass panels need a restrained shade so secondary white copy clears body-text contrast"
        )

        let designSystem = source("Sources/App/DesignSystem.swift")
        for identityHue in ["#5B5FC7", "#2E96F0", "#DDB13A", "#565D6D", "#7B83EB"] {
            XCTAssertTrue(
                designSystem.contains(identityHue),
                "approved identity hue \(identityHue) must remain in the design system"
            )
        }
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
