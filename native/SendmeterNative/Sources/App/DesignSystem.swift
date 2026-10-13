import SendLogWatchCore
import SendmeterCore
import SwiftUI

public enum SendmeterStyle {
    public static let radius: CGFloat = CGFloat(SheetPresentationPolicy.cornerRadius)
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

    // #791 W1: the single canonical semantic hue source shared by phone,
    // watch and widget. The watch applies its own luminance adaptation on
    // top of these exact hues (always-on / reduced-luminance), and the dark
    // chart pairs in ChartToken are the phone's dark-mode adaptation.
    public static let capacity = Color.palette(SendmeterPalette.optimal)
    public static let strength = Color.palette(SendmeterPalette.caution)
    public static let power = Color.palette(SendmeterPalette.danger)
    public static let execution = Color.palette(SendmeterPalette.execution)
    public static let primary = Color.palette(SendmeterPalette.primary)
    public static let optimal = Color.palette(SendmeterPalette.optimal)
    public static let caution = Color.palette(SendmeterPalette.caution)
    public static let paused = Color.palette(SendmeterPalette.paused)
    public static let alert = Color.palette(SendmeterPalette.danger)

    // #1028 B1: the shared neutral ramp (phone = Watch). Every phone surface
    // and text colour resolves here from `SendmeterPalette`; the Watch reads
    // the same pairs' dark values through `WatchPalette`.
    public static let canvas = Color.palette(SendmeterPalette.canvas)
    public static let surface = Color.palette(SendmeterPalette.surface)
    public static let surfaceRaised = Color.palette(SendmeterPalette.surfaceRaised)
    public static let surfaceNested = Color.palette(SendmeterPalette.surfaceNested)
    public static let surfaceDisabled = Color.palette(SendmeterPalette.surfaceDisabled)
    public static let line = Color.palette(SendmeterPalette.line)
    public static let textPrimary = Color.palette(SendmeterPalette.textPrimary)
    public static let textSecondary = Color.palette(SendmeterPalette.textSecondary)
    public static let textTertiary = Color.palette(SendmeterPalette.textTertiary)
    public static let textDisabled = Color.palette(SendmeterPalette.textDisabled)
    public static let primaryText = Color.palette(SendmeterPalette.primaryText)
    public static let primarySoft = Color.palette(SendmeterPalette.primarySoft)
    public static let onPrimary = Color.palette(SendmeterPalette.onPrimary)
    public static let onCaution = Color.palette(SendmeterPalette.onCaution)
    public static let optimalText = Color.palette(SendmeterPalette.optimalText)
    public static let cautionText = Color.palette(SendmeterPalette.cautionText)
    public static let dangerText = Color.palette(SendmeterPalette.dangerText)
    public static let executionText = Color.palette(SendmeterPalette.executionText)
    public static let zonePowerEndurance = Color.palette(SendmeterPalette.zonePowerEndurance)
    public static let zoneEndurance = Color.palette(SendmeterPalette.zoneEndurance)

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
    /// #1028 B1: a light/dark `SendmeterPalette` pair as one dynamic colour
    /// (resolves per trait collection, so it follows the app's theme choice
    /// without threading `colorScheme` through every view).
    static func palette(_ pair: SendmeterPalette.Pair) -> Color {
        guard pair.light != pair.dark else { return Color(hex: pair.light) }
        let light = UIColor(Color(hex: pair.light))
        let dark = UIColor(Color(hex: pair.dark))
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

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
            // #1028 B1: the shared `surface` token (phone = Watch card)
            // replaces the system material, whose grey drifted from the Watch.
            .background(SendmeterStyle.surface, in: RoundedRectangle(cornerRadius: SendmeterStyle.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SendmeterStyle.radius, style: .continuous)
                    .stroke(SendmeterStyle.line, lineWidth: 1)
            )
    }
}

/// Illustration options for the shared product empty state. The splash
/// composite stays the default for generic product surfaces; the Force
/// device empty state opts into the approved kangaroo mascot hero glyph
/// (#894) so its disconnected/empty card carries no cave/photo background.
public enum ProductEmptyStateArtwork {
    case splash
    case forceMascot
}

/// Shared product empty state for data surfaces that have finished loading but
/// have nothing useful to show yet. The illustration deliberately reuses the
/// shipped splash art so an empty screen still feels like Sendmeter, rather
/// than falling back to a framework placeholder or a bare SF Symbol.
public struct ProductEmptyState: View {
    let title: String
    let message: String
    let actionTitle: String
    let artwork: ProductEmptyStateArtwork
    let action: () -> Void
    let compact: Bool

    public init(
        title: String,
        message: String,
        actionTitle: String,
        compact: Bool = false,
        artwork: ProductEmptyStateArtwork = .splash,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.artwork = artwork
        self.action = action
        self.compact = compact
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

    @ViewBuilder
    private var illustration: some View {
        switch artwork {
        case .forceMascot:
            // #894: the approved R11 Force hero master (160 optical variant)
            // replaces the cave/photo composite on the Force device empty
            // state. Template rendering keeps the native primary tint in
            // light and dark; the image stays decorative like the splash
            // composite, so it remains out of the accessibility tree.
            Image("ForceMascotLarge")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 82 : 122, height: compact ? 82 : 118)
                .foregroundStyle(SendmeterStyle.primary)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        case .splash:
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
        ViewThatFits(in: .horizontal) {
            inlineValue
            stackedValue
        }
        .layoutPriority(1)
    }

    private var inlineValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            valueText
            unitText
        }
    }

    private var stackedValue: some View {
        VStack(alignment: .leading, spacing: 2) {
            valueText
            unitText
        }
    }

    private var valueText: some View {
        Text(value)
            .modifier(SendmeterStyle.heroMetric)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var unitText: some View {
        if let unit {
            Text(unit)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

public struct PrimaryActionButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.shared.playGesture(StructuralHaptics.cue(level: structuralHapticLevel))
                }
            }
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

    /// #1028 B3: the label is the hue mixed into `textPrimary`
    /// (`SendmeterPalette.pillText`), not the raw hue — raw caution/danger/
    /// optimal labels were 1.9–2.9:1 in light mode. Painted as textPrimary
    /// with the hue layered on top at `pillTextHueWeight`, which composites to
    /// exactly that mix for any `Color` a call site passes (iOS 17 has no
    /// `Color.mix`).
    public var body: some View {
        label
            .foregroundStyle(SendmeterStyle.textPrimary)
            .overlay {
                label
                    .foregroundStyle(color.opacity(SendmeterPalette.pillTextHueWeight))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(SendmeterPalette.pillFillOpacity), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 1))
    }

    private var label: some View {
        Text(text).font(.caption.weight(.semibold))
    }
}

/// #927: the shared error banner's accessibility contract.
///
/// The banner is the app's single failure surface, so its two accessibility
/// obligations live in one place a test can read:
///
/// - the dismiss control is a real target (44×44 pt) with an explicit,
///   user-facing label — never a bare caption-sized glyph;
/// - a NEW failure is announced exactly once, and an unchanged one is silent.
///   The announcement channel speaks the text without moving VoiceOver focus,
///   so an in-progress workout control keeps focus while the failure is heard.
public enum ErrorBannerAccessibility {
    /// The dismiss target's minimum edge (Apple's 44×44 pt guidance).
    public static let dismissTarget: CGFloat = 44
    /// Explicit user-facing action label (not an SF Symbol name).
    public static let dismissLabel = "Dismiss error"
    /// Stable identifiers for the two banner controls the tests address.
    public static let dismissIdentifier = "error-banner-dismiss"
    public static let messageIdentifier = "error-banner-message"

    /// A new, non-empty message announces; the same message re-rendered
    /// (theme switch, layout pass, animation frame) does not, and a cleared
    /// banner is silent.
    public static func shouldAnnounce(previous: String?, next: String?) -> Bool {
        guard let next, !next.isEmpty else { return false }
        return next != previous
    }

    /// Posts one VoiceOver announcement through SwiftUI's accessibility API.
    public static func post(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

/// #927: attaches the once-per-new-message announcement to whichever view
/// hosts the banner. The policy tracks the MESSAGE identity, not render
/// passes, so a banner that is re-rendered (or animated in) cannot spam
/// announcements. `post` is injectable so app-target tests can count exactly
/// how many announcements a message and its rerenders produce.
struct ErrorBannerAnnouncementModifier: ViewModifier {
    let message: String?
    var post: (String) -> Void = ErrorBannerAccessibility.post

    func body(content: Content) -> some View {
        content.onChange(of: message) { previous, next in
            guard ErrorBannerAccessibility.shouldAnnounce(previous: previous, next: next),
                  let next
            else { return }
            post(next)
        }
    }
}

extension View {
    func errorBannerAnnouncement(
        message: String?,
        post: @escaping (String) -> Void = ErrorBannerAccessibility.post
    ) -> some View {
        modifier(ErrorBannerAnnouncementModifier(message: message, post: post))
    }
}

public struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // #927 follow-up: at accessibility text sizes the glyph and the
                // dismiss target share a top row and the message wraps across
                // the full banner width, so the longest failure copy still
                // fits on one phone screen instead of a narrow column that
                // runs off its bottom edge.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        alertGlyph
                        Spacer(minLength: 0)
                        dismissButton
                    }
                    messageText
                        // VoiceOver still reads the message before the
                        // dismiss control, as in the single-row layout.
                        .accessibilitySortPriority(1)
                }
                .accessibilityElement(children: .contain)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    alertGlyph
                    messageText
                    dismissButton
                }
            }
        }
        .padding(12)
        // #927 follow-up: an opaque backing under the tint, so nothing the
        // screen draws beneath the banner (a large title, scrolled content)
        // can show through the message.
        .background(SendmeterStyle.alert.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var alertGlyph: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(SendmeterStyle.alert)
            // Decorative: VoiceOver reads the message itself, not the glyph.
            .accessibilityHidden(true)
    }

    private var messageText: some View {
        Text(message)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Wrap to the message's full height at every text size instead
            // of letting a compressed proposal clip the copy (#927).
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(ErrorBannerAccessibility.messageIdentifier)
    }

    private var dismissButton: some View {
        DismissControl(dismiss: dismiss)
    }

    /// The one dismiss control both layouts place.
    private struct DismissControl: View {
        let dismiss: () -> Void

        var body: some View {
            Button {
                Haptics.shared.playGesture(.light)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    // The glyph keeps its top-trailing seat; the surrounding
                    // space is spent on a 44 pt target that stays inside the
                    // banner and clear of the message column.
                    .frame(
                        width: ErrorBannerAccessibility.dismissTarget,
                        height: ErrorBannerAccessibility.dismissTarget,
                        alignment: .topTrailing
                    )
                    .contentShape(.rect)
            }
            .hapticButtonStyle(.plain)
            .accessibilityLabel(ErrorBannerAccessibility.dismissLabel)
            .accessibilityIdentifier(ErrorBannerAccessibility.dismissIdentifier)
        }
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
                    Haptics.shared.playGesture(.light)
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
        .contentShape(Capsule())
        .shadow(radius: 12, y: 6)
    }
}

// MARK: - #1028 A1: chalk texture (a few hero surfaces only)

/// #1028 A1: the chalky texture — on a FEW hero surfaces only (Today's
/// decision, the armed protocol). A fixed-seed speckle drawn in the text
/// token at very low opacity, so it is identical on every render, follows
/// the theme, and never carries meaning. Hidden when the user asks for
/// increased contrast or reduced transparency.
public struct ChalkTexture: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Contrast-bounded peak opacity (`SendmeterPalette.chalkOpacity`).
    static let opacity: Double = SendmeterPalette.chalkOpacity
    /// Fixed seed (0x404 = 1028, the issue number the approved texture was
    /// captured with), so the pattern matches the #1028 approved sheets.
    static let seed: UInt64 = 0x404

    public init() {}

    public var body: some View {
        if contrast != .increased, !reduceTransparency {
            Canvas(rendersAsynchronously: false) { context, size in
                var state = Self.seed
                func next() -> Double {
                    // SplitMix64: deterministic and platform-independent.
                    state &+= 0x9E37_79B9_7F4A_7C15
                    var z = state
                    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                    return Double(z ^ (z >> 31)) / Double(UInt64.max)
                }
                // ~1 grain per 90 pt², denser toward the top edge (chalk
                // dust settles where a hand brushes the card).
                let count = Int(size.width * size.height / 90)
                for _ in 0..<count {
                    let x = next() * size.width
                    let y = pow(next(), 1.6) * size.height
                    let r = 0.35 + next() * 0.9
                    context.opacity = 0.35 + next() * 0.65
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: r * 2.2, height: r * 1.6)),
                        with: .color(SendmeterStyle.textPrimary)
                    )
                }
            }
            .opacity(Self.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

public extension View {
    /// #1028 A1: chalk texture on a hero surface, clipped to its shape.
    func sendmeterChalk(cornerRadius: CGFloat = SendmeterStyle.radius) -> some View {
        overlay {
            ChalkTexture()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
