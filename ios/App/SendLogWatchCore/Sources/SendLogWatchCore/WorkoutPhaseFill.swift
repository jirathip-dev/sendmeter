import Foundation

/// What the live workout view is doing right now, as far as colour is
/// concerned (issue #243, 221b; reworked in #277).
///
/// The watch is read at arm's length mid-route, where a 11pt status label is
/// not legible but a colour block is. The phase is therefore the thing the
/// band behind the phase label and countdown is tinted by, so it has to be
/// derivable from the same inputs the view already has — no extra stored
/// state, no timer of its own.
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

    /// Parses `#RRGGBB` (leading `#` optional, case-insensitive). The single
    /// cross-surface hex source (`SendmeterSemanticHue`) stays Foundation-only
    /// so the phone, watch and widget palettes can all resolve it without
    /// importing SwiftUI.
    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

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

    /// This colour composited over `background` at `opacity`. The one place
    /// the "`.secondary` is roughly white at 60%" assumption is written down,
    /// so the on-black readouts can be measured the same way the view draws them.
    public func over(_ background: PhaseRGB, opacity: Double) -> PhaseRGB {
        let a = min(max(opacity, 0), 1)
        return PhaseRGB(
            background.red + (red - background.red) * a,
            background.green + (green - background.green) * a,
            background.blue + (blue - background.blue) * a
        )
    }
}

/// The colours the live view paints for one phase.
///
/// Since #277 the phase colour is a *band* behind the phase label and the big
/// countdown, not the whole display (TimerPlus-style colour block on black).
/// That splits what used to be one pairing into two: label-on-band, and the
/// secondary readouts sitting on the black screen either side of it.
public struct PhaseFill: Sendable, Equatable {
    /// The screen behind everything. Black for every phase — the colour is
    /// carried by the band, and the readouts around it are measured on this.
    public let screen: PhaseRGB
    /// The rounded block behind the phase eyebrow ("CLIMBING") and the big
    /// countdown.
    public let band: PhaseRGB
    /// The eyebrow and countdown sitting ON the band. Deliberately not the
    /// phase's own hue: green text on a green band is the obvious way this
    /// feature fails.
    public let label: PhaseRGB

    public init(screen: PhaseRGB, band: PhaseRGB, label: PhaseRGB) {
        self.screen = screen
        self.band = band
        self.label = label
    }
}

/// Phase → colour, mirroring the phone fullscreen's `accent` *hues*
/// (`src/components/PhoneWorkoutFullscreen.tsx:103`, dark theme): climbing is
/// `--success` electric blue, resting is `--primary` purple, rest-over is
/// `--danger` orange (issue #277 follow-up). The band composites each hue
/// toward black at a fixed opacity rather than reusing the phone's own
/// values outright: the phone mixes ~12-18% of a bright accent into a light
/// canvas, while the watch paints a band onto a black OLED and has to stay
/// dark enough that white text keeps AAA contrast on it.
public enum WorkoutPhasePalette {
    /// `--success` (dark theme), climbing — also the view's Play tint.
    public static let phoneSuccess = PhaseRGB(0x4F / 255, 0xB0 / 255, 0xFF / 255)
    /// `--primary`, resting.
    private static let phonePrimary = PhaseRGB(0x5B / 255, 0x5F / 255, 0xC7 / 255)
    /// `--danger` (dark theme), rest-over — also the view's End/Stop tint.
    public static let phoneDanger = PhaseRGB(0xF0 / 255, 0x86 / 255, 0x4C / 255)

    /// Every band is picked to clear this against `label` — AAA (7:1) for
    /// body text, with margin left for the OLED's own gamma. The secondary
    /// readouts on `screen` clear it too (see `secondaryOpacity`).
    public static let minimumContrast: Double = 7

    /// Cross-fade duration for a phase change. Long enough to read as a
    /// transition rather than a cut, short enough that "rest over" still
    /// lands as an alert.
    public static let transitionSeconds: Double = 0.45

    /// What watchOS's `.secondary` foreground style amounts to over the black
    /// screen: white at ~60%. The elapsed time, kcal, altitude and the
    /// BOULDERS eyebrow are drawn with it, and since #277 they sit on black
    /// rather than on the phase colour — so this is the number their contrast
    /// claim rests on.
    public static let secondaryOpacity: Double = 0.6

    /// How far the band is pulled down in the always-on dimmed state. watchOS
    /// dims aggressively on its own; a saturated block left at full value is
    /// both a burn-in and a battery liability, and reads muddy once the
    /// display's own reduction is stacked on top. A band is already a far
    /// smaller lit area than the full-screen fill it replaced (#277), but the
    /// scaling stays: always-on is measured in hours, not glances.
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
        // Phone's climbing blue, composited toward black at 48% — brought
        // down just far enough to clear AAA under a white label without
        // losing the hue to "deep navy". Accepted hue-adjacency trade
        // (#277 follow-up): climbing and resting are now both blue-leaning,
        // so the CVD-safe green/blue/red separation the earlier palette had
        // is gone by design — the phone's colour *meanings* won out.
        case .climbing: base = phoneSuccess.over(.black, opacity: 0.48)
        // Phone's resting purple, composited at 65% — needs more of the hue
        // left in than climbing to read as distinct from it at this size.
        case .resting: base = phonePrimary.over(.black, opacity: 0.65)
        // Phone's rest-over orange, composited at 48%. The only band with a
        // red-dominant channel, so the flip still reads under a red/green
        // colour deficiency and under the always-on dim.
        case .restOver: base = phoneDanger.over(.black, opacity: 0.48)
        }
        return PhaseFill(
            screen: .black,
            band: luminanceReduced ? base.scaled(luminanceReducedScale) : base,
            label: .white
        )
    }
}
