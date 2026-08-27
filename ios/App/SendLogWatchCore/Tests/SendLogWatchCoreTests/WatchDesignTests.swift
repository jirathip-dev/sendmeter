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

    /// SL-538 round-2 review finding 2: `readableForeground` only pins
    /// contrast against the four flat surfaces, but `WatchCard` paints an
    /// accent-tinted card as a gradient starting at `accent` over the base —
    /// not the flat base itself. A label using the default `foreground(_:)`
    /// surface can therefore pass this pinned invariant on paper while
    /// rendering below the floor on the actual accent-tinted corner it sits
    /// on. `accentCardSurface` models that corner; every semantic accent must
    /// stay readable there too via `foregroundOnAccentCard`'s resolver.
    func testReadableForegroundMeetsAAOnAccentTintedCardCorner() {
        for accent in WatchDesignTokens.semanticAccents {
            let corner = WatchDesignTokens.accentCardSurface(accent)
            let foreground = WatchDesignTokens.readableForeground(accent, on: corner)
            XCTAssertGreaterThanOrEqual(
                foreground.contrastRatio(to: corner),
                WatchDesignTokens.minimumForegroundContrast,
                "semantic accent \(accent) must remain readable on its own accent-tinted WatchCard corner"
            )
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

    // MARK: #791 W1 — one canonical semantic hue shared by phone, watch, widget.

    func testCanonicalHuesMatchPhoneSemanticPalette() {
        // The phone canonical values (SendmeterStyle / ChartToken light mode).
        XCTAssertEqual(SendmeterSemanticHue.primary.hex, "#5B5FC7")
        XCTAssertEqual(SendmeterSemanticHue.optimal.hex, "#2E96F0")
        XCTAssertEqual(SendmeterSemanticHue.caution.hex, "#DDB13A")
        XCTAssertEqual(SendmeterSemanticHue.danger.hex, "#E5743A")
        XCTAssertEqual(SendmeterSemanticHue.execution.hex, "#7B83EB")
    }

    func testWatchTokensAreDerivedFromCanonicalHues() {
        XCTAssertEqual(
            WatchDesignTokens.primary,
            PhaseRGB(hex: SendmeterSemanticHue.primary.hex)
        )
        XCTAssertEqual(
            WatchDesignTokens.secondary,
            PhaseRGB(hex: SendmeterSemanticHue.optimal.hex)
        )
        XCTAssertEqual(
            WatchDesignTokens.warning,
            PhaseRGB(hex: SendmeterSemanticHue.caution.hex)
        )
        XCTAssertEqual(
            WatchDesignTokens.danger,
            PhaseRGB(hex: SendmeterSemanticHue.danger.hex)
        )
    }

    func testWatchDangerHueStaysOrangeLikeThePhone() {
        // The #791 defect: watch danger was red-pink (#FF6175) while the
        // phone shows orange (#E5743A) for the same high/recover semantic.
        let danger = WatchDesignTokens.danger
        XCTAssertGreaterThan(danger.red, danger.green, "danger must stay red-dominant")
        XCTAssertGreaterThan(danger.green, danger.blue, "orange, not pink: green must beat blue")
    }

    // MARK: #791 W4 — one glyph mapping per concept across watch, phone, widget.

    func testCanonicalIconSymbolsMapConceptsIdentically() {
        XCTAssertEqual(SendmeterIconSymbol.force.rawValue, "scalemass")
        XCTAssertEqual(SendmeterIconSymbol.workout.rawValue, "figure.climbing")
        XCTAssertEqual(SendmeterIconSymbol.status.rawValue, "chart.bar.fill")
    }
}
