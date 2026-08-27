import Foundation

/// #791 W3 — one subtle haptic cue when a hold's peak is *established*:
/// the first sample that is `settleDrop` kg below the rep's peak-so-far.
/// During a hang the force rises to the peak and then settles, so the
/// settle IS the moment the peak is known; cuing every rising sample would
/// be a haptic storm on a 10 Hz gauge. Cues exactly once per rep; `reset()`
/// arms the next rep.
public struct ForcePeakHapticTracker: Sendable, Equatable {
    /// How far below the rep peak the force must settle before the cue.
    public let settleDrop: Double
    public private(set) var peak: Double = 0
    public private(set) var hasCued: Bool = false

    public init(settleDrop: Double = 2) {
        self.settleDrop = settleDrop
    }

    /// Arms the next rep/pull.
    public mutating func reset() {
        peak = 0
        hasCued = false
    }

    /// Returns true at most once per reset, on the first sample where the
    /// force has settled `settleDrop` kg below the measured peak. Non-finite
    /// or no-measurement samples never cue.
    public mutating func shouldCue(forceKg: Double) -> Bool {
        guard forceKg.isFinite, !hasCued else { return false }
        if forceKg > peak {
            peak = forceKg
            return false
        }
        if peak > 0 && forceKg > 0 && peak - forceKg >= settleDrop {
            hasCued = true
            return true
        }
        return false
    }
}
