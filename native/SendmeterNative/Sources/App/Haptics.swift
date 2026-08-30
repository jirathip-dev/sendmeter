import SendmeterCore
import UIKit

/// The app's single haptics touch point (#656). The DECISION layer lives in
/// Core (`Haptics.swift`); this dispatcher is the one UIKit surface that turns
/// a `HapticCue` into feedback-generator calls. Feature code calls
/// `Haptics.shared.play(...)` (or `tap()` / `sheetPresented()`) and never
/// touches a feedback generator directly (grep-assertable, pinned by
/// `src/lib/hapticsInvariants.test.ts`).
///
/// All calls are fire-and-forget: a failure can never propagate into the
/// action it accompanies.
///
/// Generators are cached per style and reused, because `prepare()` is an
/// asynchronous warm-up that must run AHEAD of the event to help; allocating a
/// fresh generator and calling `prepare()` on the very next line pays cold-start
/// latency on every tick (review F10). The whole dispatcher is `@MainActor`,
/// which is exactly the context Apple's retain-and-prepare guidance assumes.
///
/// Pattern cues are approximated as `.rigid` impacts spaced by `Task.sleep`
/// at the web's rhythm (single 150 ms hold, `[80,60,80]` switch, etc.) — a
/// CHHapticEngine is a real lifecycle burden for a "one buzz vs two vs a
/// stutter" cue, and the issue directs to ship the approximation (device
/// verification listed in RELEASE_NOTES).
///
/// Sheets (and the guided-protocol fullscreen) tick on presentation only when
/// a tap armed the gesture gate within the freshness window — the web's
/// `sheetHaptic()` semantics (an auto-prompt or restored session stays
/// silent, and one tap spends exactly one tick).
@MainActor
public final class Haptics {
    public static let shared = Haptics()

    private var gestureGate = HapticGestureGate()
    private var structuralTracker = StructuralHapticTracker()
    private var structuralDefaultSettlement: (cue: HapticCue, generation: Int)?
    private var structuralSettlementGeneration = 0
    private var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private var notification: UINotificationFeedbackGenerator?
    private var selection: UISelectionFeedbackGenerator?
#if DEBUG
    public private(set) var debugEmissionCount = 0
#endif
    private init() {}

    /// A structural button/card touch started. Mirrors the web delegated
    /// pointer-down: it arms one shared tick, but nothing fires until the
    /// gesture settles or another consumer claims it.
    public func beginTap(cue: HapticCue? = .light) {
        cancelStructuralDefault()
        gestureGate.reset()
        structuralTracker.begin(cue: cue, nowMs: nowMilliseconds())
    }

    /// The touch turned into a scroll/drag (past the web tap slop), so the
    /// gesture must not produce feedback.
    public func cancelTap() {
        structuralTracker.cancel()
    }

    /// A structural button/card touch lifted. If an explicit action haptic
    /// already claimed this gesture, this is a no-op; otherwise it settles the
    /// structural cue once per gesture.
    public func completeTap() {
        guard let cue = structuralTracker.complete(nowMs: nowMilliseconds()) else { return }
        scheduleStructuralDefault(cue)
    }

    /// A user-initiated tap landed on a control that presents a sheet/full-
    /// screen. Arms the gate so that surface's presentation can spend the
    /// tick. Nothing fires here — a sheet presented later does.
    public func tap() {
        // The structural tracker owns the button gesture when a haptic-aware
        // style/modifier is present. Don't re-arm the legacy gate on top of it.
        guard !structuralTracker.hasPendingGesture else { return }
        // If the button action runs after the structural gesture has already
        // settled, the delayed default tick owns the feedback. Preserve that
        // instead of arming a second sheet tick on the same touch.
        guard !structuralTracker.wasSettled(
            nowMs: nowMilliseconds(),
            withinMs: StructuralHapticTracker.dismissalDuplicateWindowMs
        ) else { return }
        gestureGate.tap(nowMs: nowMilliseconds())
    }

    /// A sheet/fullscreen just presented. Fires a light tick only when a tap
    /// armed the gate within the freshness window and no other consumer has
    /// spent this gesture's tick.
    public func sheetPresented() {
        let now = nowMilliseconds()
        if let cue = structuralTracker.claim(nowMs: now) {
            cancelStructuralDefault()
            fire(cue)
            return
        }
        guard gestureGate.claim(nowMs: now) else { return }
        fire(.light)
    }

    /// A sheet/fullscreen was dismissed. Backdrop taps and drag-to-close have
    /// no SwiftUI control behind them, so this is the one place that settles a
    /// dismissal tick; a close button that already settled its gesture is
    /// suppressed by the duplicate window.
    public func sheetDismissed() {
        let now = nowMilliseconds()
        if let cue = structuralTracker.claim(nowMs: now) {
            cancelStructuralDefault()
            fire(cue)
            return
        }
        guard !structuralTracker.wasSettled(
            nowMs: now,
            withinMs: StructuralHapticTracker.dismissalDuplicateWindowMs
        ) else {
            return
        }
        structuralTracker.begin(cue: .light, nowMs: now)
        _ = structuralTracker.claim(
            nowMs: now,
            requireGestureWithinMs: .infinity
        )
        fire(.light)
    }

    /// An explicit confirm/destructive/refused cue that belongs to a pointer
    /// gesture. If the structural tracker has a pending tap, this claims it so
    /// the light/default structure can't also fire; otherwise it starts and
    /// settles a gesture itself so a sheet dismiss on the same action is
    /// recognized as one tick.
    public func playGesture(_ cue: HapticCue?) {
        guard let cue else { return }
        let now = nowMilliseconds()
        if structuralTracker.claim(nowMs: now) != nil {
            cancelStructuralDefault()
            fire(cue)
            return
        }
        if structuralTracker.consumeSettled(
            nowMs: now,
            withinMs: StructuralHapticTracker.dismissalDuplicateWindowMs
        ) != nil {
            cancelStructuralDefault()
            fire(cue)
            return
        }
        guard !structuralTracker.wasSettled(
            nowMs: now,
            withinMs: StructuralHapticTracker.dismissalDuplicateWindowMs
        ) else {
            return
        }
        structuralTracker.begin(cue: cue, nowMs: now)
        _ = structuralTracker.claim(
            nowMs: now,
            requireGestureWithinMs: .infinity
        )
        fire(cue)
    }

    /// Plays a cue. Never throws, never blocks.
    public func play(_ cue: HapticCue?) {
        guard let cue else { return }
        fire(cue)
    }

    private func fire(_ cue: HapticCue) {
#if DEBUG
        debugEmissionCount += 1
#endif
        switch cue {
        case .light:
            impact(.light)
        case .medium:
            impact(.medium)
        case .selection:
            selectionGenerator().selectionChanged()
        case .warning:
            notificationGenerator().notificationOccurred(.warning)
        case .success:
            notificationGenerator().notificationOccurred(.success)
        case .error:
            notificationGenerator().notificationOccurred(.error)
        case let .pattern(pattern):
            fire(pattern: pattern)
        }
    }

    /// Plays a pattern as rigid impact ticks at the web's buzz offsets, as a
    /// fire-and-forget task. The first tick is synchronous so the buzz begins
    /// with the gesture; later ticks are spaced by `Task.sleep`.
    public func play(pattern: HapticPattern) {
        fire(pattern: pattern)
    }

    /// Delays a structural default tick one UI turn so a Button action (which
    /// may run after the structural `onEnded`) can promote the gesture to its
    /// explicit medium/warning/selection cue first. The tracker keeps the
    /// settled cue until the delayed tick fires, so a late action can still
    /// consume it instead of adding a second tick.
    private func scheduleStructuralDefault(_ cue: HapticCue) {
        structuralSettlementGeneration += 1
        let generation = structuralSettlementGeneration
        structuralDefaultSettlement = (cue: cue, generation: generation)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard structuralDefaultSettlement?.generation == generation,
                  structuralDefaultSettlement?.cue == cue else { return }
            structuralDefaultSettlement = nil
            _ = structuralTracker.consumeSettled(
                nowMs: nowMilliseconds(),
                withinMs: .infinity
            )
            fire(cue)
        }
    }

    private func cancelStructuralDefault() {
        structuralDefaultSettlement = nil
    }

    private func fire(pattern: HapticPattern) {
        switch pattern {
        case let .single(milliseconds):
            // The web's single-buzz vocabulary distinguishes by DURATION (hold
            // 150, hands-free armed 80, in-zone 45) and
            // UIImpactFeedbackGenerator has no duration axis. Approximate
            // with intensity instead so the cues stay distinguishable: a
            // longer cue reads as the heavier `.heavy` tick, a short one as
            // `.light` (review F11). The mapping is pure Core
            // (`HapticPatternWeights`), unit-tested; device pass re-checks it.
            impact(singleImpactStyle(milliseconds))
        case let .stutter(milliseconds):
            for (index, delay) in millisecondOffsets(milliseconds).enumerated() {
                if index == 0 {
                    impact(.rigid)
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
                        impact(.rigid)
                    }
                }
            }
        }
    }

    /// Maps a web single-buzz duration to an impact style via the pure Core
    /// weight (`HapticPatternWeights.singleWeight`).
    private func singleImpactStyle(_ milliseconds: Double) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch HapticPatternWeights.singleWeight(milliseconds: milliseconds) {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }

    /// Reduces a `navigator.vibrate`-style alternation (`[80, 60, 80]` =
    /// buzz 80 ms, pause 60 ms, buzz 80 ms) to the absolute buzz times:
    /// `[0, 140]`. This is exactly the web's rhythm, minus the durations the
    /// generator can't express.
    private func millisecondOffsets(_ pattern: [Double]) -> [Double] {
        var offsets: [Double] = []
        var cursor = 0.0
        for (index, value) in pattern.enumerated() {
            guard value > 0 else { continue }
            if index % 2 == 0 {
                offsets.append(cursor)
                cursor += value
            } else {
                cursor += value
            }
        }
        return offsets
    }

    private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = impacts[style] ?? {
            let fresh = UIImpactFeedbackGenerator(style: style)
            impacts[style] = fresh
            return fresh
        }()
        generator.prepare()
        generator.impactOccurred()
    }

    private func notificationGenerator() -> UINotificationFeedbackGenerator {
        let generator = notification ?? {
            let fresh = UINotificationFeedbackGenerator()
            notification = fresh
            return fresh
        }()
        generator.prepare()
        return generator
    }

    private func selectionGenerator() -> UISelectionFeedbackGenerator {
        let generator = selection ?? {
            let fresh = UISelectionFeedbackGenerator()
            selection = fresh
            return fresh
        }()
        generator.prepare()
        return generator
    }

    private func nowMilliseconds() -> Double {
        Date().timeIntervalSince1970 * 1_000
    }
}
