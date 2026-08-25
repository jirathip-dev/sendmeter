import Foundation

/// Haptics parity with the web's delegated model (#656) — the DECISION layer
/// only. Everything here is pure Foundation (no UIKit, no SwiftUI) so it runs
/// under `swift test` on macOS; the App target's `Haptics` dispatcher
/// (`Sources/App/Haptics.swift`) is the single UIKit touch point that turns a
/// `HapticCue` into a feedback-generator call. Feature code maps a gesture to
/// one of the pure helpers below and calls `Haptics.shared.play(...)` — it
/// never touches `UIImpactFeedbackGenerator` directly (grep-assertable).

/// A buzz rhythm — the web's `navigator.vibrate` vocabulary. `.sensoryFeedback`
/// cannot express a pattern, so the App dispatcher approximates each buzz as a
/// `.rigid` impact at the pattern's start times (issue #656).
public enum HapticPattern: Equatable, Sendable {
    /// One rigid tick, scaled to the web's millisecond cue (hold 150 / armed
    /// 80 / in-zone 45).
    case single(milliseconds: Double)
    /// Alternating buzz / pause durations, exactly like `navigator.vibrate`
    /// (`[80, 60, 80]` switch, `[120, 80, 120, 80, 120]` failed, etc.).
    case stutter(milliseconds: [Double])
}

/// The weight a `.single` buzz maps to — `UIImpactFeedbackGenerator` has no
/// duration axis, so the web's duration-coded singles (hold 150, armed 80,
/// in-zone 45) are approximated by intensity so the cues stay distinguishable
/// (review F11). Pure Core so the mapping is unit-tested; the App dispatcher
/// turns each weight into a UIKit style.
public enum HapticSingleWeight: Equatable, Sendable {
    case light
    case medium
    case heavy
}

public enum HapticPatternWeights {
    /// 150 ms (a hold) is the reference `.medium`; longer reads heavier,
    /// shorter lighter.
    public static func singleWeight(milliseconds: Double) -> HapticSingleWeight {
        if milliseconds >= 130 { return .heavy }
        if milliseconds <= 80 { return .light }
        return .medium
    }
}

/// The complete feedback vocabulary. Every haptic in the app is one of these.
public enum HapticCue: Equatable, Sendable {
    case light
    case medium
    case warning
    case success
    case error
    /// The crisp picker/scrubber detent — the web's `selectionHaptic()`, a
    /// DIFFERENT generator (`UISelectionFeedbackGenerator`), deliberately
    /// unguarded per value change (review F4). Sheet/open ticks use `.light`.
    case selection
    case pattern(HapticPattern)
}

/// Guided-protocol segment transition cues — the web's `ForceFullscreen.tsx`
/// rhythm table: `hold` → single 150 ms, `switch` → `[80,60,80]`, everything
/// else (prepare/rest/setRest/done) → `[80,60,80]`. Native reverse-action sets
/// are one continuous `.work` stage (there is no per-rep return cadence), so
/// the web's `[70,60,70]` return pattern has no native surface to attach to
/// yet — it stays representable via `HapticPattern` for when one lands.
///
/// Spec rows with no native surface to attach to — documented here so the next
/// reader doesn't re-derive them (review F15):
///
/// - `return` → `[70,60,70]` and failed-transition → `[120,80,120,80,120]`:
///   `ForceProtocolStageKind` has no `move`/`return` stage and native has no
///   adaptive-failed state, so neither pattern can fire.
/// - Target-zone coach cues (`in-zone` 45, `below` `[35,45,70]`, `above`
///   `[70,45,35]` — `ForceFullscreen.tsx:632-635`): native has no target-zone
///   coach at all, so there is genuinely nothing to attach to.
/// - Routine-timer segment transitions (web `RoutineFullscreen.tsx:235`):
///   out of #656's scope (its table names only force segments) — a known
///   parity gap, flagged for the next haptics pass.
public enum GuidedTransitionHaptics {
    public static func cue(entering kind: ForceProtocolStageKind) -> HapticCue {
        switch kind {
        case .work:
            return .pattern(.single(milliseconds: 150))
        case .switchSide:
            return .pattern(.stutter(milliseconds: [80, 60, 80]))
        case .prepare, .restBetweenRepetitions, .restBetweenSets, .complete:
            return .pattern(.stutter(milliseconds: [80, 60, 80]))
        }
    }
}

/// Hands-free armed / measuring status cues — the web's
/// `navigator.vibrate?.(next === "armed" ? 80 : 150)`.
public enum HandsFreeHapticState: Equatable, Sendable {
    case armed
    case measuring
}

public enum HandsFreeHaptics {
    public static func cue(for state: HandsFreeHapticState) -> HapticCue {
        switch state {
        case .armed:
            return .pattern(.single(milliseconds: 80))
        case .measuring:
            return .pattern(.single(milliseconds: 150))
        }
    }
}

/// The scrub tick guard — "once per VALUE change, not per drag frame" (web
/// `useChartHover`'s `if (hovered !== value) selectionHaptic()`). A scrub that
/// stays inside one band keeps returning false and stays silent (AC1).
public enum SelectionHaptics {
    public static func valueChanged<T: Equatable>(_ previous: T?, _ next: T?) -> Bool {
        previous != next
    }
}

/// The refused-vs-disabled rule (#222): a control that is deliberately still
/// clickable but refuses the action — the tap is how the user learns WHY —
/// fires the warning; a genuinely disabled control fires nothing (AC3).
public enum RefusedActionHaptics {
    public static func cue(tappableAndRefused: Bool) -> HapticCue? {
        tappableAndRefused ? .warning : nil
    }
}

/// The structural tap vocabulary (#752) — the native analogue of the web's
/// `data-haptic` values (`haptics.ts`). A normal interactive control gets the
/// light tick; a confirm/destructive action gets medium; a deliberately
/// clickable-but-refused control gets warning; a genuinely disabled control is
/// filtered out before it reaches the tracker.
public enum HapticTapLevel: Equatable, Sendable {
    case normal
    case confirm
    case refused
}

public enum StructuralHaptics {
    public static func cue(level: HapticTapLevel, isEnabled: Bool = true) -> HapticCue? {
        guard isEnabled else { return nil }
        switch level {
        case .normal:
            return .light
        case .confirm:
            return .medium
        case .refused:
            return .warning
        }
    }
}

/// One tick per pointer gesture (#752) — the pure version of the web's
/// `createGestureTracker` (`tapHaptics.ts`). SwiftUI buttons don't expose a
/// DOM event path, so the App layer calls `begin`/`complete` around a touch
/// and every consumer (the button itself, an explicit confirm haptic, sheet
/// presentation, sheet dismissal) claims the same pending cue exactly once.
public struct StructuralHapticTracker: Sendable {
    /// Mirror of the web `TAP_SLOP_PX`.
    public static let tapSlopPx: Double = 10
    /// Mirror of the web `GESTURE_FRESH_MS`.
    public static let gestureFreshnessMs: Double = 1_500
    /// A close-button tick and the sheet's `onDismiss` arrive close together;
    /// this window lets the dismissal hook see the same gesture as already
    /// settled instead of adding a second tick.
    public static let dismissalDuplicateWindowMs: Double = 400

    private var pendingCue: HapticCue?
    private var pendingStartMs: Double?
    private var settledAtMs: Double?
    private var settledCue: HapticCue?
    private var settled = false

    public init() {}

    public mutating func begin(cue: HapticCue?, nowMs: Double) {
        pendingCue = cue
        pendingStartMs = cue == nil ? nil : nowMs
        settledAtMs = nil
        settledCue = nil
        settled = false
    }

    public mutating func cancel() {
        pendingCue = nil
        pendingStartMs = nil
    }

    public mutating func claim(
        nowMs: Double,
        requireGestureWithinMs: Double = StructuralHapticTracker.gestureFreshnessMs
    ) -> HapticCue? {
        guard let cue = pendingCue,
              let pendingStartMs,
              !settled,
              nowMs - pendingStartMs <= requireGestureWithinMs
        else {
            return nil
        }
        settled = true
        settledAtMs = nowMs
        settledCue = cue
        pendingCue = nil
        self.pendingStartMs = nil
        return cue
    }

    /// Completes a button/card tap. This intentionally ignores the freshness
    /// window: the user is physically holding the touch when this is called,
    /// so a long press must still settle once they lift.
    public mutating func complete(nowMs: Double) -> HapticCue? {
        claim(
            nowMs: nowMs,
            requireGestureWithinMs: .infinity
        )
    }

    public var hasPendingGesture: Bool {
        pendingCue != nil
    }

    /// Claims the default cue a completed button gesture settled on. This lets
    /// an explicit confirm/refused/selection action upgrade the same gesture
    /// even when SwiftUI runs the Button action after the structural
    /// `onEnded`, without allowing a second tick.
    public mutating func consumeSettled(
        nowMs: Double,
        withinMs: Double
    ) -> HapticCue? {
        guard let settledCue, let settledAtMs else { return nil }
        guard nowMs - settledAtMs <= withinMs else { return nil }
        self.settledCue = nil
        return settledCue
    }

    public func wasSettled(nowMs: Double, withinMs: Double) -> Bool {
        guard let settledAtMs else { return false }
        return nowMs - settledAtMs <= withinMs
    }
}

/// Sheet-mount tick gate — the web's `createGestureTracker` + `claim(...)`
/// (`GESTURE_FRESH_MS`): a sheet ticks only when a tap armed it within the
/// freshness window, and one tap spends exactly one tick. A sheet that appears
/// without a tap behind it — an auto-prompt, a restored session — stays silent.
public struct HapticGestureGate: Sendable {
    /// Web `GESTURE_FRESH_MS` (1.5 s).
    public static let tapFreshnessMs: Double = 1_500

    private var lastTapAtMs: Double?
    private var tickSpent = false

    public init() {}

    /// A user-initiated tap landed. One tap arms exactly one future tick.
    public mutating func tap(nowMs: Double) {
        lastTapAtMs = nowMs
        tickSpent = false
    }

    /// Whether this gesture may spend its tick — the tap must be within the
    /// freshness window and not already claimed. Calling this claims it, so
    /// exactly one consumer per gesture gets the tick.
    public mutating func claim(
        nowMs: Double,
        requireGestureWithinMs: Double = HapticGestureGate.tapFreshnessMs
    ) -> Bool {
        guard let lastTapAtMs, nowMs - lastTapAtMs <= requireGestureWithinMs, !tickSpent else {
            return false
        }
        tickSpent = true
        return true
    }

    public mutating func reset() {
        lastTapAtMs = nil
        tickSpent = false
    }
}
