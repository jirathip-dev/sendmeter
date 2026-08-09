import SendLogWatchCore
import SwiftUI

/// Native watch design language. Keep all SwiftUI-only styling here so
/// production screens share the same semantic vocabulary and no state gets a
/// one-off colour, corner radius or hit target.
enum WatchPalette {
    static func color(_ rgb: PhaseRGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Decorative semantic accents have one reduced-luminance conversion point
    /// shared by cards, strokes and gradients. Semantic text and symbols must
    /// use `foreground` below instead: dimming a sparse foreground pixel to
    /// 42% makes small labels and icons disappear in Always-On.
    static func accent(_ rgb: PhaseRGB, reducedLuminance: Bool = false) -> Color {
        let adjusted = WatchDesignTokens.accent(rgb, reducedLuminance: reducedLuminance)
        return color(adjusted)
    }

    /// Readable semantic foregrounds stay at full emission and are nudged only
    /// when needed to meet AA against the lightest shared card surface. The
    /// same resolver is used by the app and widget copies of the palette.
    static func foreground(_ rgb: PhaseRGB, on surface: PhaseRGB = WatchDesignTokens.cardStrong) -> Color {
        color(WatchDesignTokens.readableForeground(rgb, on: surface))
    }

    static let canvas = color(WatchDesignTokens.canvas)
    static let canvasRaised = color(WatchDesignTokens.canvasRaised)
    static let card = color(WatchDesignTokens.card)
    static let cardStrong = color(WatchDesignTokens.cardStrong)
    static let primary = color(WatchDesignTokens.primary)
    static let secondary = color(WatchDesignTokens.secondary)
    static let success = color(WatchDesignTokens.success)
    static let warning = color(WatchDesignTokens.warning)
    static let danger = color(WatchDesignTokens.danger)
    static let force = color(WatchDesignTokens.force)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.48)

    private static func token(for state: WatchVisualState) -> PhaseRGB {
        switch state {
        case .ready, .success: WatchDesignTokens.success
        case .syncing: WatchDesignTokens.secondary
        case .offline, .cached, .stale, .warning: WatchDesignTokens.warning
        case .danger: WatchDesignTokens.danger
        }
    }

    static func foreground(for state: WatchVisualState) -> Color {
        foreground(token(for: state))
    }

    static func accent(for state: WatchVisualState, reducedLuminance: Bool) -> Color {
        accent(token(for: state), reducedLuminance: reducedLuminance)
    }

    static func screenGradient(luminanceReduced: Bool) -> LinearGradient {
        if luminanceReduced {
            return LinearGradient(
                colors: [canvas, canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [canvasRaised, canvas, canvas],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func cardGradient(accent: Color?, luminanceReduced: Bool) -> LinearGradient {
        let base = luminanceReduced ? card : cardStrong
        guard let accent, !luminanceReduced else {
            return LinearGradient(colors: [base, base], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(
            colors: [accent.opacity(0.24), base, card],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func phaseGradient(_ color: Color, luminanceReduced: Bool) -> LinearGradient {
        let opacity = WatchDesignTokens.accentScale(reducedLuminance: luminanceReduced)
        return LinearGradient(
            colors: [color.opacity(opacity), color.opacity(opacity * 0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct WatchCard<Content: View>: View {
    private let accent: Color?
    private let content: () -> Content
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    init(accent: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.accent = accent
        self.content = content
    }

    var body: some View {
        content()
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(WatchPalette.cardGradient(accent: accent, luminanceReduced: isLuminanceReduced))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                accent?.opacity(
                                    (isLuminanceReduced ? 0.38 : 0.65)
                                        * WatchDesignTokens.accentScale(reducedLuminance: isLuminanceReduced)
                                )
                                    ?? Color.white.opacity(isLuminanceReduced ? 0.12 : 0.18),
                                lineWidth: 1
                            )
                    }
            }
            .overlay(alignment: .topLeading) {
                if let accent, !isLuminanceReduced {
                    Capsule()
                        .fill(accent)
                        .frame(width: 30, height: 2)
                        .padding(.leading, 14)
                        .padding(.top, 1)
                }
            }
            .shadow(
                color: isLuminanceReduced ? .clear : .black.opacity(0.34),
                radius: isLuminanceReduced ? 0 : 8,
                y: isLuminanceReduced ? 0 : 3
            )
    }
}

struct WatchEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.9)
            .foregroundStyle(WatchPalette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityHidden(true)
    }
}

struct WatchStateChip: View {
    let state: WatchVisualState
    var title: String? = nil
    var compact = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var tint: Color {
        WatchPalette.foreground(for: state)
    }
    private var fillTint: Color {
        WatchPalette.accent(for: state, reducedLuminance: isLuminanceReduced)
    }
    private var displayTitle: String { title ?? state.label }

    var body: some View {
        Label(displayTitle, systemImage: state.symbolName)
            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, compact ? 7 : 9)
            .frame(minHeight: compact ? 24 : 28)
            .background(Capsule().fill(fillTint.opacity(0.16)))
            .overlay(Capsule().stroke(fillTint.opacity(0.42), lineWidth: 0.8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayTitle)
            .accessibilityValue(state.label)
            .accessibilityIdentifier("watch-state-\(state.rawValue)")
    }
}

struct WatchStateBanner: View {
    let state: WatchVisualState
    let title: String
    let message: String?
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var actionDisabled = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var tint: Color { WatchPalette.foreground(for: state) }
    private var accent: Color {
        WatchPalette.accent(for: state, reducedLuminance: isLuminanceReduced)
    }

    var body: some View {
        WatchCard(accent: accent) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(WatchPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .buttonStyle(WatchSecondaryButtonStyle(tint: tint))
                            .disabled(actionDisabled)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("watch-banner-\(state.rawValue)")
    }
}

struct WatchPrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.65 : 0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    }
            }
            .opacity(configuration.isPressed ? 0.84 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct WatchSecondaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .frame(
                minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
                minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
            )
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.22 : 0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(tint.opacity(0.5), lineWidth: 1)
                    }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WatchPageControl: View {
    let selection: Int
    let labels: [String]
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Button {
                    onSelect(index)
                } label: {
                    Text(label)
                        .font(.system(size: 10, weight: index == selection ? .bold : .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(
                            maxWidth: .infinity,
                            minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
                            minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == selection ? WatchPalette.textPrimary : WatchPalette.textTertiary)
                .background {
                    Capsule()
                        .fill(index == selection ? WatchPalette.primary.opacity(0.72) : Color.white.opacity(0.06))
                        .overlay(Capsule().stroke(Color.white.opacity(index == selection ? 0.24 : 0.1), lineWidth: 0.7))
                }
                .accessibilityLabel("Show \(label)")
                .accessibilityValue(index == selection ? "Selected" : "Not selected")
                .accessibilityAddTraits(index == selection ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(WatchPalette.card.opacity(0.9)))
        .frame(maxWidth: .infinity)
    }
}

struct WatchLoadingState: View {
    let title: String
    var message: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var tint: Color { WatchPalette.foreground(WatchDesignTokens.secondary) }
    private var accent: Color {
        WatchPalette.accent(WatchDesignTokens.secondary, reducedLuminance: isLuminanceReduced)
    }

    var body: some View {
        WatchCard(accent: accent) {
            HStack(spacing: 9) {
                if reduceMotion {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)
                } else {
                    ProgressView()
                        .tint(tint)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                    if let message {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

extension View {
    /// Shared OLED canvas. `isLuminanceReduced` intentionally removes the
    /// gradient so Always-On gets a flat, dim-safe fallback.
    func watchCanvas() -> some View {
        modifier(WatchCanvasModifier())
    }
}

private struct WatchCanvasModifier: ViewModifier {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func body(content: Content) -> some View {
        content
            .background {
                WatchPalette.screenGradient(luminanceReduced: isLuminanceReduced)
                    .ignoresSafeArea()
            }
    }
}
