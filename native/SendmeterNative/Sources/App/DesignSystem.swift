import SendmeterCore
import SwiftUI

public enum SendmeterStyle {
    public static let radius: CGFloat = 18
    public static let spacing: CGFloat = 16

    /// Shared treatment for the app's glanceable metric values. The semantic
    /// font keeps the number tied to Dynamic Type; tightening and the
    /// single-line scale keep metric values visually compact.
    public static var heroMetric: HeroMetricModifier { HeroMetricModifier() }

    /// Dynamic-Type-aware display treatment for active countdowns. Callers
    /// supply their existing context size so a fullscreen timer stays larger
    /// than a card metric without freezing it at one accessibility size.
    public static func countdownMetric(baseSize: CGFloat) -> CountdownMetricModifier {
        CountdownMetricModifier(baseSize: baseSize)
    }

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

public struct HeroMetricModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .monospacedDigit()
            .allowsTightening(true)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }
}

public struct CountdownMetricModifier: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 0

    public init(baseSize: CGFloat) {
        _displaySize = ScaledMetric(wrappedValue: baseSize, relativeTo: .largeTitle)
    }

    public func body(content: Content) -> some View {
        content
            .font(.system(size: displaySize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .allowsTightening(true)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
    }
}

public extension SendConditionsColorBand {
    /// Semantic native color for a Send Conditions score/percentile band —
    /// shared by the summary card and detail sheet so their badges cannot
    /// drift (web `percentileColor` / `sendScoreColor` hue families).
    var color: Color {
        switch self {
        case .optimal: return SendmeterStyle.optimal
        case .caution: return SendmeterStyle.caution
        case .alert: return SendmeterStyle.alert
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

/// Shared product empty state for data surfaces that have finished loading but
/// have nothing useful to show yet. The illustration deliberately reuses the
/// shipped splash art so an empty screen still feels like Sendmeter, rather
/// than falling back to a framework placeholder or a bare SF Symbol.
public struct ProductEmptyState: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    let compact: Bool

    public init(
        title: String,
        message: String,
        actionTitle: String,
        compact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.compact = compact
        self.action = action
    }

    public var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            illustration

            VStack(spacing: 4) {
                Text(title)
                    .font(compact ? .headline : .title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(actionTitle, action: action)
                .hapticButtonStyle(PrimaryActionButtonStyle())
                .frame(maxWidth: compact ? .infinity : 280)
        }
        .padding(.horizontal, compact ? 4 : 20)
        .padding(.vertical, compact ? 4 : 24)
        .frame(maxWidth: .infinity)
    }

    private var illustration: some View {
        ZStack {
            Image("SplashCaveBackground")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.42)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipped()

            Image("SplashKangaroo")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 82 : 122)
                .shadow(color: .black.opacity(0.34), radius: 10, y: 7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 82 : 118)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
        .accessibilityHidden(true)
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
                .modifier(SendmeterStyle.heroMetric)
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
            .hapticTap(structuralHapticLevel)
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

extension PrimaryActionButtonStyle: StructuralHapticStyle {
    public var structuralHapticLevel: HapticTapLevel { .normal }
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
            .hapticButtonStyle(.plain)
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
                .hapticButtonStyle(.bordered)
                .tint(SendmeterStyle.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: Capsule())
        .shadow(radius: 12, y: 6)
    }
}
