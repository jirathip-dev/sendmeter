import XCTest
@testable import SendLogWatchCore

final class WatchDesignTests: XCTestCase {
    func testPrimaryHitTargetMatchesWatchGuidance() {
        XCTAssertEqual(WatchDesignTokens.minimumHitTarget, 44)
        XCTAssertGreaterThanOrEqual(WatchDesignTokens.minimumHitTarget, 44)
    }

    func testSemanticStatesHaveStableAccessibleLanguage() {
        XCTAssertEqual(WatchVisualState.allCases.map(\.label), [
            "Ready", "Syncing", "Offline", "Needs attention", "Saved", "Caution", "Error",
        ])
        XCTAssertEqual(
            Set(WatchVisualState.allCases.map(\.symbolName)).count,
            WatchVisualState.allCases.count - 1,
            "Ready and Saved intentionally share the positive checkmark symbol"
        )
    }

    func testAlwaysOnScalePreservesHueAndReducesLuminance() {
        for color in WatchDesignTokens.semanticAccents {
            let dimmed = WatchDesignTokens.alwaysOn(color)
            XCTAssertLessThan(dimmed.relativeLuminance, color.relativeLuminance)
            XCTAssertEqual(dimmed.red / color.red, WatchDesignTokens.alwaysOnAccentScale, accuracy: 1e-9)
            XCTAssertEqual(dimmed.green / color.green, WatchDesignTokens.alwaysOnAccentScale, accuracy: 1e-9)
            XCTAssertEqual(dimmed.blue / color.blue, WatchDesignTokens.alwaysOnAccentScale, accuracy: 1e-9)
        }
    }

    func testBrightTextHasLegibleContrastOnEverySurface() {
        for surface in [WatchDesignTokens.canvas, WatchDesignTokens.canvasRaised, WatchDesignTokens.card, WatchDesignTokens.cardStrong] {
            XCTAssertGreaterThanOrEqual(
                PhaseRGB.white.contrastRatio(to: surface),
                7,
                "surface (surface) must keep body text at AAA contrast"
            )
        }
    }
}
