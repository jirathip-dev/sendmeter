@testable import SendLogWatchCore
import XCTest

/// #1028 B1: ONE palette — the Watch resolves the shared palette's dark half,
/// so phone-dark and Watch can never drift apart again (build 57: navy Watch
/// canvas vs grey phone material; mint "Synced" vs the phone's blue).
final class SendmeterPaletteTests: XCTestCase {
    func testWatchSurfacesAreThePhoneDarkRamp() {
        XCTAssertEqual(WatchDesignTokens.canvas, SendmeterPalette.canvas.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.canvasRaised, SendmeterPalette.surface.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.card, SendmeterPalette.surfaceRaised.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.cardStrong, SendmeterPalette.surfaceNested.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.textPrimary, SendmeterPalette.textPrimary.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.textSecondary, SendmeterPalette.textSecondary.rgb(isDark: true))
    }

    func testSuccessIsThePhonesOptimalBlueNotMint() {
        XCTAssertEqual(WatchDesignTokens.success, SendmeterPalette.success.rgb(isDark: true))
        let mint = PhaseRGB(0.30, 0.93, 0.68)
        XCTAssertNotEqual(WatchDesignTokens.success, mint)
        XCTAssertGreaterThan(WatchDesignTokens.success.blue, WatchDesignTokens.success.green)
    }

    func testCanvasIsNotNavyOrTrueBlack() {
        let canvas = WatchDesignTokens.canvas
        // The old Watch canvas leaned navy (blue ≫ red); the shared ramp is a
        // near-neutral slate, a hair cool.
        XCTAssertLessThan(canvas.blue - canvas.red, 0.05)
        XCTAssertGreaterThan(canvas.red + canvas.green + canvas.blue, 0)
    }

    func testPairsParse() {
        for pair in [SendmeterPalette.canvas, SendmeterPalette.surface, SendmeterPalette.surfaceRaised, SendmeterPalette.surfaceNested, SendmeterPalette.textPrimary, SendmeterPalette.textSecondary, SendmeterPalette.success] {
            for dark in [false, true] {
                let rgb = pair.rgb(isDark: dark)
                for channel in [rgb.red, rgb.green, rgb.blue] {
                    XCTAssertTrue((0...1).contains(channel))
                }
            }
        }
    }
}
