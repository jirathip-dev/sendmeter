import Foundation

/// Plain sRGB values for the routine runner's light-appearance contrast
/// contract. Keeping this independent of SwiftUI lets the compositing math be
/// tested on every package platform instead of treating a source string as
/// evidence of a readable render.
public struct RoutineRunnerRGB: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    public static let black = RoutineRunnerRGB(red: 0, green: 0, blue: 0)
    public static let white = RoutineRunnerRGB(red: 1, green: 1, blue: 1)

    /// WCAG relative luminance (sRGB → linear, Rec. 709 weights).
    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            let clamped = min(max(component, 0), 1)
            return clamped <= 0.04045
                ? clamped / 12.92
                : pow((clamped + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linear(red)
            + 0.7152 * linear(green)
            + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1…21. The order of the colours is irrelevant.
    public func contrastRatio(to other: RoutineRunnerRGB) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Composites this sRGB foreground over a background at the supplied
    /// opacity, matching the alpha treatment used by SwiftUI's text styles.
    public func over(_ background: RoutineRunnerRGB, opacity: Double) -> RoutineRunnerRGB {
        let alpha = min(max(opacity, 0), 1)
        return RoutineRunnerRGB(
            red: background.red + (red - background.red) * alpha,
            green: background.green + (green - background.green) * alpha,
            blue: background.blue + (blue - background.blue) * alpha
        )
    }
}

/// The deterministic palette/treatment model behind the runner's SwiftUI
/// appearance. The material itself is supplied by SwiftUI, so `glassSurface`
/// models the intended resolved direction (light material over REST, dark
/// material over the other fields); the explicit DONE shade is then applied in
/// the same order as the view's material overlay.
public enum RoutineRunnerContrastPalette {
    public static let minimumBodyContrast: Double = 4.5
    public static let minimumLargeTextContrast: Double = 3.0
    public static let bodyTextOpacity: Double = 0.9
    public static let glassShadeOpacity: Double = 0.12
    public static let doneCompletionForegroundHex = "#1A1A1A"

    private static let materialTintOpacity: Double = 0.20

    public static func glassShadeOpacity(for state: RoutineRunnerVisualState) -> Double {
        state == .done ? glassShadeOpacity : 0
    }

    public static func field(for state: RoutineRunnerVisualState) -> RoutineRunnerRGB {
        switch state {
        case .working: return RoutineRunnerRGB(hex: 0x5B5FC7)
        case .rest: return RoutineRunnerRGB(hex: 0xDDB13A)
        case .paused: return RoutineRunnerRGB(hex: 0x565D6D)
        case .done: return RoutineRunnerRGB(hex: 0x7B83EB)
        }
    }

    public static func foreground(for state: RoutineRunnerVisualState) -> RoutineRunnerRGB {
        state == .rest ? RoutineRunnerRGB(hex: 0x1A1A1A) : .white
    }

    /// A conservative, deterministic proxy for the phase-aware material
    /// surface: REST resolves toward light and the white-text phases resolve
    /// toward dark. The explicit DONE shade is kept separate so the test
    /// covers both the material direction and the view-owned overlay.
    public static func glassSurface(for state: RoutineRunnerVisualState) -> RoutineRunnerRGB {
        let tint = state == .rest ? RoutineRunnerRGB.white : .black
        return tint.over(field(for: state), opacity: materialTintOpacity)
    }

    public static func treatedGlassSurface(for state: RoutineRunnerVisualState) -> RoutineRunnerRGB {
        RoutineRunnerRGB.black.over(
            glassSurface(for: state),
            opacity: glassShadeOpacity(for: state)
        )
    }

    public static func bodyText(on surface: RoutineRunnerRGB, state: RoutineRunnerVisualState) -> RoutineRunnerRGB {
        foreground(for: state).over(surface, opacity: bodyTextOpacity)
    }

    public static var doneCompletionForeground: RoutineRunnerRGB {
        RoutineRunnerRGB(hex: 0x1A1A1A)
    }
}
