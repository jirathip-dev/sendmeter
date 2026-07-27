import XCTest
import SendLogWatchCore

/// Issue #243 (221b): the watch live-workout view colours itself by phase.
/// Colour cannot be judged headlessly, but the two things that make it fail
/// *can* be: resolving the wrong phase, and picking a colour the text can't be
/// read on. Both live here rather than in the view.
final class WorkoutPhaseResolutionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func phase(
        climbing: Bool = false,
        climbingSince: Date? = nil,
        restStartedAt: Date? = nil,
        restTargetS: Int = 180,
        after seconds: TimeInterval = 0
    ) -> WorkoutPhase {
        WorkoutPhasePalette.phase(
            manualClimbing: climbing,
            climbingSince: climbingSince,
            restStartedAt: restStartedAt,
            restTargetS: restTargetS,
            now: t0.addingTimeInterval(seconds)
        )
    }

    func testClimbingWinsOverAnOpenRest() {
        // The manager clears restStartedAt on toggle, but ordering must not
        // matter: a boulder in progress is a boulder in progress.
        XCTAssertEqual(
            phase(climbing: true, climbingSince: t0, restStartedAt: t0),
            .climbing
        )
    }

    func testClimbingFlagWithoutAStartTimeIsNotClimbing() {
        // The view can't draw a count-up without a start; the band must agree
        // with what the timer shows rather than go green over nothing.
        XCTAssertEqual(phase(climbing: true, climbingSince: nil, restStartedAt: t0), .resting)
    }

    func testRestingUntilTheTargetThenRestOver() {
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 180, after: 0), .resting)
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 180, after: 179.9), .resting)
        // Exactly at zero already counts as over — the countdown reads 0:00
        // and the haptic has fired, so the band must not still say rest.
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 180, after: 180), .restOver)
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 180, after: 600), .restOver)
    }

    func testRestTargetChangeCanFlipThePhaseBothWays() {
        // The 1/2/3/5m chips are tappable *during* the rest.
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 300, after: 200), .resting)
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 60, after: 200), .restOver)
    }

    func testNoPhaseWithoutEitherClock() {
        XCTAssertEqual(phase(), .idle)
    }
}

final class WorkoutPhaseFillTests: XCTestCase {
    /// The failure this feature invites: text in the phase's own colour on a
    /// block of the phase's own colour. Since #277 the block is a band behind
    /// the eyebrow and the countdown rather than the whole screen — the
    /// pairing to hold is label-on-*band*, at full brightness and dimmed.
    func testEveryBandCarriesItsLabelAtAAAContrast() {
        for phase in WorkoutPhase.allCases {
            for reduced in [false, true] {
                let fill = WorkoutPhasePalette.fill(for: phase, luminanceReduced: reduced)
                let ratio = fill.band.contrastRatio(to: fill.label)
                XCTAssertGreaterThanOrEqual(
                    ratio, WorkoutPhasePalette.minimumContrast,
                    "\(phase) (reduced: \(reduced)) contrast \(ratio)"
                )
            }
        }
    }

    /// The screen is black for every phase (#277) — the whole point of the
    /// band is that the colour stopped flooding the display. If a phase ever
    /// tints the screen again, the on-black assertions below stop meaning
    /// anything, so pin it here.
    func testScreenIsBlackForEveryPhase() {
        for phase in WorkoutPhase.allCases {
            for reduced in [false, true] {
                XCTAssertEqual(
                    WorkoutPhasePalette.fill(for: phase, luminanceReduced: reduced).screen,
                    .black, "\(phase) (reduced: \(reduced))"
                )
            }
        }
    }

    /// HR, elapsed, BOULDERS, kcal and altitude used to sit on the phase fill
    /// (behind a wash); they now sit on black either side of the band. watchOS
    /// draws them with `.secondary` — white at ~60% — which clears AAA on
    /// black, and unlike the old fill it does so identically in every phase.
    func testSecondaryReadoutsClearAAAOnTheBlackScreen() {
        for phase in WorkoutPhase.allCases {
            for reduced in [false, true] {
                let fill = WorkoutPhasePalette.fill(for: phase, luminanceReduced: reduced)
                let secondary = PhaseRGB.white.over(
                    fill.screen, opacity: WorkoutPhasePalette.secondaryOpacity
                )
                let ratio = fill.screen.contrastRatio(to: secondary)
                XCTAssertGreaterThanOrEqual(
                    ratio, WorkoutPhasePalette.minimumContrast,
                    "\(phase) (reduced: \(reduced)) secondary contrast \(ratio)"
                )
            }
        }
    }

    /// Primary readouts (the HR number, the boulder count) are full-strength
    /// white on the same black — the ceiling, but assert it so a future
    /// non-black screen can't slip past the secondary check's margin.
    func testPrimaryReadoutsClearAAAOnTheBlackScreen() {
        for phase in WorkoutPhase.allCases {
            let fill = WorkoutPhasePalette.fill(for: phase)
            XCTAssertGreaterThanOrEqual(
                fill.screen.contrastRatio(to: .white), WorkoutPhasePalette.minimumContrast, "\(phase)"
            )
        }
    }

    /// Dimming may only ever help legibility — white text on a darker band is
    /// a higher ratio, never a lower one.
    func testDimmingNeverReducesContrast() {
        for phase in WorkoutPhase.allCases {
            let full = WorkoutPhasePalette.fill(for: phase)
            let dim = WorkoutPhasePalette.fill(for: phase, luminanceReduced: true)
            XCTAssertLessThanOrEqual(dim.band.relativeLuminance, full.band.relativeLuminance)
            XCTAssertGreaterThanOrEqual(
                dim.band.contrastRatio(to: dim.label),
                full.band.contrastRatio(to: full.label)
            )
        }
    }

    /// The always-on band has to stay genuinely dark. A band is a much smaller
    /// lit area than the full-screen fill it replaced, but always-on is
    /// measured in hours — the scaling stays and so does this bound.
    func testDimmedBandsAreDark() {
        for phase in WorkoutPhase.allCases {
            let dim = WorkoutPhasePalette.fill(for: phase, luminanceReduced: true)
            XCTAssertLessThan(dim.band.relativeLuminance, 0.02, "\(phase)")
        }
    }

    /// The band has to read as a block of colour against the black around it,
    /// or it is just dark text-backing. 3:1 (WCAG 1.4.11, non-text) and a 7:1
    /// white label on that same band intersect at exactly one value: 3:1 over
    /// black needs luminance ≥ 0.10, 7:1 under white needs ≤ 0.10. So both are
    /// satisfiable, but only at L = 0.10 on the nose, with no margin either
    /// way for the OLED's own gamma — and the label, not the band, is what
    /// carries the meaning. So the label keeps AAA with room to spare and the
    /// band is held well clear of black instead.
    func testEveryLiveBandReadsAsABlockAgainstTheScreen() {
        for phase in [WorkoutPhase.climbing, .resting, .restOver] {
            for reduced in [false, true] {
                let fill = WorkoutPhasePalette.fill(for: phase, luminanceReduced: reduced)
                let ratio = fill.band.contrastRatio(to: fill.screen)
                XCTAssertGreaterThan(ratio, reduced ? 1.15 : 2, "\(phase) (reduced: \(reduced)) \(ratio)")
            }
        }
    }

    /// The whole point is glanceability: the three live phases must be
    /// distinguishable *as colours*, not just as labels — including dimmed,
    /// where a muddy palette collapses.
    func testLivePhasesAreVisiblyDistinct() {
        let live: [WorkoutPhase] = [.climbing, .resting, .restOver]
        for reduced in [false, true] {
            let bands = live.map { WorkoutPhasePalette.fill(for: $0, luminanceReduced: reduced).band }
            for (i, a) in bands.enumerated() {
                for b in bands[(i + 1)...] {
                    // Each pair differs by a clear margin on at least one channel.
                    let delta = max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
                    XCTAssertGreaterThan(delta, 0.08, "\(a) vs \(b) (reduced: \(reduced))")
                    // ...and each phase's dominant channel is its own.
                    XCTAssertNotEqual(dominantChannel(a), dominantChannel(b))
                }
            }
        }
    }

    /// Idle draws no band at all — the view keeps the stock black background
    /// until there is a phase to report.
    func testIdleDrawsNoBand() {
        let fill = WorkoutPhasePalette.fill(for: .idle)
        XCTAssertEqual(fill.band, .black)
        XCTAssertEqual(fill.band, fill.screen)
    }

    func testTransitionIsAnimatedButNotSluggish() {
        XCTAssertGreaterThan(WorkoutPhasePalette.transitionSeconds, 0.2)
        XCTAssertLessThan(WorkoutPhasePalette.transitionSeconds, 1.0)
    }

    private func dominantChannel(_ c: PhaseRGB) -> String {
        if c.red >= c.green, c.red >= c.blue { return "r" }
        return c.green >= c.blue ? "g" : "b"
    }
}

final class PhaseRGBTests: XCTestCase {
    func testContrastRatioMatchesKnownWCAGValues() {
        XCTAssertEqual(PhaseRGB.white.contrastRatio(to: .black), 21, accuracy: 0.001)
        XCTAssertEqual(PhaseRGB.white.contrastRatio(to: .white), 1, accuracy: 0.001)
        // Order-independent.
        XCTAssertEqual(
            PhaseRGB.black.contrastRatio(to: .white),
            PhaseRGB.white.contrastRatio(to: .black),
            accuracy: 0.001
        )
        // Mid grey (#767676) is the canonical 4.54:1 against white.
        let grey = PhaseRGB(118 / 255, 118 / 255, 118 / 255)
        XCTAssertEqual(grey.contrastRatio(to: .white), 4.54, accuracy: 0.02)
    }

    func testLuminanceUsesTheLinearSegmentNearBlack() {
        // Below 0.04045 sRGB is linear, not a power curve — getting this wrong
        // would overstate how dark the dimmed bands are.
        XCTAssertEqual(PhaseRGB(0.02, 0.02, 0.02).relativeLuminance, 0.02 / 12.92, accuracy: 1e-9)
        XCTAssertEqual(PhaseRGB.black.relativeLuminance, 0, accuracy: 1e-12)
        XCTAssertEqual(PhaseRGB.white.relativeLuminance, 1, accuracy: 1e-9)
    }

    func testScaledClampsIntoRangeWhenMeasured() {
        // Out-of-range components must not produce nonsense luminance.
        XCTAssertEqual(PhaseRGB(2, 2, 2).relativeLuminance, 1, accuracy: 1e-9)
        XCTAssertEqual(PhaseRGB(-1, -1, -1).relativeLuminance, 0, accuracy: 1e-12)
    }

    func testCompositingOverABackground() {
        XCTAssertEqual(PhaseRGB.white.over(.black, opacity: 0.6), PhaseRGB(0.6, 0.6, 0.6))
        XCTAssertEqual(PhaseRGB.white.over(.black, opacity: 1), .white)
        XCTAssertEqual(PhaseRGB.white.over(.black, opacity: 0), .black)
        // Opacity is clamped, so a caller can't manufacture an out-of-gamut colour.
        XCTAssertEqual(PhaseRGB.white.over(.black, opacity: 4), .white)
        XCTAssertEqual(PhaseRGB.white.over(.black, opacity: -1), .black)
    }
}
