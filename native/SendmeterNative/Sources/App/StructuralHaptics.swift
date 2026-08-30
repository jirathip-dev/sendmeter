import SendmeterCore
import SwiftUI

private struct HapticTapMutedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct StructuralHapticTapPolicyKey: EnvironmentKey {
    static let defaultValue = StructuralHapticTapPolicy.allEnabled
}

public extension EnvironmentValues {
    var hapticTapMuted: Bool {
        get { self[HapticTapMutedKey.self] }
        set { self[HapticTapMutedKey.self] = newValue }
    }

    var structuralHapticTapPolicy: StructuralHapticTapPolicy {
        get { self[StructuralHapticTapPolicyKey.self] }
        set { self[StructuralHapticTapPolicyKey.self] = newValue }
    }
}

private enum HapticTapSource {
    case rootDefault
    case explicit
}

private extension StructuralHapticTapPolicy {
    func allows(_ source: HapticTapSource) -> Bool {
        switch source {
        case .rootDefault:
            return rootDefaultEnabled
        case .explicit:
            return explicitEnabled
        }
    }
}

/// The SwiftUI half of the structural haptics layer (#752).
///
/// Production uses SwiftUI's native Button action/press path for implicit
/// buttons. Explicit card surfaces fire from their own action closure rather
/// than installing a second recognizer that competes with scrolling. The
/// DEBUG-only A/B arms also expose the pre-fix zero-distance drag control so
/// the original structural-gesture hypothesis can be compared on-device.
/// The one-tick tracker is Core (`StructuralHapticTracker`); this modifier only
/// feeds it.
///
/// System `Menu` rows are rendered outside the SwiftUI view hierarchy, so a
/// row cannot carry `.hapticTap` directly. Menu triggers opt in with it and
/// each row action calls `Haptics.shared.playGesture(_:)`, which keeps
/// trigger + row selection to one tick within the settled-gesture window. If
/// a menu is held open longer than that window, the row selection is
/// necessarily a separate gesture and produces its own tick.
public struct HapticTapModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hapticTapMuted) private var muted
    @Environment(\.structuralHapticTapPolicy) private var policy
#if DEBUG
    @State private var tracking = false
#endif

    private let level: HapticTapLevel
    private let source: HapticTapSource

    public init(level: HapticTapLevel = .normal) {
        self.level = level
        self.source = .explicit
    }

    fileprivate init(level: HapticTapLevel, source: HapticTapSource) {
        self.level = level
        self.source = source
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if policy.allows(source) {
#if DEBUG
            if policy.attachment == .legacyZeroDistance {
                // Diagnostic A/B only. The legacy control preserves the
                // pre-fix callback semantics; production never compiles this
                // zero-distance recognizer into its normal path.
                content.simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isEnabled, !muted else { return }
                            if !tracking {
                                tracking = true
                                Haptics.shared.beginTap(
                                    cue: StructuralHaptics.cue(level: level)
                                )
                            }
                            let overSlop = max(
                                abs(value.translation.width),
                                abs(value.translation.height)
                            ) > StructuralHapticTracker.tapSlopPx
                            if overSlop {
                                tracking = false
                                Haptics.shared.cancelTap()
                            }
                        }
                        .onEnded { _ in
                            // Keep A faithful to the pre-fix control,
                            // including its mid-gesture enabled/muted guard.
                            guard tracking, isEnabled, !muted else { return }
                            tracking = false
                            Haptics.shared.completeTap()
                        }
                )
            } else {
                scrollSafeBody(content: content)
            }
#else
            scrollSafeBody(content: content)
#endif
        } else {
            content
        }
    }

    private func scrollSafeBody(content: Content) -> some View {
        // Production explicit surfaces stay on their native action path.
        content
    }
}

public extension View {
    /// Opt a non-button tappable (or a Button already styled by the system)
    /// into the structural tap tick.
    func hapticTap(_ level: HapticTapLevel = .normal) -> some View {
        modifier(HapticTapModifier(level: level))
    }

    /// The root default-button style uses a distinct source so B′ can keep
    /// the root gesture while muting only explicit HapticTapModifier paths.
    fileprivate func structuralHapticTap(_ level: HapticTapLevel = .normal) -> some View {
        modifier(HapticTapModifier(level: level, source: .rootDefault))
    }

    /// Apply a ButtonStyle and a structural tap tick in one place, so adding
    /// a new control does not require remembering a haptic call-site.
    @ViewBuilder
    func hapticButtonStyle<S: SwiftUI.ButtonStyle>(_ style: S) -> some View {
        if style is any StructuralHapticStyle {
            buttonStyle(style)
        } else {
            buttonStyle(StructuralButtonStyle(style: style))
        }
    }

    /// System styles such as `.plain` are static members of
    /// `PrimitiveButtonStyle`, so mirror SwiftUI's own overload split.
    @ViewBuilder
    func hapticButtonStyle<S: SwiftUI.PrimitiveButtonStyle>(_ style: S) -> some View {
        buttonStyle(StructuralPrimitiveButtonStyle(style: style))
    }

    /// Suppress structural feedback for a surface that owns its own feedback
    /// (chart scrubbing, sliders) or that must stay completely silent.
    func hapticTapMuted() -> some View {
        environment(\.hapticTapMuted, true)
    }
}

/// The structural default for buttons that don't opt into an explicit app
/// style. Production wraps the action in a native Button and delegates the
/// visual and scroll arbitration to SwiftUI's `DefaultButtonStyle`; there is
/// no global zero-distance drag. DEBUG A/B arms retain the legacy body so the
/// old root attachment can be compared on the same source revision.
public struct StructuralDefaultButtonStyle: PrimitiveButtonStyle {
    private let mode: StructuralHapticDiagnosticMode

    public init(mode: StructuralHapticDiagnosticMode = .normal) {
        self.mode = mode
    }

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
#if DEBUG
        if mode.usesLegacyStructuralGesture {
            if mode.tapPolicy.rootDefaultEnabled {
                DefaultButtonStyle().makeBody(configuration: configuration)
                    .structuralHapticTap()
            } else {
                // B deliberately delegates to SwiftUI's stock default
                // behavior; explicit action haptics and all feature behavior
                // stay intact.
                DefaultButtonStyle().makeBody(configuration: configuration)
            }
        } else {
            ScrollSafeStructuralButton(configuration: configuration)
        }
#else
        ScrollSafeStructuralButton(configuration: configuration)
#endif
    }
}

/// Adapts a regular ButtonStyle to a native action-owned structural tick.
private struct StructuralButtonStyle<S: ButtonStyle>: PrimitiveButtonStyle {
    let style: S

    func makeBody(configuration: Configuration) -> some View {
        Button {
            Haptics.shared.beginTap(cue: StructuralHaptics.cue(level: .normal))
            Haptics.shared.completeTap()
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(style)
    }
}

/// Adapts a primitive style without embedding a gesture in its label.
private struct StructuralPrimitiveButtonStyle<S: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let style: S

    func makeBody(configuration: Configuration) -> some View {
        Button {
            Haptics.shared.beginTap(cue: StructuralHaptics.cue(level: .normal))
            Haptics.shared.completeTap()
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(style)
    }
}

/// A real Button owns press/scroll arbitration. Its action arms the same
/// shared tracker that explicit tap surfaces use, then triggers the original
/// primitive action exactly once.
private struct ScrollSafeStructuralButton: View {
    let configuration: PrimitiveButtonStyle.Configuration

    var body: some View {
        Button(role: configuration.role) {
            Haptics.shared.beginTap(cue: StructuralHaptics.cue(level: .normal))
            Haptics.shared.completeTap()
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(DefaultButtonStyle())
    }
}

/// Marker for a `ButtonStyle` that already carries the structural haptic
/// directly in its `makeBody`. `hapticButtonStyle` leaves these styles alone
/// so the tracker is not armed twice for the same touch.
public protocol StructuralHapticStyle {
    var structuralHapticLevel: HapticTapLevel { get }
}
