import Foundation

/// Presentation-only contracts shared by the native watch app's visual
/// surfaces. SwiftUI owns the actual `Color`/`Gradient` values; this package
/// keeps the decisions that must remain stable under tests (hit targets,
/// semantic state language and Always-On dimming) free of WatchKit.
public enum WatchDesignTokens {
    /// Apple's minimum recommended watch hit target. Primary actions in the
    /// watch app use this value as their minimum, never as a fixed size.
    public static let minimumHitTarget: Double = 44

    /// A short phase transition is useful at a glance, but is removed entirely
    /// when Reduce Motion is enabled rather than merely slowed down.
    public static let motionDuration: Double = 0.35
    public static let reducedMotionDuration: Double = 0

    /// Maximum glow strength for always-on rendering. The watchOS system adds
    /// its own luminance reduction; this cap keeps saturated gradients from
    /// becoming a burn-in/battery liability on top of it.
    public static let alwaysOnAccentScale: Double = 0.42

    // Deep OLED-safe canvas and raised surfaces. These are sRGB values so the
    // SwiftUI target can translate them to Color while Core tests their
    // contrast and dimmed behavior without importing SwiftUI.
    public static let canvas = PhaseRGB(0.018, 0.024, 0.055)
    public static let canvasRaised = PhaseRGB(0.045, 0.055, 0.12)
    public static let card = PhaseRGB(0.075, 0.082, 0.17)
    public static let cardStrong = PhaseRGB(0.12, 0.12, 0.25)

    // Semantic accents. Hue is the differentiator; every important state is
    // also named/iconed in the UI so colour is never the only signal.
    public static let primary = PhaseRGB(0.48, 0.40, 1.0)
    public static let secondary = PhaseRGB(0.18, 0.84, 0.96)
    public static let success = PhaseRGB(0.30, 0.93, 0.68)
    public static let warning = PhaseRGB(1.0, 0.76, 0.32)
    public static let danger = PhaseRGB(1.0, 0.38, 0.46)
    public static let force = PhaseRGB(1.0, 0.43, 0.76)

    public static let semanticAccents: [PhaseRGB] = [
        primary, secondary, success, warning, danger, force,
    ]

    /// The reduced variant keeps semantic hue while cutting emitted light.
    public static func alwaysOn(_ color: PhaseRGB) -> PhaseRGB {
        color.scaled(alwaysOnAccentScale)
    }
}
/// State language used by chips, banners and accessibility labels throughout
/// waiting, status, workout and force flows.
public enum WatchVisualState: String, CaseIterable, Sendable {
    case ready
    case syncing
    case offline
    case stale
    case success
    case warning
    case danger

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .syncing: "Syncing"
        case .offline: "Offline"
        case .stale: "Needs attention"
        case .success: "Saved"
        case .warning: "Caution"
        case .danger: "Error"
        }
    }

    public var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "icloud.slash"
        case .stale: "clock.badge.exclamationmark"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }
}
