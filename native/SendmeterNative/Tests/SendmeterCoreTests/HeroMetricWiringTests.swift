import Foundation
import XCTest

/// The SwiftUI app target is intentionally outside the host SwiftPM module.
/// These source invariants keep the shared hero treatment wired to each
/// primary-number owner until the hosted Xcode compile gate runs.
final class HeroMetricWiringTests: XCTestCase {
    func testHeroMetricIsDynamicTypeRelativeAndRounded() {
        let design = code(source("Sources/App/DesignSystem.swift"))
        let modifier = exactBlock(
            design,
            startingWith: "public struct HeroMetricModifier: ViewModifier"
        )
        let normalized = normalizeWhitespace(modifier)

        XCTAssertTrue(design.contains("public static var heroMetric: HeroMetricModifier"))
        XCTAssertTrue(normalized.contains(".font(.system(.largeTitle, design: .rounded).weight(.bold))"))
        XCTAssertTrue(normalized.contains(".monospacedDigit()"))
        XCTAssertTrue(normalized.contains(".allowsTightening(true)"))
        XCTAssertTrue(normalized.contains(".lineLimit(1)"))
        XCTAssertTrue(normalized.contains(".minimumScaleFactor(0.65)"))
        XCTAssertFalse(normalized.contains("lineSpacing"), "single-line hero metrics must not claim inert leading control")
        XCTAssertFalse(normalized.contains("tightLeading"), "hero style must not retain a dead leading invariant")
        XCTAssertFalse(normalized.contains(".system(size:"), "hero style must not freeze an absolute point size")
        XCTAssertFalse(normalized.contains(".frame("), "hero style must not add a clipping frame")
    }

    func testCountdownFamilyUsesASharedDynamicTypeAwareTier() {
        let design = code(source("Sources/App/DesignSystem.swift"))
        let countdown = exactBlock(
            design,
            startingWith: "public struct CountdownMetricModifier: ViewModifier"
        )
        let manual = code(source("Sources/Features/Workout/ManualWorkoutFullscreen.swift"))
        let workout = code(source("Sources/Features/Workout/WorkoutView.swift"))
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let normalized = normalizeWhitespace(countdown)

        XCTAssertTrue(design.contains("public static func countdownMetric(baseSize: CGFloat)"))
        XCTAssertTrue(normalized.contains("@ScaledMetric(relativeTo: .largeTitle)"))
        XCTAssertTrue(normalized.contains(".font(.system(size: displaySize, weight: .bold, design: .rounded))"))
        XCTAssertTrue(normalized.contains(".monospacedDigit()"))
        XCTAssertTrue(normalized.contains(".allowsTightening(true)"))
        XCTAssertTrue(normalized.contains(".minimumScaleFactor(0.55)"))
        XCTAssertTrue(normalized.contains(".lineLimit(1)"))

        XCTAssertTrue(manual.contains("SendmeterStyle.countdownMetric(baseSize: 82)"))
        XCTAssertTrue(workout.contains("SendmeterStyle.countdownMetric(baseSize: 52)"))
        XCTAssertTrue(workout.contains("SendmeterStyle.countdownMetric(baseSize: 80)"))
        XCTAssertTrue(force.contains("SendmeterStyle.countdownMetric(baseSize: 68)"))
        XCTAssertFalse(workout.contains(".font(.system(size: 52, weight: .bold, design: .rounded))"))
        XCTAssertFalse(workout.contains(".font(.system(size: 80, weight: .bold, design: .rounded))"))
        XCTAssertFalse(force.contains(".font(.system(size: 68, weight: .bold, design: .rounded))"))
    }

    func testMetricValueUsesTheSharedHeroTreatment() {
        let design = code(source("Sources/App/DesignSystem.swift"))
        let metric = exactBlock(design, startingWith: "public struct MetricValue: View")

        XCTAssertTrue(metric.contains("Text(value)"))
        XCTAssertTrue(metric.contains(".modifier(SendmeterStyle.heroMetric)"))
        XCTAssertFalse(metric.contains(".system(size: 42"))
    }

    func testReadinessTrendScoreOwnerUsesTheSharedHeroTreatment() {
        let dashboard = code(source("Sources/Features/Dashboard/DashboardView.swift"))
        let trend = code(source("Sources/Features/Dashboard/ReadinessTrendCard.swift"))
        let decision = exactBlock(dashboard, startingWith: "private struct TodayDecisionCard: View")

        // ReadinessTrendCard is chart-only; Today's decision owns the score
        // ring shown immediately above that trend and is its primary-number
        // owner.
        XCTAssertTrue(trend.contains("struct ReadinessTrendCard: View"))
        XCTAssertTrue(dashboard.contains("ReadinessTrendCard()"))
        XCTAssertTrue(decision.contains("if let score = model.readiness?.readiness"))
        XCTAssertTrue(decision.contains("Text(\"\\(score)\")"))
        XCTAssertTrue(decision.contains(".modifier(SendmeterStyle.heroMetric)"))
        XCTAssertTrue(decision.contains("@ScaledMetric(relativeTo: .largeTitle) private var readinessRingDiameter: CGFloat = 92"))
        XCTAssertTrue(decision.contains("@ScaledMetric(relativeTo: .largeTitle) private var readinessRingStroke: CGFloat = 10"))
        XCTAssertTrue(decision.contains("StrokeStyle(lineWidth: readinessRingStroke"))
        XCTAssertTrue(decision.contains(".frame(width: readinessRingDiameter, height: readinessRingDiameter)"))
        XCTAssertFalse(decision.contains(".system(size: 32"))
    }

    func testSendConditionsScoreUsesTheSharedHeroTreatment() {
        let dashboard = code(source("Sources/Features/Dashboard/DashboardView.swift"))
        let conditions = exactFunction(
            dashboard,
            startingWith: "private func populatedContent(_ conditions: SendConditions)"
        )

        XCTAssertTrue(conditions.contains("Text(\"\\(conditions.score)\")"))
        XCTAssertTrue(conditions.contains(".modifier(SendmeterStyle.heroMetric)"))
        XCTAssertFalse(conditions.contains(".system(size: 30"))
    }

    func testAcwrProjectionRatioOwnerUsesTheSharedHeroTreatment() {
        let dashboard = code(source("Sources/Features/Dashboard/DashboardView.swift"))
        let projection = code(source("Sources/Features/Dashboard/AcwrProjectionCard.swift"))
        let status = code(source("Sources/Features/Dashboard/AcwrStatusCard.swift"))
        let content = exactBlock(status, startingWith: "private var content: some View")

        // AcwrProjectionCard deliberately plots the future curve without
        // duplicating today's ratio. AcwrStatusCard is the canonical current
        // ratio owner above it.
        XCTAssertTrue(projection.contains("struct AcwrProjectionCard: View"))
        XCTAssertTrue(dashboard.contains("AcwrProjectionCard()"))
        XCTAssertTrue(content.contains("ratio.map { String(format: \"%.2f\", $0) }"))
        XCTAssertTrue(content.contains(".modifier(SendmeterStyle.heroMetric)"))
        XCTAssertFalse(content.contains(".system(size:"))
    }

    func testForceDeviceKeepsCurrentHeroAndLabelsPeak() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let deviceCard = exactBlock(force, startingWith: "private struct ForceDeviceCard: View")
        let normalized = normalizeWhitespace(deviceCard)

        XCTAssertTrue(normalized.contains("device.peakKilograms.formatted"))
        XCTAssertTrue(normalized.contains("Text(\"Peak "))
        XCTAssertTrue(normalized.contains("accessibilityLabel( \"Peak"))
        XCTAssertEqual(
            countOccurrences("MetricValue( device.currentKilograms", in: normalized),
            1,
            "ForceDeviceCard must keep exactly one current-force hero; a reintroduced duplicate must fail"
        )
        XCTAssertFalse(normalized.contains("MetricValue( device.peakKilograms"))
    }

    func testManualWorkoutRestCountdownUsesTheSharedHeroTreatment() {
        let workout = code(source("Sources/Features/Workout/ManualWorkoutFullscreen.swift"))
        let phasePanel = exactFunction(workout, startingWith: "private func phasePanel(snapshot: ManualWorkoutSnapshot)")

        XCTAssertTrue(phasePanel.contains("Text(formatDuration(snapshot.phaseSeconds))"))
        XCTAssertTrue(phasePanel.contains(".modifier(SendmeterStyle.countdownMetric(baseSize: 82)"))
        XCTAssertFalse(phasePanel.contains(".system(size: 82"))
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

    private func exactBlock(
        _ source: String,
        startingWith marker: String,
        missingMessage: String = "type"
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

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
