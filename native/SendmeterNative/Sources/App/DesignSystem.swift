import SendmeterCore
import SwiftUI

public enum SendmeterStyle {
    public static let radius: CGFloat = 18
    public static let spacing: CGFloat = 16

    public static let capacity = Color(hex: "#2E96F0")
    public static let strength = Color(hex: "#DDB13A")
    public static let power = Color(hex: "#E5743A")
    public static let execution = Color(hex: "#7B83EB")
    public static let primary = Color(hex: "#5B5FC7")
    public static let optimal = Color(hex: "#2E96F0")
    public static let caution = Color(hex: "#DDB13A")
    public static let alert = Color(hex: "#E5743A")

    public static func phaseColor(_ phase: PhaseID) -> Color {
        switch phase {
        case .capacity: return capacity
        case .strength: return strength
        case .power: return power
        case .execution: return execution
        }
    }

    /// Training-quality hues for the History zone badge (#630): cool → warm
    /// as the zone moves from endurance to power — the same mapping as the
    /// web's `QUALITY_COLORS` (success / info / warning / danger).
    public static func zoneColor(_ zone: ZoneQuality) -> Color {
        switch zone {
        case .power: return alert
        case .strength: return caution
        case .powerEndurance: return execution
        case .endurance: return optimal
        }
    }
}

public extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red, green, blue, alpha: UInt64
        switch cleaned.count {
        case 3:
            (red, green, blue, alpha) = (
                ((value >> 8) & 0xF) * 17,
                ((value >> 4) & 0xF) * 17,
                (value & 0xF) * 17,
                255
            )
        case 8:
            (red, green, blue, alpha) = (
                (value >> 24) & 0xFF,
                (value >> 16) & 0xFF,
                (value >> 8) & 0xFF,
                value & 0xFF
            )
        default:
            (red, green, blue, alpha) = (
                (value >> 16) & 0xFF,
                (value >> 8) & 0xFF,
                value & 0xFF,
                255
            )
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

public struct SurfaceCard<Content: View>: View {
    private let content: Content
    private let fillsHeight: Bool

    public init(fillsHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.fillsHeight = fillsHeight
    }

    public var body: some View {
        content
            .padding(SendmeterStyle.spacing)
            .frame(
                maxWidth: .infinity,
                maxHeight: fillsHeight ? .infinity : nil,
                alignment: .leading
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SendmeterStyle.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SendmeterStyle.radius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

public struct SectionLabel: View {
    let title: String
    let systemImage: String?

    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title.uppercased())
        }
        .font(.caption2.weight(.semibold))
        .tracking(1)
        .foregroundStyle(.secondary)
    }
}

public struct MetricValue: View {
    let value: String
    let unit: String?
    let color: Color

    public init(_ value: String, unit: String? = nil, color: Color = .primary) {
        self.value = value
        self.unit = unit
        self.color = color
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            if let unit {
                Text(unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

public struct PrimaryActionButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                SendmeterStyle.primary.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shared compact icon control for card-header secondary actions (#541).
/// Prefer this over a one-off `Button` + `Image` for any icon-only control so
/// the glyph size, the 44pt minimum hit target, and the pressed/disabled
/// treatment stay identical everywhere instead of drifting per screen.
///
/// - `accessibilityLabel` is required: an icon with no announced name is not
///   accessible (#541's rule). `accessibilityHint` is optional extra context
///   (e.g. "Rename or hide exercises"); `accessibilityIdentifier` is optional
///   and lets a caller (or a UI test) target the control independent of its
///   announced copy.
/// - The hit target is 44pt on both axes regardless of how small the glyph
///   renders. The frame/shape that deliver it are applied to the *button's
///   label content*, not the button wrapper — a `.frame`/`.contentShape`
///   chained after a `Button` only resizes the layout box and does not enlarge
///   the tappable region, so they sit inside the style's `makeBody`, matching
///   where `PrimaryActionButtonStyle` puts its own label treatment.
public struct CompactIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    var accessibilityIdentifier: String? = nil
    var tint: Color = SendmeterStyle.primary
    var isDisabled = false
    let action: () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        accessibilityIdentifier: String? = nil,
        tint: Color = SendmeterStyle.primary,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityIdentifier = accessibilityIdentifier
        self.tint = tint
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(CompactIconButtonStyle(tint: tint))
        .disabled(isDisabled)
        // No `.accessibilityElement(children: .ignore)` here: on a `Button`
        // (unlike a plain `Label`) it left the SF Symbol's own auto-generated
        // name as the announced label instead of the one set below, so the
        // label is set explicitly on the button.
        .accessibilityLabel(accessibilityLabel)
        .modifier(CompactIconButtonHint(hint: accessibilityHint))
        .modifier(CompactIconButtonIdentifier(identifier: accessibilityIdentifier))
    }
}

private struct CompactIconButtonHint: ViewModifier {
    let hint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(Text(hint))
        } else {
            content
        }
    }
}

private struct CompactIconButtonIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct CompactIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = SendmeterStyle.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .background(
                tint.opacity(configuration.isPressed ? 0.16 : 0.08),
                in: Circle()
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

public struct StatusPill: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 1))
    }
}

public struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SendmeterStyle.alert)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(SendmeterStyle.alert.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

public struct AppToastAction {
    public let label: String
    public let perform: () -> Void

    public init(label: String, perform: @escaping () -> Void) {
        self.label = label
        self.perform = perform
    }
}

public struct AppToastState: Identifiable {
    public let id: UUID
    public let message: String
    public let action: AppToastAction?

    public init(
        id: UUID = UUID(),
        message: String,
        action: AppToastAction? = nil
    ) {
        self.id = id
        self.message = message
        self.action = action
    }

    public var timeoutNanoseconds: UInt64 {
        ToastLifecycle.timeoutNanoseconds(hasAction: action != nil)
    }
}

public struct AppToast: View {
    let message: String
    let action: AppToastAction?
    let dismiss: () -> Void

    public init(
        message: String,
        action: AppToastAction? = nil,
        dismiss: @escaping () -> Void = {}
    ) {
        self.message = message
        self.action = action
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if let action {
                Button(action.label) {
                    dismiss()
                    action.perform()
                }
                .font(.subheadline.weight(.bold))
                .buttonStyle(.bordered)
                .tint(SendmeterStyle.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: Capsule())
        .shadow(radius: 12, y: 6)
    }
}
