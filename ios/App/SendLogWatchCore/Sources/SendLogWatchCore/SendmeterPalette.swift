import Foundation

/// #1028 B1: the ONE shared Sendmeter palette.
///
/// Every colour the phone and the Watch paint resolves from this file: the
/// five semantic hues (`SendmeterSemanticHue`, unchanged), the neutral
/// surface/text ramp that used to live as ~26 scattered phone hexes
/// (`RecordingContextPalette`, `ChartToken`, Workout), the zone hues, and
/// the Watch canvas. Values are Foundation-only `#RRGGBB` strings so Core
/// tests can check contrast (`PhaseRGB.contrastRatio`) without SwiftUI; the
/// phone (`Color(hex:)`) and Watch (`WatchPalette.color`) convert at the edge.
///
/// B2: a test fails on any `Color(hex:)` / literal hex outside the token
/// files (`SendmeterPaletteGateTests`). B3: every text pair below is
/// contrast-checked in both themes (`SendmeterPaletteContrastTests`) and the
/// owner-facing table lives in `docs/design/tokens.md`.
public enum SendmeterPalette {
    /// One light/dark pair. Watch surfaces always read `dark` (the Watch is
    /// dark-only), which is what makes phone-dark and Watch the same palette.
    public struct Pair: Equatable, Sendable {
        public let light: String
        public let dark: String

        public init(_ light: String, _ dark: String) {
            self.light = light
            self.dark = dark
        }

        public init(_ both: String) {
            self.light = both
            self.dark = both
        }

        public func hex(isDark: Bool) -> String { isDark ? dark : light }
        public func rgb(isDark: Bool) -> PhaseRGB { PhaseRGB(hex: hex(isDark: isDark)) }
    }

    // MARK: Neutral ramp — "chalk on slate"
    //
    // A cool slate ramp with a faint indigo cast (it sits next to the
    // `primary` #5B5FC7 brand hue). Dark mode is near-black slate, light mode
    // a chalk-white; both replace the old mix of iOS grey literals and the
    // Watch's navy-only canvas.

    /// Screen background (phone grouped background, Watch canvas).
    public static let canvas = Pair("#F3F3F7", "#0B0C12")
    /// Card surface (phone `SurfaceCard`, Watch `WatchCard` base).
    public static let surface = Pair("#FFFFFF", "#17181F")
    /// Raised/nested surface inside a card (protocol hero, load module,
    /// Watch strong card, trace chart background).
    public static let surfaceRaised = Pair("#F7F7FA", "#22232C")
    /// A second nesting level and the chalk hero tint base.
    public static let surfaceNested = Pair("#ECECF2", "#2B2C36")
    /// Disabled control fill.
    public static let surfaceDisabled = Pair("#E8E8ED", "#2A2B33")
    /// Hairlines and dividers.
    public static let line = Pair("#D8D8DE", "#363743")
    /// Chart gridlines (quieter than `line`).
    public static let grid = Pair("#E2E2E6", "#30313B")

    /// Primary text.
    public static let textPrimary = Pair("#15161C", "#F4F4F8")
    /// Secondary text / metadata (AA on every surface in both themes).
    public static let textSecondary = Pair("#52525C", "#B9BAC6")
    /// Tertiary text: axis labels, timestamps (AA on surface/canvas).
    public static let textTertiary = Pair("#696974", "#9A9BA8")
    /// Disabled label text.
    public static let textDisabled = Pair("#61616B", "#9E9FAA")

    /// Brand-tinted text that must read as "primary" on a neutral surface.
    public static let primaryText = Pair("#4A4EAC", "#A9ADE3")
    /// Brand tint for selected chips / soft fills.
    public static let primarySoft = Pair("#C3C5EC", "#3A3D7A")

    /// Text on a filled `primary` button.
    public static let onPrimary = Pair("#FFFFFF")
    /// Text on a filled `caution` (amber) surface — rest stages.
    public static let onCaution = Pair("#1A1A1A")

    // MARK: Semantic hues (from `SendmeterSemanticHue`)
    //
    // Fills, strokes, dots and chart marks use the canonical hue in BOTH
    // themes (the phone already did; the Watch now matches). Small text in a
    // semantic hue uses the `…Text` pair instead: the canonical amber/blue/
    // orange are below AA as caption text on chalk-white, so light mode reads
    // a darker same-hue variant and dark mode a lighter one.

    public static let primary = Pair(SendmeterSemanticHue.primary.hex)
    public static let optimal = Pair(SendmeterSemanticHue.optimal.hex)
    public static let caution = Pair(SendmeterSemanticHue.caution.hex)
    public static let danger = Pair(SendmeterSemanticHue.danger.hex)
    public static let execution = Pair(SendmeterSemanticHue.execution.hex)
    /// Paused / offline status dot (a neutral, not a warning).
    public static let paused = Pair("#565D6D", "#7D8496")

    public static let optimalText = Pair("#216CAD", "#4FB0FF")
    public static let cautionText = Pair("#7E6521", "#E8C24E")
    public static let dangerText = Pair("#A35229", "#F0864C")
    public static let executionText = Pair("#5C62B0", "#9296EE")

    /// "Ready / success" state hue. The phone's `--success` is the optimal
    /// blue; the Watch used an off-palette mint (0.30, 0.93, 0.68) that the
    /// phone never paints. #1028 B1 moves the Watch onto the phone's value.
    public static let success = Pair(SendmeterSemanticHue.optimal.hex, "#4FB0FF")

    /// Watch Home "Force Gauge" nav-card identity only — a maintainer-
    /// accepted deviation recorded on #538 (kept as-is in #1028).
    public static let watchForceNav = Pair("#FF6EC2")

    // MARK: Rest (#1028 P6)

    /// The resting hue. The phone paints a manual-workout rest in `primary`:
    /// the RESTING accent and the selected rest-target chip
    /// (`ManualWorkoutFullscreen`), and the Watch's resting phase band is the
    /// same hue (`WorkoutPhasePalette`). P6 puts the Watch rest-target chips
    /// on it too, retiring their off-palette mint/cyan/indigo/amber ramp —
    /// the last Watch colour family the phone never painted.
    public static let rest = primary

    // MARK: Chart neutrals + activity hues (`ChartToken`, `ChartActivityHue`)
    //
    // Moved here unchanged from `ChartTheme.swift` so every phone colour lives
    // in this one file. They mirror the web's `--chart-*` and
    // `--chart-activity-*` values (index.css, light / `.dark`), and
    // `ChartThemeTests` pins each one. `chartGrid` is the existing chart grid;
    // `grid` above is the quieter shared grid line the rollout adopts.

    public static let chartReference = Pair("#8E8E93", "#A9A9B0")
    public static let chartGrid = Pair("#E2E2E6", "#3E3E44")
    public static let chartAxis = Pair("#6E6E73", "#A9A9B0")
    public static let chartTooltip = Pair("#FFFFFF", "#2C2C31")
    public static let chartTooltipBorder = Pair("#D8D8DC", "#4A4A50")

    public static let activityBoard = Pair("#2E96F0", "#4FB0FF")
    public static let activityFingerboard = Pair("#7B83EB", "#9296EE")
    public static let activityGym = Pair("#5B5FC7", "#9296EE")
    public static let activityOutdoor = Pair("#218E98", "#65D2DB")
    public static let activityArc = Pair("#1682A5", "#66D5EF")
    public static let activityAntagonist = Pair("#7752A8", "#B18AE8")
    public static let activityRoutine = Pair("#A94D7D", "#E39AC3")
    public static let activityCampus = Pair("#C96032", "#F0864C")
    public static let activityTindeq = Pair("#B96C2C", "#E8A24D")
    public static let activityAuto = Pair("#2A82C5", "#77C8F5")
    public static let activityCustom = Pair("#6E6E73", "#A9A9B0")

    // MARK: Zone hues (Force training quality)

    public static let zonePower = Pair(SendmeterSemanticHue.danger.hex)
    public static let zoneStrength = Pair(SendmeterSemanticHue.caution.hex)
    public static let zonePowerEndurance = Pair("#87669A", "#A88BBB")
    public static let zoneEndurance = Pair("#3CBFA3")

    // MARK: Chalk texture (A1)

    /// Peak opacity of the A1 chalk speckle (`textPrimary` grains) on the
    /// few chalked hero surfaces. Bounded by contrast, not taste: at the
    /// worst case — a full-strength grain right behind a tertiary glyph on
    /// `surfaceRaised` — AA holds up to 0.059 (light) / 0.078 (dark).
    /// `chalkedTextPairs` + `SendmeterPaletteContrastTests` keep it honest.
    public static let chalkOpacity = 0.05

    /// `foreground` blended over `background` at `alpha` (sRGB, like the
    /// compositor paints it), as `#RRGGBB`.
    public static func composite(_ foreground: String, over background: String, alpha: Double) -> String {
        let f = PhaseRGB(hex: foreground), b = PhaseRGB(hex: background)
        func channel(_ x: Double, _ y: Double) -> Int { Int(((x * alpha + y * (1 - alpha)) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            channel(f.red, b.red), channel(f.green, b.green), channel(f.blue, b.blue)
        )
    }

    /// A chalked hero surface at the worst case (a full grain).
    public static func chalked(_ surface: Pair) -> Pair {
        Pair(
            composite(textPrimary.light, over: surface.light, alpha: chalkOpacity),
            composite(textPrimary.dark, over: surface.dark, alpha: chalkOpacity)
        )
    }

    // MARK: Status pills (B3)
    //
    // `StatusPill` paints its label in its hue on a 12% tint of that hue.
    // In build 57 the label was the raw hue: 1.86–2.95:1 in light mode
    // (caution/danger/optimal/execution), below AA on every surface. The
    // label is now the hue mixed into `textPrimary` at `pillTextHueWeight`,
    // which keeps the hue's identity and clears AA on every surface,
    // chalked or not (worst case: caution on chalked surfaceNested, light).

    public static let pillFillOpacity = 0.12
    public static let pillTextHueWeight = 0.45

    /// The pill label for `hue`: the hue over `textPrimary`.
    public static func pillText(_ hue: Pair) -> Pair {
        Pair(
            composite(hue.light, over: textPrimary.light, alpha: pillTextHueWeight),
            composite(hue.dark, over: textPrimary.dark, alpha: pillTextHueWeight)
        )
    }

    /// The pill fill for `hue` on `surface`.
    public static func pillFill(_ hue: Pair, on surface: Pair) -> Pair {
        Pair(
            composite(hue.light, over: surface.light, alpha: pillFillOpacity),
            composite(hue.dark, over: surface.dark, alpha: pillFillOpacity)
        )
    }

    // MARK: Text-pair registry (B3)

    /// A text/background pair the UI actually paints, checked for WCAG AA.
    public struct TextPair: Sendable {
        public let name: String
        public let foreground: Pair
        public let background: Pair
        /// 4.5 for body text, 3.0 for large/bold text and UI glyphs.
        public let minimum: Double

        public init(_ name: String, _ foreground: Pair, on background: Pair, minimum: Double = 4.5) {
            self.name = name
            self.foreground = foreground
            self.background = background
            self.minimum = minimum
        }

        public func ratio(isDark: Bool) -> Double {
            foreground.rgb(isDark: isDark).contrastRatio(to: background.rgb(isDark: isDark))
        }
    }

    /// Every text pair the refined surfaces paint. `docs/design/tokens.md` is
    /// generated from this list (`docs/evidence/issue-1030/tools/tokens.sh`).
    public static let textPairs: [TextPair] = {
        var pairs: [TextPair] = []
        for (name, background) in [
            ("canvas", canvas), ("surface", surface),
            ("surfaceRaised", surfaceRaised), ("surfaceNested", surfaceNested),
        ] {
            pairs.append(TextPair("textPrimary on \(name)", textPrimary, on: background))
            pairs.append(TextPair("textSecondary on \(name)", textSecondary, on: background))
            pairs.append(TextPair("textTertiary on \(name)", textTertiary, on: background))
            pairs.append(TextPair("primaryText on \(name)", primaryText, on: background))
        }
        // A1: text on the chalked hero surfaces, worst case.
        for (name, background) in [("surface", surface), ("surfaceRaised", surfaceRaised)] {
            pairs.append(TextPair("textSecondary on chalked \(name)", textSecondary, on: chalked(background)))
            pairs.append(TextPair("textTertiary on chalked \(name)", textTertiary, on: chalked(background)))
            pairs.append(TextPair("primaryText on chalked \(name)", primaryText, on: chalked(background)))
        }
        // Status pills: every hue a pill is painted in, on every surface a
        // pill sits on (including the chalked heroes).
        for (hueName, hue) in [
            ("primary", primary), ("optimal", optimal), ("caution", caution),
            ("danger", danger), ("execution", execution), ("paused", paused),
            ("zonePowerEndurance", zonePowerEndurance), ("zoneEndurance", zoneEndurance),
        ] {
            for (surfaceName, background) in [
                ("canvas", canvas), ("surface", surface), ("surfaceRaised", surfaceRaised),
                ("surfaceNested", surfaceNested), ("chalked surface", chalked(surface)),
                ("chalked surfaceNested", chalked(surfaceNested)),
            ] {
                pairs.append(TextPair(
                    "pill \(hueName) on \(surfaceName)", pillText(hue), on: pillFill(hue, on: background)
                ))
            }
        }
        pairs.append(TextPair("textDisabled on surfaceDisabled", textDisabled, on: surfaceDisabled))
        pairs.append(TextPair("onPrimary on primary (button label)", onPrimary, on: primary))
        pairs.append(TextPair("onCaution on caution (rest stage)", onCaution, on: caution))
        for (name, hue) in [
            ("optimalText", optimalText), ("cautionText", cautionText),
            ("dangerText", dangerText), ("executionText", executionText),
        ] {
            for (surfaceName, background) in [("surface", surface), ("surfaceRaised", surfaceRaised)] {
                pairs.append(TextPair("\(name) on \(surfaceName)", hue, on: background))
            }
        }
        return pairs
    }()
}
