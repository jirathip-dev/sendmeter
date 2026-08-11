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

    /// `foreground(_:)`'s default `cardStrong` surface is the *flat* card
    /// base — but a label near the topLeading corner of an accent-tinted
    /// `WatchCard` actually sits on `accent` painted over that base (see
    /// `WatchDesignTokens.accentCardSurface`), which is a worse surface for a
    /// same-hue label. Use this instead of `foreground(_:)` for any label at
    /// or near that corner (SL-538 round-2 review finding 2).
    static func foregroundOnAccentCard(
        _ rgb: PhaseRGB,
        accent: PhaseRGB = WatchDesignTokens.primary
    ) -> Color {
        foreground(rgb, on: WatchDesignTokens.accentCardSurface(accent))
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

/// Visual weight for `WatchIconActionButton` — mirrors the filled/outline
/// split of `WatchPrimaryButtonStyle`/`WatchSecondaryButtonStyle`, scaled down
/// to a compact icon-only footprint. Deliberately has no destructive variant:
/// Start/Stop/Save/Finish and destructive/recovery actions stay text-labeled
/// per #541's icon-vs-text rule and must never adopt this control.
enum WatchIconActionRole {
    case prominent
    case plain
}

/// Shared metrics/colour math for `WatchIconActionButton`, factored out of
/// `WatchIconActionButtonStyle` so previews can render the pressed state
/// deterministically — a `ButtonStyle`'s `configuration.isPressed` only ever
/// reflects a real touch, never something a preview can set.
private enum WatchIconActionVisuals {
    static let glyphDiameter: CGFloat = 30
    static let iconSize: CGFloat = 15

    static func fill(role: WatchIconActionRole, tint: Color, isPressed: Bool) -> Color {
        switch role {
        case .prominent: tint.opacity(isPressed ? 0.65 : 0.92)
        case .plain: tint.opacity(isPressed ? 0.22 : 0.12)
        }
    }

    static func foreground(role: WatchIconActionRole, tint: Color) -> Color {
        role == .prominent ? .white : tint
    }

    static func strokeWidth(role: WatchIconActionRole) -> CGFloat {
        role == .plain ? 1 : 0
    }
}

struct WatchIconActionButtonStyle: ButtonStyle {
    let role: WatchIconActionRole
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: WatchIconActionVisuals.iconSize, weight: .bold))
            .foregroundStyle(WatchIconActionVisuals.foreground(role: role, tint: tint))
            .frame(width: WatchIconActionVisuals.glyphDiameter, height: WatchIconActionVisuals.glyphDiameter)
            .background {
                Circle()
                    .fill(WatchIconActionVisuals.fill(role: role, tint: tint, isPressed: pressed))
                    .overlay {
                        Circle().stroke(tint.opacity(0.5), lineWidth: WatchIconActionVisuals.strokeWidth(role: role))
                    }
            }
            .frame(
                minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
                minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
            )
            .opacity(pressed ? 0.84 : 1)
            .contentShape(Rectangle())
    }
}

/// Compact circular icon-only action control (#541 slice 1). The painted
/// glyph is a small `glyphDiameter` circle, but the tappable frame is always
/// padded out to `WatchDesignTokens.minimumHitTarget` — the same "small
/// visually, full-size to the touch" shape as `WatchSecondaryButtonStyle`.
/// Reserved for secondary/navigation actions; Start/Stop/Save/Finish and
/// destructive/recovery actions keep their explicit text labels.
struct WatchIconActionButton: View {
    let systemImage: String
    var role: WatchIconActionRole = .plain
    var tint: Color = WatchPalette.primary
    /// Required, not defaulted: an icon-only control has no text fallback for
    /// VoiceOver, so a caller cannot construct one without stating what it does.
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(WatchIconActionButtonStyle(role: role, tint: tint))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityLabel(accessibilityLabel)
        .watchAccessibilityHint(accessibilityHint)
    }
}

struct WatchPageControl: View {
    let selection: Int
    let labels: [String]
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.indices, id: \.self) { index in
                WatchPageControlItem(
                    label: labels[index],
                    isSelected: index == selection,
                    action: { onSelect(index) }
                )
            }
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .background {
            Capsule()
                .fill(WatchPalette.card.opacity(0.9))
                .padding(.vertical, 4)
        }
    }
}

private struct WatchPageControlItem: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    private var labelWeight: Font.Weight { isSelected ? .bold : .medium }
    private var foreground: Color { isSelected ? WatchPalette.textPrimary : WatchPalette.textTertiary }
    private var fill: Color { isSelected ? WatchPalette.primary.opacity(0.72) : Color.white.opacity(0.06) }
    private var strokeOpacity: Double { isSelected ? 0.24 : 0.1 }

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(fill)
                    .overlay(Capsule().stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.7))
                Text(label)
                    .font(.system(size: 9, weight: labelWeight, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
            maxWidth: .infinity,
            minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
        )
        .foregroundStyle(foreground)
        .contentShape(Rectangle())
        .accessibilityLabel("Show \(label)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Compact icon-navigation item (#541 slice 1) — a single destination in an
/// icon-only nav row, with the same selected/unselected visual language as
/// `WatchPageControlItem` but an SF Symbol in place of a text label. The
/// #539 replacement for the text-heavy Status/Actions pill is expected to
/// lay a row of these out; this issue adds the item only, not that row.
struct WatchIconNavItem: View {
    let systemImage: String
    let isSelected: Bool
    /// Required, not defaulted: an icon-only control has no text fallback for
    /// VoiceOver, so a caller cannot construct one without stating what it does.
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    let action: () -> Void

    private var iconWeight: Font.Weight { isSelected ? .bold : .medium }
    private var foreground: Color { isSelected ? WatchPalette.textPrimary : WatchPalette.textTertiary }
    private var fill: Color { isSelected ? WatchPalette.primary.opacity(0.72) : Color.white.opacity(0.06) }
    private var strokeOpacity: Double { isSelected ? 0.24 : 0.1 }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .overlay(Circle().stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.7))
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: iconWeight))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
            minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
        )
        .foregroundStyle(foreground)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
        .watchAccessibilityHint(accessibilityHint)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    /// `accessibilityHint(_:)` has no overload that accepts `nil`; this
    /// applies one only when the caller actually supplied non-empty text.
    @ViewBuilder
    func watchAccessibilityHint(_ hint: String?) -> some View {
        if let hint, !hint.isEmpty {
            accessibilityHint(hint)
        } else {
            self
        }
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

#if DEBUG
/// The two screens the layout has to hold, in points: the smallest supported
/// watch and the largest — same pinned-frame approach as
/// `WorkoutLiveView`'s preview screens (the `#Preview` macro ignores
/// `previewDevice`; it takes the device from the Canvas picker).
private enum WatchIconPreviewScreen {
    /// Apple Watch SE / Series 4-6, 40mm.
    static let mm40 = CGSize(width: 162, height: 197)
    /// Apple Watch Ultra / Ultra 2, 49mm.
    static let mm49 = CGSize(width: 205, height: 251)
}

/// Preview-only: renders `WatchIconActionButton`'s exact fill/foreground math
/// for an explicit pressed/disabled state. `ButtonStyle.configuration.isPressed`
/// only ever reflects a real touch, which a preview canvas can't produce, so
/// this reuses the same `WatchIconActionVisuals` math outside a live `Button`.
private struct WatchIconActionSwatch: View {
    let systemImage: String
    let role: WatchIconActionRole
    let tint: Color
    var isPressed = false
    var isDisabled = false
    let caption: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: WatchIconActionVisuals.iconSize, weight: .bold))
                .foregroundStyle(WatchIconActionVisuals.foreground(role: role, tint: tint))
                .frame(width: WatchIconActionVisuals.glyphDiameter, height: WatchIconActionVisuals.glyphDiameter)
                .background {
                    Circle()
                        .fill(WatchIconActionVisuals.fill(role: role, tint: tint, isPressed: isPressed))
                        .overlay {
                            Circle().stroke(
                                tint.opacity(0.5),
                                lineWidth: WatchIconActionVisuals.strokeWidth(role: role)
                            )
                        }
                }
                .frame(
                    minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
                    minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
                )
                .opacity(isDisabled ? 0.4 : (isPressed ? 0.84 : 1))
                // Preview-only: outlines the tappable frame so the padding
                // between the small glyph and the full hit target (AC2) is
                // visible at a glance, not just true in code.
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                }
            Text(caption)
                .font(.system(size: 8, design: .rounded))
                .foregroundStyle(WatchPalette.textSecondary)
        }
    }
}

private func watchIconActionGallery(_ size: CGSize) -> some View {
    ScrollView {
        VStack(spacing: 10) {
            WatchEyebrow(text: "Prominent")
            HStack(spacing: 8) {
                WatchIconActionSwatch(
                    systemImage: "bell.fill", role: .prominent, tint: WatchPalette.primary,
                    caption: "Normal"
                )
                WatchIconActionSwatch(
                    systemImage: "bell.fill", role: .prominent, tint: WatchPalette.primary,
                    isPressed: true, caption: "Pressed"
                )
                WatchIconActionSwatch(
                    systemImage: "bell.fill", role: .prominent, tint: WatchPalette.primary,
                    isDisabled: true, caption: "Disabled"
                )
            }
            WatchEyebrow(text: "Plain")
            HStack(spacing: 8) {
                WatchIconActionSwatch(
                    systemImage: "gearshape.fill", role: .plain, tint: WatchPalette.secondary,
                    caption: "Normal"
                )
                WatchIconActionSwatch(
                    systemImage: "gearshape.fill", role: .plain, tint: WatchPalette.secondary,
                    isPressed: true, caption: "Pressed"
                )
                WatchIconActionSwatch(
                    systemImage: "gearshape.fill", role: .plain, tint: WatchPalette.secondary,
                    isDisabled: true, caption: "Disabled"
                )
            }
            // Exercises the real initializer (not just the swatch math)
            // wired to a no-op action.
            WatchIconActionButton(
                systemImage: "arrow.clockwise",
                role: .plain,
                tint: WatchPalette.warning,
                accessibilityLabel: "Retry sync",
                accessibilityHint: "Retries the last failed upload",
                action: {}
            )
        }
        .padding(10)
    }
    .frame(width: size.width, height: size.height)
    .watchCanvas()
    .clipped()
}

#Preview("Icon action · 40mm") {
    watchIconActionGallery(WatchIconPreviewScreen.mm40)
}

#Preview("Icon action · 49mm") {
    watchIconActionGallery(WatchIconPreviewScreen.mm49)
}

#Preview("Icon action · 40mm · accessibility") {
    watchIconActionGallery(WatchIconPreviewScreen.mm40)
        .environment(\.dynamicTypeSize, .accessibility3)
}

private func watchIconNavGallery(_ size: CGSize) -> some View {
    VStack(spacing: 14) {
        WatchEyebrow(text: "First item selected")
        HStack(spacing: 8) {
            WatchIconNavItem(systemImage: "heart.fill", isSelected: true, accessibilityLabel: "Status", action: {})
            WatchIconNavItem(systemImage: "bolt.fill", isSelected: false, accessibilityLabel: "Actions", action: {})
        }
        WatchEyebrow(text: "Second item selected")
        HStack(spacing: 8) {
            WatchIconNavItem(systemImage: "heart.fill", isSelected: false, accessibilityLabel: "Status", action: {})
            WatchIconNavItem(systemImage: "bolt.fill", isSelected: true, accessibilityLabel: "Actions", action: {})
        }
    }
    .padding(10)
    .frame(width: size.width, height: size.height)
    .watchCanvas()
    .clipped()
}

#Preview("Icon nav · 40mm") {
    watchIconNavGallery(WatchIconPreviewScreen.mm40)
}

#Preview("Icon nav · 49mm") {
    watchIconNavGallery(WatchIconPreviewScreen.mm49)
}

#Preview("Icon nav · 40mm · accessibility") {
    watchIconNavGallery(WatchIconPreviewScreen.mm40)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
