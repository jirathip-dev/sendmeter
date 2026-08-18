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
    private var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private var notification: UINotificationFeedbackGenerator?
    private var selection: UISelectionFeedbackGenerator?
    private init() {}

    /// A user-initiated tap landed on a control that presents a sheet/full-
    /// screen. Arms the gate so that surface's presentation can spend the
    /// tick. Nothing fires here — a sheet presented later does.
    public func tap() {
        gestureGate.tap(nowMs: nowMilliseconds())
    }

    /// A sheet/fullscreen just presented. Fires a light tick only when a tap
    /// armed the gate within the freshness window and no other consumer has
    /// spent this gesture's tick.
    public func sheetPresented() {
        guard gestureGate.claim(nowMs: nowMilliseconds()) else { return }
        play(.light)
    }

    /// Plays a cue. Never throws, never blocks.
    public func play(_ cue: HapticCue?) {
        guard let cue else { return }
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
            play(pattern: pattern)
        }
    }

    /// Plays a pattern as rigid impact ticks at the web's buzz offsets, as a
    /// fire-and-forget task. The first tick is synchronous so the buzz begins
    /// with the gesture; later ticks are spaced by `Task.sleep`.
    public func play(pattern: HapticPattern) {
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
