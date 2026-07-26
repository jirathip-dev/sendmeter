import XCTest
import SendLogWatchCore

/// Issue #243 (221b): the watch live-workout view tints its whole background
/// by phase. Colour cannot be judged headlessly, but the two things that make
/// it fail *can* be: resolving the wrong phase, and picking a fill the text
/// can't be read on. Both live here rather than in the view.
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
        // The view can't draw a count-up without a start; the fill must agree
        // with what the timer shows rather than tint green over nothing.
        XCTAssertEqual(phase(climbing: true, climbingSince: nil, restStartedAt: t0), .resting)
    }

    func testRestingUntilTheTargetThenRestOver() {
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 180, after: 0), .resting)
        XCTAssertEqual(phase(restStartedAt: t0, restTargetS: 180, after: 179.9), .resting)
        // Exactly at zero already counts as over — the countdown reads 0:00
        // and the haptic has fired, so the screen must not still say rest.
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
    /// fill of the phase's own colour. Every fill has to carry white body text
    /// at AAA, at full brightness and dimmed.
    func testEveryFillCarriesItsLabelAtAAAContrast() {
        for phase in WorkoutPhase.allCases {
            for reduced in [false, true] {
                let fill = WorkoutPhasePalette.fill(for: phase, luminanceReduced: reduced)
                let ratio = fill.background.contrastRatio(to: fill.label)
                XCTAssertGreaterThanOrEqual(
                    ratio, WorkoutPhasePalette.minimumContrast,
                    "\(phase) (reduced: \(reduced)) contrast \(ratio)"
                )
            }
        }
    }

    /// `.secondary` on watchOS is roughly white at 60% — the elapsed time,
    /// kcal and altitude readouts. They only need AA (4.5:1), but they must
    /// not have been quietly dropped below it by the fill.
    func testSecondaryTextStillClearsAAOnEveryFill() {
        for phase in WorkoutPhase.allCases {
            let bg = WorkoutPhasePalette.fill(for: phase).background
            let secondary = PhaseRGB(
                bg.red + (1 - bg.red) * 0.6,
                bg.green + (1 - bg.green) * 0.6,
                bg.blue + (1 - bg.blue) * 0.6
            )
            XCTAssertGreaterThanOrEqual(
                bg.contrastRatio(to: secondary), 4.5,
                "\(phase) secondary contrast \(bg.contrastRatio(to: secondary))"
            )
        }
    }

    /// Dimming may only ever help legibility — white text on a darker fill is
    /// a higher ratio, never a lower one.
    func testDimmingNeverReducesContrast() {
        for phase in WorkoutPhase.allCases {
            let full = WorkoutPhasePalette.fill(for: phase)
            let dim = WorkoutPhasePalette.fill(for: phase, luminanceReduced: true)
            XCTAssertLessThanOrEqual(dim.background.relativeLuminance, full.background.relativeLuminance)
            XCTAssertGreaterThanOrEqual(
                dim.background.contrastRatio(to: dim.label),
                full.background.contrastRatio(to: full.label)
            )
        }
    }

    /// The always-on fill has to stay genuinely dark — a full-screen tint left
    /// bright in the dimmed state is a burn-in and battery liability.
    func testDimmedFillsAreDark() {
        for phase in WorkoutPhase.allCases {
            let dim = WorkoutPhasePalette.fill(for: phase, luminanceReduced: true)
            XCTAssertLessThan(dim.background.relativeLuminance, 0.02, "\(phase)")
        }
    }

    /// The bottom wash sits under the secondary readouts and the action
    /// button; it must darken, never lighten.
    func testBottomShadeOnlyDarkens() {
        let shade = WorkoutPhasePalette.bottomShade
        XCTAssertGreaterThan(shade, 0)
        XCTAssertLessThan(shade, 1)
        for phase in WorkoutPhase.allCases {
            let bg = WorkoutPhasePalette.fill(for: phase).background
            let shaded = bg.scaled(1 - shade) // black at `shade` opacity over it
            XCTAssertLessThan(shaded.relativeLuminance, bg.relativeLuminance + 1e-12)
            XCTAssertGreaterThanOrEqual(
                shaded.contrastRatio(to: .white), WorkoutPhasePalette.minimumContrast
            )
        }
    }

    /// The whole point is glanceability: the three live phases must be
    /// distinguishable *as colours*, not just as labels — including dimmed,
    /// where a muddy palette collapses.
    func testLivePhasesAreVisiblyDistinct() {
        let live: [WorkoutPhase] = [.climbing, .resting, .restOver]
        for reduced in [false, true] {
            let fills = live.map { WorkoutPhasePalette.fill(for: $0, luminanceReduced: reduced).background }
            for (i, a) in fills.enumerated() {
                for b in fills[(i + 1)...] {
                    // Each pair differs by a clear margin on at least one channel.
                    let delta = max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
                    XCTAssertGreaterThan(delta, 0.08, "\(a) vs \(b) (reduced: \(reduced))")
                    // ...and each phase's dominant channel is its own.
                    XCTAssertNotEqual(dominantChannel(a), dominantChannel(b))
                }
            }
        }
    }

    /// Idle draws no tint at all — the view keeps the stock black background
    /// until there is a phase to report.
    func testIdleIsUntinted() {
        XCTAssertEqual(WorkoutPhasePalette.fill(for: .idle).background, .black)
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
        // would overstate how dark the dimmed fills are.
        XCTAssertEqual(PhaseRGB(0.02, 0.02, 0.02).relativeLuminance, 0.02 / 12.92, accuracy: 1e-9)
        XCTAssertEqual(PhaseRGB.black.relativeLuminance, 0, accuracy: 1e-12)
        XCTAssertEqual(PhaseRGB.white.relativeLuminance, 1, accuracy: 1e-9)
    }

    func testScaledClampsIntoRangeWhenMeasured() {
        // Out-of-range components must not produce nonsense luminance.
        XCTAssertEqual(PhaseRGB(2, 2, 2).relativeLuminance, 1, accuracy: 1e-9)
        XCTAssertEqual(PhaseRGB(-1, -1, -1).relativeLuminance, 0, accuracy: 1e-12)
    }
}
