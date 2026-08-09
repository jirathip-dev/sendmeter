import Foundation

/// Boundary events are replayed in order for persistence, but a foreground
/// tick can cross many historical boundaries at once.  The watch should cue
/// only the latest haptic-worthy boundary from that batch rather than replay
/// a storm of stale direction/rest cues.
public enum GuidedForceHapticPolicy {
    public static func latestCueIndex(in events: [GuidedForceRunEvent]) -> Int? {
        events.indices.reversed().first { index in
            switch events[index] {
            case .prepare, .startMovement, .direction, .startStaticHold,
                 .rest, .completed, .stopped:
                return true
            case .finishMovement, .finishStaticHold:
                return false
            }
        }
    }
}
