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

/// The complete feedback vocabulary. Every haptic in the app is one of these.
public enum HapticCue: Equatable, Sendable {
    case light
    case medium
    case warning
    case success
    case error
    case pattern(HapticPattern)
}

/// Guided-protocol segment transition cues — the web's `ForceFullscreen.tsx`
/// rhythm table: `hold` → single 150 ms, `switch` → `[80,60,80]`, everything
/// else (prepare/rest/setRest/done) → `[80,60,80]`. Native reverse-action sets
/// are one continuous `.work` stage (there is no per-rep return cadence), so
/// the web's `[70,60,70]` return pattern has no native surface to attach to
/// yet — it stays representable via `HapticPattern` for when one lands.
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
