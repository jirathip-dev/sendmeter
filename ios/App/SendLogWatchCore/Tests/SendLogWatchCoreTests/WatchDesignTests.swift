import XCTest
@testable import SendLogWatchCore

final class WatchDesignTests: XCTestCase {
    func testPrimaryHitTargetMatchesWatchGuidance() {
        XCTAssertEqual(WatchDesignTokens.minimumHitTarget, 44)
        XCTAssertGreaterThanOrEqual(WatchDesignTokens.minimumHitTarget, 44)
    }

    func testSemanticStatesHaveStableAccessibleLanguage() {
        XCTAssertEqual(WatchVisualState.allCases.map(\.label), [
            "Ready", "Syncing", "Offline", "Cached", "Needs attention", "Saved", "Caution", "Error",
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

    func testAccentScaleUsesFullBrightnessOutsideReducedLuminance() {
        XCTAssertEqual(WatchDesignTokens.accentScale(reducedLuminance: false), 1)
        XCTAssertEqual(
            WatchDesignTokens.accentScale(reducedLuminance: true),
            WatchDesignTokens.alwaysOnAccentScale
        )

        let bright = WatchDesignTokens.accent(WatchDesignTokens.force, reducedLuminance: false)
        let dimmed = WatchDesignTokens.accent(WatchDesignTokens.force, reducedLuminance: true)
        XCTAssertEqual(bright, WatchDesignTokens.force)
        XCTAssertEqual(dimmed, WatchDesignTokens.alwaysOn(WatchDesignTokens.force))
    }

    func testRefreshFailureNeverClaimsSynced() {
        let success = WatchStatusRefreshOutcome(healthSucceeded: true, acwrSucceeded: true)
        let partial = WatchStatusRefreshOutcome(healthSucceeded: true, acwrSucceeded: false)
        let failure = WatchStatusRefreshOutcome(healthSucceeded: false, acwrSucceeded: false)

        XCTAssertEqual(WatchStatusRefreshState.after(success, hasCachedSnapshot: true), .synced)
        XCTAssertEqual(WatchStatusRefreshState.after(partial, hasCachedSnapshot: true), .cached)
        XCTAssertEqual(WatchStatusRefreshState.after(partial, hasCachedSnapshot: false), .offline)
        XCTAssertEqual(WatchStatusRefreshState.after(failure, hasCachedSnapshot: false), .offline)
        XCTAssertNotEqual(WatchStatusRefreshState.after(partial, hasCachedSnapshot: true), .synced)
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

    func testReadableForegroundMeetsAAForEverySemanticAccentAndSurface() {
        let surfaces = [
            WatchDesignTokens.canvas,
            WatchDesignTokens.canvasRaised,
            WatchDesignTokens.card,
            WatchDesignTokens.cardStrong,
        ]

        for accent in WatchDesignTokens.semanticAccents {
            for surface in surfaces {
                let foreground = WatchDesignTokens.readableForeground(accent, on: surface)
                XCTAssertGreaterThanOrEqual(
                    foreground.contrastRatio(to: surface),
                    WatchDesignTokens.minimumForegroundContrast,
                    "semantic accent \(accent) must remain readable on surface \(surface)"
                )
            }
        }
    }

    func testReducedAccentIsDecorativeOnlyAndCannotBeUsedAsForeground() {
        for accent in WatchDesignTokens.semanticAccents {
            let reduced = WatchDesignTokens.accent(accent, reducedLuminance: true)
            XCTAssertLessThan(
                reduced.contrastRatio(to: WatchDesignTokens.card),
                WatchDesignTokens.minimumForegroundContrast,
                "the 42% accent is intentionally not an accessible text/icon colour"
            )
        }

        let foreground = WatchDesignTokens.readableForeground(
            WatchDesignTokens.primary,
            on: WatchDesignTokens.card
        )
        XCTAssertGreaterThanOrEqual(
            foreground.contrastRatio(to: WatchDesignTokens.card),
            WatchDesignTokens.minimumForegroundContrast
        )
    }
}
