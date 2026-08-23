import SendmeterCore
import SwiftUI

private struct HapticTapMutedKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var hapticTapMuted: Bool {
        get { self[HapticTapMutedKey.self] }
        set { self[HapticTapMutedKey.self] = newValue }
    }
}

/// The SwiftUI half of the structural haptics layer (#752).
///
/// SwiftUI exposes no global `<button>` equivalent, so a button/card is given
/// a `DragGesture(minimumDistance: 0)` as a *simultaneous* gesture. It starts
/// a shared tick on touch-down, cancels after the web tap slop (a scroll that
/// starts on a control stays silent), and settles on lift. The one-tick
/// tracker is Core (`StructuralHapticTracker`); this modifier only feeds it.
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
    @State private var tracking = false

    private let level: HapticTapLevel

    public init(level: HapticTapLevel = .normal) {
        self.level = level
    }

    public func body(content: Content) -> some View {
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
                    guard tracking, isEnabled, !muted else { return }
                    tracking = false
                    // The dispatcher holds the settled cue for a short
                    // arbitration window, so a Button action that runs after
                    // this callback can still promote the same gesture to its
                    // explicit medium/warning cue instead of double-firing.
                    Haptics.shared.completeTap()
                }
        )
    }
}

public extension View {
    /// Opt a non-button tappable (or a Button already styled by the system)
    /// into the structural tap tick.
    func hapticTap(_ level: HapticTapLevel = .normal) -> some View {
        modifier(HapticTapModifier(level: level))
    }

    /// Apply a ButtonStyle and a structural tap tick in one place, so adding
    /// a new control does not require remembering a haptic call-site.
    @ViewBuilder
    func hapticButtonStyle<S: SwiftUI.ButtonStyle>(_ style: S) -> some View {
        if style is any StructuralHapticStyle {
            buttonStyle(style)
        } else {
            buttonStyle(style).hapticTap()
        }
    }

    /// System styles such as `.plain` are static members of
    /// `PrimitiveButtonStyle`, so mirror SwiftUI's own overload split.
    @ViewBuilder
    func hapticButtonStyle<S: SwiftUI.PrimitiveButtonStyle>(_ style: S) -> some View {
        if style is any StructuralHapticStyle {
            buttonStyle(style)
        } else {
            buttonStyle(style).hapticTap()
        }
    }

    /// Suppress structural feedback for a surface that owns its own feedback
    /// (chart scrubbing, sliders) or that must stay completely silent.
    func hapticTapMuted() -> some View {
        environment(\.hapticTapMuted, true)
    }
}

/// The structural default for buttons that don't opt into an explicit app
/// style. It delegates the visual to SwiftUI's `DefaultButtonStyle` and adds
/// the same one-tick tap gesture, so implicit list/toolbar controls are not
/// silent just because they never called `.hapticButtonStyle`.
public struct StructuralDefaultButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DefaultButtonStyle().makeBody(configuration: configuration)
            .hapticTap()
    }
}

/// Marker for a `ButtonStyle` that already carries the structural haptic
/// directly in its `makeBody`. `hapticButtonStyle` leaves these styles alone
/// so the tracker is not armed twice for the same touch.
public protocol StructuralHapticStyle {
    var structuralHapticLevel: HapticTapLevel { get }
}
