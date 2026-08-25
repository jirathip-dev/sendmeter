import SwiftUI

/// Semantic chart palette — web parity (#649). Every hex below mirrors
/// `src/index.css` (light `:root` ~L157-177, dark `.dark` ~L356-377) and the
/// token names in `src/lib/chartTheme.ts`, so a CSS change is caught by the
/// hex-string assertions in `ChartThemeTests` instead of silently drifting.
///
/// Charts read `@Environment(\.colorScheme)` and pass the scheme down —
/// never `AppTheme.storedChoice()` (that returns `.system` most of the time
/// and would need the OS appearance threaded in anyway).
public enum ChartToken: String, CaseIterable, Sendable {
    case focus
    case health
    case load
    case force
    case forceSecondary
    case optimal
    case caution
    case alert
    case reference
    case grid
    case axis
    case tooltip
    case tooltipBorder

    /// CSS hex in light mode (index.css `--chart-*`).
    public var lightHex: String { hexPair.0 }

    /// CSS hex in dark mode (index.css `.dark` `--chart-*`).
    public var darkHex: String { hexPair.1 }

    /// Hex for the given appearance mode.
    public func hex(for scheme: ColorScheme) -> String {
        scheme == .dark ? darkHex : lightHex
    }

    /// Resolved color for the given appearance mode.
    public func color(_ scheme: ColorScheme) -> Color {
        Color(chartHex: hex(for: scheme))
    }

    /// `--chart-area-opacity` (index.css): 0.16 light / 0.20 dark. The top
    /// stop of every area fill.
    public func areaOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.20 : 0.16
    }

    /// Training-quality hue for the training-balance bars — the same *mapping*
    /// as the web's `QUALITY_COLORS` (power → danger, strength → warning,
    /// power-endurance → info, endurance → success), expressed in ChartTheme
    /// tokens so the palette stays central (#653). This is a hue-family
    /// substitution, NOT an exact hex match: the tokens resolve to the
    /// `--chart-*` palette (alert `#E5743A`, caution `#DDB13A`, load
    /// `#7B83EB`, optimal `#2E96F0`), while the web's `QUALITY_COLORS` use the
    /// semantic `--danger/--warning/--info/--success` vars (`#B95122`,
    /// `#956A00`, `#5964B7`, `#1674BE`). Same hue families, deliberately
    /// different values (#653 review finding 9).
    public static func zoneQuality(_ zone: ZoneQuality) -> ChartToken {
        switch zone {
        case .power: return .alert
        case .strength: return .caution
        case .powerEndurance: return .load
        case .endurance: return .optimal
        }
    }

    /// `--chart-band-opacity` (index.css): 0.12 light / 0.16 dark. The top
    /// stop of a reference band fill.
    public func bandOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.16 : 0.12
    }

    /// Bottom stop of the vertical area fill — `ChartDefs.tsx` uses 0.03 for
    /// focus/health and 0.04 for load/force.
    public var areaBottomOpacity: Double {
        self == .load || self == .force ? 0.04 : 0.03
    }

    /// Vertical area fill, top → bottom (`ChartDefs.tsx`): the token at
    /// `areaOpacity` fading to `areaBottomOpacity`.
    public func areaGradient(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: color(scheme).opacity(areaOpacity(scheme)), location: 0),
                .init(color: color(scheme).opacity(areaBottomOpacity), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Reference band fill (`referenceBand` in `ChartDefs.tsx`): the token
    /// at `bandOpacity` fading to 0.04.
    public func bandGradient(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: color(scheme).opacity(bandOpacity(scheme)), location: 0),
                .init(color: color(scheme).opacity(0.04), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Selected-halo stops (`selectedHalo` in `ChartDefs.tsx`): 0.28 @ 0,
    /// 0.08 @ 0.7, 0 @ 1.0 of the focus token — kept as data so tests can
    /// assert them.
    public static let selectedHaloStops: [(opacity: Double, location: Double)] = [
        (opacity: 0.28, location: 0),
        (opacity: 0.08, location: 0.7),
        (opacity: 0, location: 1)
    ]

    /// The universal ACWR status color — the single mapping shared by the Load
    /// card and the projection card's day-0 dot (#652 F12). The web splits
    /// under-training (`--primary`) from low (`--info`); native folds both into
    /// `focus`, matching the existing Load card.
    public static func acwrStatusColor(_ ratio: Double?, _ scheme: ColorScheme) -> Color {
        switch TrainingMetrics.acwrStatus(ratio) {
        case .optimal: return ChartToken.optimal.color(scheme)
        case .low, .underTraining: return ChartToken.focus.color(scheme)
        case .caution: return ChartToken.caution.color(scheme)
        case .danger: return ChartToken.alert.color(scheme)
        case .noData: return .secondary
        }
    }

    /// Radial glow behind a selected point, built from `selectedHaloStops`.
    /// The web's `selectedHalo` SVG is centered with no explicit `cx`/`cy`,
    /// so the native halo defaults to the center too; radii are parameters
    /// because SwiftUI measures them in points of the filled shape.
    public static func selectedHalo(
        _ scheme: ColorScheme,
        center: UnitPoint = .center,
        startRadius: CGFloat = 0,
        endRadius: CGFloat = 44
    ) -> RadialGradient {
        let focus = ChartToken.focus.color(scheme)
        return RadialGradient(
            stops: selectedHaloStops.map {
                .init(color: focus.opacity($0.opacity), location: $0.location)
            },
            center: center,
            startRadius: startRadius,
            endRadius: endRadius
        )
    }

    private var hexPair: (light: String, dark: String) {
        switch self {
        case .focus: return ("#5B5FC7", "#9296EE")
        case .health: return ("#2E96F0", "#4FB0FF")
        case .load: return ("#7B83EB", "#9296EE")
        case .force: return ("#5B5FC7", "#9296EE")
        case .forceSecondary: return ("#2E96F0", "#4FB0FF")
        case .optimal: return ("#2E96F0", "#4FB0FF")
        case .caution: return ("#DDB13A", "#E8C24E")
        case .alert: return ("#E5743A", "#F0864C")
        case .reference: return ("#8E8E93", "#A9A9B0")
        case .grid: return ("#E2E2E6", "#3E3E44")
        case .axis: return ("#6E6E73", "#A9A9B0")
        case .tooltip: return ("#FFFFFF", "#2C2C31")
        case .tooltipBorder: return ("#D8D8DC", "#4A4A50")
        }
    }
}

/// Per-activity-type hues (`--chart-activity-*`, index.css) for the training-
/// load activity mix and heatmaps. Every hue has a distinct dark-mode value
/// (index.css `.dark` override block) — `auto` and `custom` included (#649
/// review: the CSS resolves them via `--chart-activity-auto/custom` vars, so
/// dark renders #77C8F5 / #A9A9B0, not the light values).
public enum ChartActivityHue: String, CaseIterable, Sendable {
    case board
    case fingerboard
    case gym
    case outdoor
    case arc
    case antagonist
    case routine
    case campus
    case tindeq
    case auto
    case custom

    /// CSS hex in light mode (`--chart-activity-*`).
    public var lightHex: String { hexPair.0 }

    /// CSS hex in dark mode; every hue has a distinct dark value.
    public var darkHex: String { hexPair.1 }

    /// Hex for the given appearance mode.
    public func hex(for scheme: ColorScheme) -> String {
        scheme == .dark ? darkHex : lightHex
    }

    /// Resolved color for the given appearance mode.
    public func color(_ scheme: ColorScheme) -> Color {
        Color(chartHex: hex(for: scheme))
    }

    /// Web `activityColor(type)` fallback (`activityTypes.ts`): an unknown
    /// activity type renders as the reference token.
    public static func color(forActivityID id: String, scheme: ColorScheme) -> Color {
        ChartActivityHue(rawValue: id)?.color(scheme) ?? ChartToken.reference.color(scheme)
    }

    private var hexPair: (light: String, dark: String) {
        switch self {
        case .board: return ("#2E96F0", "#4FB0FF")
        case .fingerboard: return ("#7B83EB", "#9296EE")
        case .gym: return ("#5B5FC7", "#9296EE")
        case .outdoor: return ("#218E98", "#65D2DB")
        case .arc: return ("#1682A5", "#66D5EF")
        case .antagonist: return ("#7752A8", "#B18AE8")
        case .routine: return ("#A94D7D", "#E39AC3")
        case .campus: return ("#C96032", "#F0864C")
        case .tindeq: return ("#B96C2C", "#E8A24D")
        case .auto: return ("#2A82C5", "#77C8F5")
        case .custom: return ("#6E6E73", "#A9A9B0")
        }
    }
}

private extension Color {
    /// Hex-string init local to ChartTheme.swift (the app target's public
    /// `Color(hex:)` lives in `DesignSystem.swift` and is not visible from
    /// the SendmeterCore module this file compiles into).
    init(chartHex: String) {
        let cleaned = chartHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red, green, blue: UInt64
        switch cleaned.count {
        case 3:
            (red, green, blue) = (
                ((value >> 8) & 0xF) * 17,
                ((value >> 4) & 0xF) * 17,
                (value & 0xF) * 17
            )
        case 8:
            (red, green, blue) = (
                (value >> 24) & 0xFF,
                (value >> 16) & 0xFF,
                (value >> 8) & 0xFF
            )
        default:
            (red, green, blue) = (
                (value >> 16) & 0xFF,
                (value >> 8) & 0xFF,
                value & 0xFF
            )
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}
