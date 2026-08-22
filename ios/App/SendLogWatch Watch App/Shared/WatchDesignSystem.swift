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
    /// Override for the tightest cards on the smallest watch — the readiness
    /// card (#539 round-1 review F1) needed a few points back after its sync
    /// line went from suppressed-under-fixtures to always rendered. Every
    /// other call site keeps the default so this is not a visual-rhythm
    /// change app-wide.
    private let padding: CGFloat
    private let content: () -> Content
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    init(accent: Color? = nil, padding: CGFloat = 11, @ViewBuilder content: @escaping () -> Content) {
        self.accent = accent
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
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

/// Canonical SF Symbol per navigation/secondary-action concept (#541). Call
/// sites read from here instead of inlining a symbol string, so the mapping
/// can't drift between HomeView's switcher, #537's Force setup, and future
/// `WatchIconButton` consumers. Entries commented "not yet wired" exist so a
/// future call site has one place to look rather than guessing a new glyph.
enum WatchIconSymbol {
    static let status = "chart.bar.fill"
    static let actions = "bolt.fill"
    static let force = "scalemass" // matches ActionsView's Force Gauge row
    static let workout = "figure.climbing" // matches ActionsView's Climb Workout row
    static let forceContext = "slider.horizontal.3" // Force exercise/protocol chooser
    static let disconnect = "xmark" // Progressor disconnect action
    static let refresh = "arrow.triangle.2.circlepath" // matches WatchVisualState.syncing
    static let history = "clock.arrow.circlepath" // matches WatchVisualState.cached
    // Finishing an activity is a checkered flag — shared by the live
    // Workout's finish control and Force's finish-session control so the
    // concept reads identically on both screens. Deliberately NOT the
    // in-row boulder stop glyph (stop.fill): those controls end different
    // scopes (the whole workout vs. one boulder) and sharing a glyph would
    // make them ambiguous (#580 scope 1).
    static let finishWorkout = "flag.checkered"
    static let settings = "gearshape.fill" // not yet wired to a call site
    static let connection = "antenna.radiowaves.left.and.right" // not yet wired
    static let protocolPicker = "list.bullet.clipboard" // not yet wired (Force protocol chooser)
}

/// Shared compact icon control for Watch navigation and secondary actions —
/// the primitive #541 (icon-first design system) asks for. Any icon-only
/// control on the watch (Home's Status/Actions switcher below, #537's Force
/// setup entry points, future secondary actions) should be built from this
/// rather than a one-off `Button` + `Image`, so the visible glyph size, the
/// watchOS-minimum hit target, and the selected/unselected/pressed/disabled
/// treatment stay identical everywhere instead of drifting per screen.
///
/// - `accessibilityLabel` is required: an icon with no announced name is not
///   accessible (#541's rule). `accessibilityHint` is optional extra context
///   ("Opens force gauge setup"); `accessibilityIdentifier` is optional and
///   lets a caller (or a UI test) target the control independent of its
///   announced copy.
/// - The hit target is `WatchDesignTokens.minimumHitTarget` (44pt) on both
///   axes regardless of how small `systemImage` renders. The frame/shape that
///   deliver it are applied to the *button's label content*, not the button
///   wrapper — a `.frame`/`.contentShape` chained after a `Button` only
///   resizes the layout box around it and does not enlarge the tappable
///   region, so it has to sit inside, matching where
///   `WatchPrimaryButtonStyle`/`WatchSecondaryButtonStyle` put theirs
///   (`configuration.label`).
/// - `isSelected` reuses the same fill/opacity language as
///   `WatchStateChip`/segmented tabs elsewhere for an active state, and
///   `tint` takes a `PhaseRGB` (not a `Color`) so the selected fill can run
///   through `WatchPalette.accent(_:reducedLuminance:)` — the file's one
///   shared Always-On dimming conversion — like every other decorative
///   accent here.
/// - Pressed and disabled rendering belongs to the primitive's button style,
///   not to each caller. The disabled state is read from SwiftUI's
///   `isEnabled` environment, so both `.disabled(true)` and the explicit
///   `isDisabled` convenience below get the same muted treatment.
struct WatchIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    var accessibilityIdentifier: String? = nil
    var isSelected: Bool = false
    var tint: PhaseRGB = WatchDesignTokens.primary
    /// Secondary actions such as disconnect need their semantic colour even
    /// when they are not selected; navigation controls stay tertiary when
    /// inactive so the compact Home switcher does not become another pill.
    var usesTintWhenUnselected = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(
            WatchIconButtonStyle(
                isSelected: isSelected,
                tint: tint,
                usesTintWhenUnselected: usesTintWhenUnselected
            )
        )
        .disabled(isDisabled)
        // No `.accessibilityElement(children: .ignore)` here: on a `Button`
        // (unlike the plain `Label` `WatchStateChip` uses) it left the SF
        // Symbol's own auto-generated name ("Chart Column", "Flash") as the
        // announced label instead of the one set below, regardless of
        // modifier order — omitting the call is what fixed it.
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(WatchIconButtonHint(hint: accessibilityHint))
        .modifier(WatchIconButtonIdentifier(identifier: accessibilityIdentifier))
    }
}

/// The style owns the entire interactive label, including the 44pt frame.
/// Keeping this inside `ButtonStyle.makeBody` is the important part of the
/// hit-target contract: a frame/content shape chained after `Button` only
/// grows its layout box, not the region that receives the tap.
private struct WatchIconButtonStyle: ButtonStyle {
    let isSelected: Bool
    let tint: PhaseRGB
    let usesTintWhenUnselected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func makeBody(configuration: Configuration) -> some View {
        let resolvedTint = WatchPalette.accent(tint, reducedLuminance: isLuminanceReduced)
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: WatchIconButtonVisuals.iconSize, weight: .bold))
            .foregroundStyle(
                WatchIconButtonVisuals.foreground(
                    isSelected: isSelected,
                    tint: tint,
                    usesTintWhenUnselected: usesTintWhenUnselected
                )
            )
            .frame(
                width: WatchIconButtonVisuals.visibleDiameter,
                height: WatchIconButtonVisuals.visibleDiameter
            )
            .background {
                Circle()
                    .fill(
                        WatchIconButtonVisuals.fill(
                            isSelected: isSelected,
                            tint: resolvedTint,
                            isPressed: pressed,
                            isEnabled: isEnabled
                        )
                    )
                    .overlay {
                        Circle().stroke(
                            WatchIconButtonVisuals.stroke(
                                isSelected: isSelected,
                                isPressed: pressed,
                                isEnabled: isEnabled
                            ),
                            lineWidth: WatchIconButtonVisuals.strokeWidth(
                                isPressed: pressed,
                                isEnabled: isEnabled
                            )
                        )
                    }
            }
            // Inside the button's label, not chained after `Button` — see
            // the doc comment above (#569 / #539 review F2).
            .frame(
                minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
                minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
            )
            .contentShape(Rectangle())
            .opacity(
                WatchIconButtonVisuals.opacity(isPressed: pressed, isEnabled: isEnabled)
            )
    }
}

/// Shared visual math for the live control and its deterministic preview/
/// screenshot swatches. The swatches are not a second control; they make the
/// pressed state (which a Canvas or fixture cannot hold with a real touch)
/// inspectable while keeping the production button and the evidence in lockstep.
private enum WatchIconButtonVisuals {
    static let visibleDiameter: CGFloat = 30
    static let iconSize: CGFloat = 14

    static func foreground(
        isSelected: Bool,
        tint: PhaseRGB,
        usesTintWhenUnselected: Bool
    ) -> Color {
        if isSelected {
            return WatchPalette.textPrimary
        }
        return usesTintWhenUnselected ? WatchPalette.foreground(tint) : WatchPalette.textTertiary
    }

    static func fill(
        isSelected: Bool,
        tint: Color,
        isPressed: Bool,
        isEnabled: Bool
    ) -> Color {
        guard isEnabled else {
            return Color.white.opacity(isSelected ? 0.08 : 0.04)
        }
        if isSelected {
            return tint.opacity(isPressed ? 0.9 : 0.72)
        }
        return Color.white.opacity(isPressed ? 0.22 : 0.08)
    }

    static func stroke(isSelected: Bool, isPressed: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return Color.white.opacity(0.06) }
        return Color.white.opacity(
            isPressed ? (isSelected ? 0.42 : 0.24) : (isSelected ? 0.24 : 0.1)
        )
    }

    static func strokeWidth(isPressed: Bool, isEnabled: Bool) -> CGFloat {
        isEnabled ? (isPressed ? 1.1 : 0.7) : 0.6
    }

    static func opacity(isPressed: Bool, isEnabled: Bool) -> Double {
        guard isEnabled else { return 0.38 }
        return isPressed ? 0.84 : 1
    }
}

/// `accessibilityHint` is optional on `WatchIconButton`; SwiftUI has no
/// conditional-modifier shorthand, so this keeps the `if let` out of the
/// button's own body.
private struct WatchIconButtonHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

/// Same shape as `WatchIconButtonHint`, for the optional identifier.
private struct WatchIconButtonIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

extension View {
    /// The watch's one compact finish/confirm affordance (SL-580 follow-up):
    /// a small in-design card over a blocking scrim, replacing the
    /// full-screen system `confirmationDialog` (too big on 40mm, and its red
    /// destructive treatment read as alarming for safe, expected actions).
    /// ONE implementation on purpose — the Workout finish and the Force
    /// session finish share the same checkered-flag trigger glyph, so they
    /// must also share the exact ask-first behavior; a second copy is how
    /// the two would drift.
    ///
    /// Contract (mirrors what the system dialog provided):
    /// - `onConfirm` is reachable only through the explicit confirm button —
    ///   the compact destructive trigger can never complete on one tap.
    /// - The scrim blocks every control underneath and tapping it cancels
    ///   (always safe); the presenting content also leaves the accessibility
    ///   tree, so VoiceOver focus cannot land on covered controls, and the
    ///   card takes the escape gesture as the scrim-tap's VoiceOver
    ///   equivalent.
    /// - No animation on present/dismiss — nothing for Reduce Motion to
    ///   reduce; the card chrome flows through `WatchCard`'s Always-On path.
    func watchFinishConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmIdentifier: String,
        confirmHint: String,
        cancelIdentifier: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        self
            .accessibilityHidden(isPresented.wrappedValue)
            .overlay {
                if isPresented.wrappedValue {
                    WatchFinishConfirmationCard(
                        isPresented: isPresented,
                        title: title,
                        message: message,
                        confirmIdentifier: confirmIdentifier,
                        confirmHint: confirmHint,
                        cancelIdentifier: cancelIdentifier,
                        onConfirm: onConfirm
                    )
                }
            }
    }
}

private struct WatchFinishConfirmationCard: View {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let confirmIdentifier: String
    let confirmHint: String
    let cancelIdentifier: String
    let onConfirm: () -> Void
    /// The user's REAL size — read before the `.xxLarge` cap below, so the
    /// accessibility layout branch keys off what the user actually chose.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            // Deep enough that the screen behind reads as background in both
            // full and reduced luminance; the card on top stays the focus.
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .accessibilityHidden(true)
            WatchCard(accent: WatchPalette.secondary) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    // At accessibility sizes the supporting line is dropped
                    // (the title carries the decision and the confirm hint
                    // repeats the consequence) — its rows are what the
                    // stacked full-width buttons below need to fit 40mm.
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(message)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(WatchPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                }
            }
            .padding(.horizontal, 6)
            // VoiceOver treats the card as a modal so focus stays on the
            // confirmation instead of the dimmed controls behind it; escape
            // (two-finger scrub) is the scrim-tap's VoiceOver equivalent.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { isPresented = false }
        }
        // Bounded like the live screen's readouts: the compact card plus two
        // 44pt buttons must fit a 40mm viewport with no scroll fallback, so
        // the visual scale stops at .xxLarge while the full VoiceOver labels
        // and hints stay intact.
        .dynamicTypeSize(.medium ... .xxLarge)
    }

    /// Side by side at normal sizes; STACKED full-width at accessibility
    /// sizes (#588 review F1): in the row layout the two labels compete for
    /// ~128pt of 40mm card width, and at accessibility scale the confirm
    /// title compressed past `minimumScaleFactor` into a truncated "Fi…" on
    /// the app's one irreversible confirmation. Stacking removes the
    /// compression entirely — each button gets the full row — and the
    /// screenshot suite asserts the stacked geometry at accessibility size.
    @ViewBuilder
    private var actions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 6) {
                confirmButton
                cancelButton
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 6) {
                cancelButton
                confirmButton
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { isPresented = false }
            .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.textSecondary))
            // One line each in the tight side-by-side row on 40mm, scaling
            // down a step instead of hyphenating when the width demands it.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityIdentifier(cancelIdentifier)
            .accessibilityHint("Cancels without finishing")
    }

    private var confirmButton: some View {
        Button("Finish") {
            isPresented = false
            onConfirm()
        }
        .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.secondary))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityIdentifier(confirmIdentifier)
        .accessibilityHint(confirmHint)
    }
}

/// Shared icon glyph for a compact `NavigationLink` label. `WatchIconButton`
/// above is the single interactive primitive for icon *actions*; a
/// `NavigationLink` (for example Force's context chooser) cannot use a
/// `Button`-based primitive, so this provides the same compact circular label
/// content for a caller-owned link. The containing link owns the required
/// accessibility label/hint and the glyph is hidden from VoiceOver so it does
/// not announce its SF Symbol name a second time.
///
/// The visible circle and the 44pt hit frame reuse `WatchIconButtonVisuals` —
/// the exact math `WatchIconButton` renders with — so a nav-link icon stays
/// visually identical to the interactive icon primitive's resting state
/// instead of a per-screen circle/stroke copy (#541). `size`/`weight`/
/// `foreground` default to the single current call site (Force's context
/// chooser) and are overridable for future links.
struct WatchIconGlyph: View {
    let systemImage: String
    var size: CGFloat = 14
    var weight: Font.Weight = .bold
    var foreground: Color = WatchPalette.textSecondary
    var tint: PhaseRGB = WatchDesignTokens.primary
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let resolvedTint = WatchPalette.accent(tint, reducedLuminance: isLuminanceReduced)
        Image(systemName: systemImage)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(foreground)
            .frame(
                width: WatchIconButtonVisuals.visibleDiameter,
                height: WatchIconButtonVisuals.visibleDiameter
            )
            .background {
                Circle()
                    .fill(
                        WatchIconButtonVisuals.fill(
                            isSelected: false,
                            tint: resolvedTint,
                            isPressed: false,
                            isEnabled: true
                        )
                    )
                    .overlay {
                        Circle().stroke(
                            WatchIconButtonVisuals.stroke(
                                isSelected: false,
                                isPressed: false,
                                isEnabled: true
                            ),
                            lineWidth: WatchIconButtonVisuals.strokeWidth(
                                isPressed: false,
                                isEnabled: true
                            )
                        )
                    }
            }
            // Inside the link's label, matching the shared primitives'
            // hit-target contract (a frame after the link only grows its
            // layout box, not the tappable region).
            .frame(
                minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
                minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
            )
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

/// Deterministic gallery used by the screenshot target and the Canvas. It
/// deliberately exercises the same `WatchIconButton` used by Home and Force;
/// only the pressed swatch is static because a preview cannot hold a real
/// touch. Fixture-only captions and section headers are intentionally omitted
/// so the actual 44pt controls stay inside the smallest watch viewport; their
/// labels, identifiers, and visible state styling keep the matrix deterministic.
/// This is foundation coverage, not a production destination.
struct WatchIconPrimitiveFixtureView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                LazyVGrid(
                    // Three 44pt cells plus two 2pt gaps fit inside the
                    // 40mm content width after the 4pt horizontal inset.
                    columns: [
                        GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                    ],
                    spacing: 2
                ) {
                    WatchIconButton(
                        systemImage: "bell.fill",
                        accessibilityLabel: "Normal icon action",
                        accessibilityHint: "Runs the secondary action",
                        accessibilityIdentifier: "icon-action-normal",
                        action: {}
                    )
                    WatchIconButtonSwatch(
                        systemImage: "bell.fill",
                        accessibilityLabel: "Pressed icon action",
                        accessibilityIdentifier: "icon-action-pressed",
                        isPressed: true
                    )
                    WatchIconButton(
                        systemImage: "bell.fill",
                        accessibilityLabel: "Disabled icon action",
                        accessibilityIdentifier: "icon-action-disabled",
                        isDisabled: true,
                        action: {}
                    )
                }

                HStack(spacing: 2) {
                    WatchIconButton(
                        systemImage: WatchIconSymbol.status,
                        accessibilityLabel: "Show status",
                        accessibilityHint: "Displays today's readiness",
                        accessibilityIdentifier: "icon-nav-unselected",
                        action: {}
                    )
                    WatchIconButton(
                        systemImage: WatchIconSymbol.actions,
                        accessibilityLabel: "Show actions",
                        accessibilityHint: "Displays Force and workout actions",
                        accessibilityIdentifier: "icon-nav-selected",
                        isSelected: true,
                        tint: WatchDesignTokens.secondary,
                        action: {}
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("icon-primitives-viewport")
        .watchCanvas()
    }
}

/// Preview-only pressed-state evidence. `WatchIconButton` owns all interactive
/// states; this view only calls the shared visual math so a held touch can be
/// reviewed deterministically in Canvas and in the screenshot fixture.
private struct WatchIconButtonSwatch: View {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    var isPressed = false
    var isSelected = false
    var tint: PhaseRGB = WatchDesignTokens.primary
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let resolvedTint = WatchPalette.accent(tint, reducedLuminance: isLuminanceReduced)
        Image(systemName: systemImage)
            .font(.system(size: WatchIconButtonVisuals.iconSize, weight: .bold))
            .foregroundStyle(
                WatchIconButtonVisuals.foreground(
                    isSelected: isSelected,
                    tint: tint,
                    usesTintWhenUnselected: false
                )
            )
            .frame(
                width: WatchIconButtonVisuals.visibleDiameter,
                height: WatchIconButtonVisuals.visibleDiameter
            )
            .background {
                Circle()
                    .fill(
                        WatchIconButtonVisuals.fill(
                            isSelected: isSelected,
                            tint: resolvedTint,
                            isPressed: isPressed,
                            isEnabled: true
                        )
                    )
                    .overlay {
                        Circle().stroke(
                            WatchIconButtonVisuals.stroke(
                                isSelected: isSelected,
                                isPressed: isPressed,
                                isEnabled: true
                            ),
                            lineWidth: WatchIconButtonVisuals.strokeWidth(
                                isPressed: isPressed,
                                isEnabled: true
                            )
                        )
                    }
            }
            .frame(
                minWidth: CGFloat(WatchDesignTokens.minimumHitTarget),
                minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
            )
            .contentShape(Rectangle())
            .opacity(WatchIconButtonVisuals.opacity(isPressed: isPressed, isEnabled: true))
            // Make the 44pt label content visible in the evidence without
            // changing the production control's appearance.
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(WatchPalette.secondary.opacity(0.28), lineWidth: 0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

#if DEBUG
/// Pinned frames make the smallest and largest supported watch explicit in
/// Canvas. The accessibility variants use the same fixture hierarchy as the
/// normal previews, so Dynamic Type changes are visible rather than two
/// unrelated mock layouts.
private enum WatchIconPreviewScreen {
    static let mm40 = CGSize(width: 162, height: 197)
    static let mm49 = CGSize(width: 205, height: 251)
}

private func watchIconPreview(_ size: CGSize) -> some View {
    WatchIconPrimitiveFixtureView()
        .frame(width: size.width, height: size.height)
        .clipped()
}

#Preview("Icon primitives · 40mm") {
    watchIconPreview(WatchIconPreviewScreen.mm40)
}

#Preview("Icon primitives · 49mm") {
    watchIconPreview(WatchIconPreviewScreen.mm49)
}

#Preview("Icon primitives · 40mm · accessibility") {
    watchIconPreview(WatchIconPreviewScreen.mm40)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Icon primitives · 49mm · accessibility") {
    watchIconPreview(WatchIconPreviewScreen.mm49)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif

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
