import Foundation

/// What the live workout view is doing right now, as far as colour is
/// concerned (issue #243, 221b).
///
/// The watch is read at arm's length mid-route, where a 11pt status label is
/// not legible but a full-screen colour is. The phase is therefore the thing
/// the whole background is tinted by, so it has to be derivable from the same
/// inputs the view already has — no extra stored state, no timer of its own.
public enum WorkoutPhase: String, Sendable, Equatable, CaseIterable {
    /// Running, but neither climbing nor resting yet (defensive — the manager
    /// opens a rest the moment the workout starts). No tint.
    case idle
    /// A boulder is open: count-up.
    case climbing
    /// Between boulders, countdown still running.
    case resting
    /// The rest countdown has passed its target — get back on the wall.
    case restOver
}

/// A plain sRGB triple. Not `SwiftUI.Color`, so the palette (and the contrast
/// arithmetic that justifies it) compiles and is tested on Linux CI (#191/#199)
/// — the view's only job is to hand these three numbers to `Color(red:green:blue:)`.
public struct PhaseRGB: Sendable, Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = PhaseRGB(1, 1, 1)
    public static let black = PhaseRGB(0, 0, 0)

    /// WCAG relative luminance (sRGB → linear, Rec.709 weights).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1…21. Order-independent.
    public func contrastRatio(to other: PhaseRGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Scales toward black in sRGB space. Used for the always-on (luminance
    /// reduced) variant — the hue survives, the emitted light does not.
    public func scaled(_ factor: Double) -> PhaseRGB {
        PhaseRGB(red * factor, green * factor, blue * factor)
    }
}

/// The colours the live view paints for one phase.
public struct PhaseFill: Sendable, Equatable {
    /// The full-screen tint.
    public let background: PhaseRGB
    /// The phase eyebrow ("CLIMBING") and the big countdown sitting on it.
    /// Deliberately not the phase's own hue: green text on a green fill is
    /// the obvious way this feature fails.
    public let label: PhaseRGB

    public init(background: PhaseRGB, label: PhaseRGB) {
        self.background = background
        self.label = label
    }
}

/// Phase → colour, mirroring the phone fullscreen's `accent` *meanings*
/// (`src/components/PhoneWorkoutFullscreen.tsx`): climbing reads go, resting
/// reads hold, rest-over reads act now. The values are not the phone's:
/// the phone mixes ~12% of a bright accent into a light canvas, while the
/// watch paints onto a black OLED and has to stay dark enough that white text
/// keeps AAA contrast and the panel does not glow at arm's length.
public enum WorkoutPhasePalette {
    /// Every fill is picked to clear this against `label` — AAA (7:1) for
    /// body text, with margin left for the OLED's own gamma.
    public static let minimumContrast: Double = 7

    /// Cross-fade duration for a phase change. Long enough to read as a
    /// transition rather than a cut, short enough that "rest over" still
    /// lands as an alert.
    public static let transitionSeconds: Double = 0.45

    /// Opacity of the static black wash over the bottom of the screen. The
    /// secondary readouts (kcal, altitude) and the action button live down
    /// there; darkening under them buys contrast without touching the hue at
    /// the top, where the phase label and countdown are.
    public static let bottomShade: Double = 0.45

    /// How far the fill is pulled down in the always-on dimmed state. watchOS
    /// dims aggressively on its own; a saturated full-screen fill left at full
    /// value is both a burn-in and a battery liability, and reads muddy once
    /// the display's own reduction is stacked on top.
    public static let luminanceReducedScale: Double = 0.45

    /// Resolves the phase from exactly what `WorkoutLiveView` already holds.
    /// `now` is passed in (never read from the clock) so rest-over is testable.
    public static func phase(
        manualClimbing: Bool,
        climbingSince: Date?,
        restStartedAt: Date?,
        restTargetS: Int,
        now: Date
    ) -> WorkoutPhase {
        if manualClimbing, climbingSince != nil { return .climbing }
        guard let restStartedAt else { return .idle }
        let end = restStartedAt.addingTimeInterval(Double(restTargetS))
        return now >= end ? .restOver : .resting
    }

    public static func fill(for phase: WorkoutPhase, luminanceReduced: Bool = false) -> PhaseFill {
        let base: PhaseRGB
        switch phase {
        case .idle: base = .black
        // Deep forest — 10:1 under white. "Green" at watch scale needs the
        // green *channel* dominant, not a bright green: #2ECC71 as a fill
        // would leave the countdown at ~2:1.
        case .climbing: base = PhaseRGB(0.04, 0.30, 0.16)
        // Deep navy-blue, the calmest and darkest of the three (12:1) — it is
        // the phase you spend the most time staring at.
        case .resting: base = PhaseRGB(0.06, 0.20, 0.42)
        // Deep red (12:1). Sits far from both others in hue *and* in channel
        // dominance, so the flip still reads under a red/green colour
        // deficiency and under the always-on dim.
        case .restOver: base = PhaseRGB(0.45, 0.06, 0.07)
        }
        return PhaseFill(
            background: luminanceReduced ? base.scaled(luminanceReducedScale) : base,
            label: .white
        )
    }
}
