import SendmeterCore
import UIKit

/// The app's single haptics touch point (#656). The DECISION layer lives in
/// Core (`Haptics.swift`); this dispatcher is the one UIKit surface that turns
/// a `HapticCue` into feedback-generator calls. Feature code calls
/// `Haptics.shared.play(...)` (or `tap()` / `sheetPresented()`) and never
/// touches `UIImpactFeedbackGenerator` directly (grep-assertable).
///
/// All calls are fire-and-forget: a failure can never propagate into the
/// action it accompanies, and no generator outlives the play it serves. The
/// feedback generators are recreated per play because they must be prepared on
/// the run loop the gesture happened on to be reliable — holding one app-wide
/// instance that the UI thread never touches (a real risk with SwiftUI's
/// background-diffed state) silently mutes the whole app.
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
        case .warning:
            notification(.warning)
        case .success:
            notification(.success)
        case .error:
            notification(.error)
        case let .pattern(pattern):
            play(pattern: pattern)
        }
    }

    /// Plays a pattern as rigid impact ticks at the web's buzz offsets, as a
    /// fire-and-forget task. The first tick is synchronous so the buzz begins
    /// with the gesture; later ticks are spaced by `Task.sleep`.
    public func play(pattern: HapticPattern) {
        switch pattern {
        case .single:
            // The web encodes a single-buzz distinction in duration (hold 150
            // vs armed 80 vs in-zone 45); UIImpactFeedbackGenerator has no
            // duration axis, so a single buzz is one rigid tick regardless —
            // the distinction still reads because the single/pattern split
            // carries the semantic content.
            impact(.rigid)
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
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    private func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    private func nowMilliseconds() -> Double {
        Date().timeIntervalSince1970 * 1_000
    }
}
