import Foundation

/// Plain sRGB values for chart contrast checks. Keeping this independent of
/// SwiftUI lets the Force trace's composited colours be tested on the host
/// package instead of treating a token or opacity literal as evidence of a
/// readable render.
public struct ChartContrastRGB: Equatable, Hashable, Sendable {
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

    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt32(cleaned, radix: 16) ?? 0
        if cleaned.count == 3 {
            self.init(
                red: Double(((value >> 8) & 0xF) * 17) / 255,
                green: Double(((value >> 4) & 0xF) * 17) / 255,
                blue: Double((value & 0xF) * 17) / 255
            )
        } else {
            self.init(hex: value)
        }
    }

    public static let black = ChartContrastRGB(red: 0, green: 0, blue: 0)
    public static let white = ChartContrastRGB(red: 1, green: 1, blue: 1)

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
    public func contrastRatio(to other: ChartContrastRGB) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Composites this sRGB foreground over a background at the supplied
    /// opacity, matching the alpha treatment used by the chart canvas.
    public func over(_ background: ChartContrastRGB, opacity: Double) -> ChartContrastRGB {
        let alpha = min(max(opacity, 0), 1)
        return ChartContrastRGB(
            red: background.red + (red - background.red) * alpha,
            green: background.green + (green - background.green) * alpha,
            blue: background.blue + (blue - background.blue) * alpha
        )
    }
}

/// The native Force canvas owns an opaque neutral surface so its contrast
/// contract has a stable background rather than a material/secondary-opacity
/// blend that changes with the surrounding card.
public enum ChartContrastPolicy {
    public static let minimumNonTextContrast: Double = 3.0
    public static let lightTraceBackgroundHex = "#F2F2F7"
    public static let darkTraceBackgroundHex = "#1C1C1E"

    public static func traceBackgroundHex(isDark: Bool) -> String {
        isDark ? darkTraceBackgroundHex : lightTraceBackgroundHex
    }

    public static func traceBackground(isDark: Bool) -> ChartContrastRGB {
        ChartContrastRGB(hex: traceBackgroundHex(isDark: isDark))
    }

    /// Finds the least opacity, to a thousandth, that makes a foreground
    /// graphical cue meet the supplied WCAG ratio over the actual surface.
    public static func minimumOpacity(
        foreground: ChartContrastRGB,
        background: ChartContrastRGB,
        minimumRatio: Double
    ) -> Double {
        let target = max(1, minimumRatio)
        for step in 0...1_000 {
            let opacity = Double(step) / 1_000
            if foreground.over(background, opacity: opacity).contrastRatio(to: background) >= target {
                return opacity
            }
        }
        return 1
    }
}
