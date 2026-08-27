import Foundation

public enum RoutineAudioStatus: String, Codable, Equatable, Sendable {
    case on
    case muted
    case unavailable

    public var label: String {
        switch self {
        case .on: return "Audio on"
        case .muted: return "Muted"
        case .unavailable: return "Audio unavailable"
        }
    }

    public var systemImage: String {
        switch self {
        case .on: return "speaker.wave.2.fill"
        case .muted: return "speaker.slash.fill"
        case .unavailable: return "speaker.slash.fill"
        }
    }
}

public enum RoutineAudioCue: Equatable, Sendable {
    case clockTick
    case countdown(second: Int)
    case phaseEnd
}

public enum RoutineAudioPolicy {
    public static func status(
        userMuted: Bool,
        systemMuted: Bool,
        systemAvailable: Bool
    ) -> RoutineAudioStatus {
        guard systemAvailable else { return .unavailable }
        return userMuted || systemMuted ? .muted : .on
    }

    public static func shouldPlay(
        _ cue: RoutineAudioCue,
        status: RoutineAudioStatus
    ) -> Bool {
        status == .on
    }
}

/// Pure cue de-duplication for the 250ms TimelineView. It advances its
/// observation cursor even when playback is muted/unavailable, so turning
/// audio back on cannot replay stale ticks or a missed 3–2–1 sequence.
public struct RoutineAudioCueController: Equatable, Sendable {
    private var observedStageID: UUID?
    private var lastRemainingSeconds: Int?
    private var phaseEndStageID: UUID?
    private var suppressStageEnd = false
    private var suspended = false

    public init() {}

    public mutating func observe(
        stage: RoutineStage,
        remainingSeconds: Int,
        isPaused: Bool
    ) -> RoutineAudioCue? {
        guard !suspended else { return nil }

        let remaining = max(0, remainingSeconds)
        if isPaused {
            observedStageID = stage.id
            lastRemainingSeconds = remaining
            return nil
        }

        if let previousStageID = observedStageID, previousStageID != stage.id {
            let shouldPlayEnd = !suppressStageEnd && phaseEndStageID != previousStageID
            observedStageID = stage.id
            lastRemainingSeconds = remaining
            phaseEndStageID = nil
            suppressStageEnd = false
            if shouldPlayEnd {
                return .phaseEnd
            }
            return nil
        }

        if observedStageID == nil {
            observedStageID = stage.id
            lastRemainingSeconds = remaining
            return remaining <= 3 ? countdownCue(for: stage, remainingSeconds: remaining) : nil
        }

        guard lastRemainingSeconds != remaining else { return nil }
        let previousRemaining = lastRemainingSeconds ?? remaining
        lastRemainingSeconds = remaining
        guard remaining < previousRemaining, remaining > 0 else { return nil }
        return countdownCue(for: stage, remainingSeconds: remaining)
    }

    /// Called immediately before the engine advances a naturally completed
    /// stage. The claim is idempotent, so a TimelineView refresh cannot repeat
    /// the phase-end sound.
    public mutating func phaseEnded(stageID: UUID) -> RoutineAudioCue? {
        guard !suspended, observedStageID == stageID, phaseEndStageID != stageID else {
            return nil
        }
        phaseEndStageID = stageID
        observedStageID = stageID
        lastRemainingSeconds = 0
        let shouldPlay = !suppressStageEnd
        suppressStageEnd = false
        return shouldPlay ? .phaseEnd : nil
    }

    /// Skip is an explicit user action, not a natural rep/phase ending. The
    /// next observation therefore re-anchors without emitting a completion
    /// cue for the skipped stage.
    public mutating func skipped(stageID: UUID) {
        phaseEndStageID = stageID
        suppressStageEnd = true
    }

    /// Pause/background stops future playback and leaves no catch-up cue when
    /// the runner becomes active again.
    public mutating func suspend() {
        suspended = true
    }

    /// Re-anchor the observation cursor without changing whether playback is
    /// suspended. This is safe for a paused/foregrounding run: the cursor can
    /// move, but no cue can escape until the caller explicitly resumes it.
    public mutating func reanchor(stage: RoutineStage, remainingSeconds: Int) {
        observedStageID = stage.id
        lastRemainingSeconds = max(0, remainingSeconds)
        phaseEndStageID = nil
        suppressStageEnd = false
    }

    /// Resume playback from a settled stage. The first observation is an
    /// anchor, so a foreground catch-up cannot emit a stale countdown or gong.
    public mutating func resume(stage: RoutineStage, remainingSeconds: Int) {
        reanchor(stage: stage, remainingSeconds: remainingSeconds)
        suspended = false
    }

    public mutating func reset() {
        observedStageID = nil
        lastRemainingSeconds = nil
        phaseEndStageID = nil
        suppressStageEnd = false
        suspended = false
    }

    private func countdownCue(
        for stage: RoutineStage,
        remainingSeconds: Int
    ) -> RoutineAudioCue? {
        guard remainingSeconds > 0 else { return nil }
        if remainingSeconds <= 3 {
            return .countdown(second: remainingSeconds)
        }
        return stage.kind == .work ? .clockTick : nil
    }
}
