import Foundation

/// Pure lock-screen mapping for the Manual workout Live Activity (#763).
///
/// The running workout stays owned by `PhoneWorkoutEngine`; this module
/// derives the wire snapshot from the engine at call time and applies the
/// two lock-screen intents without needing another state machine. The app
/// target compiles it; the widget extension renders only the pushed
/// `ContentState` from `Sources/Shared`, never this model.
public enum ManualWorkoutActivityPhase: String, Codable, Equatable, Sendable {
    case climbing
    case resting
}

public enum ManualWorkoutActivityAction: String, Codable, Equatable, Sendable {
    case beginBoulder
    case endBoulder
}

public struct ManualWorkoutActivityEvent: Codable, Equatable, Sendable {
    public let action: ManualWorkoutActivityAction
    public let at: Date

    public init(action: ManualWorkoutActivityAction, at: Date) {
        self.action = action
        self.at = at
    }
}

public struct ManualWorkoutActivitySnapshot: Equatable, Sendable {
    public let phase: ManualWorkoutActivityPhase
    public let phaseStartedAt: Date
    public let restTargetSeconds: Int
    public let boulderCount: Int

    public init(
        phase: ManualWorkoutActivityPhase,
        phaseStartedAt: Date,
        restTargetSeconds: Int,
        boulderCount: Int
    ) {
        self.phase = phase
        self.phaseStartedAt = phaseStartedAt
        self.restTargetSeconds = restTargetSeconds
        self.boulderCount = boulderCount
    }

    /// Derive the card at one instant from the LIVE engine. `.restOver` is
    /// collapsed to `.resting` to match the Capacitor `WorkoutLiveActivity`
    /// wire contract — its card renders CLIMBING / RESTING only, with the
    /// native countdown simply reaching zero when the rest target passes.
    public init(engine: PhoneWorkoutEngine, restTarget: Int, now: Date = Date()) {
        let remaining = ManualWorkoutRest.remainingSeconds(
            now: now,
            workoutStartedAt: engine.draft.startedAt,
            attempts: engine.draft.attempts,
            targetSeconds: restTarget
        )
        let phase = ManualWorkoutRest.phase(
            attemptStartedAt: engine.attemptStartedAt,
            restRemaining: remaining
        )
        let phaseStartedAt: Date
        if let attemptStartedAt = engine.attemptStartedAt {
            phaseStartedAt = attemptStartedAt
        } else {
            phaseStartedAt = ManualWorkoutRest.restStartedAt(
                workoutStartedAt: engine.draft.startedAt,
                attempts: engine.draft.attempts
            )
        }

        self.phase = phase == .climbing ? .climbing : .resting
        self.phaseStartedAt = phaseStartedAt
        self.restTargetSeconds = ManualWorkoutRest.validatedTarget(restTarget)
        self.boulderCount = engine.draft.attempts.count
    }

    /// Apply one lock-screen intent to the card natively. Invalid transitions
    /// (Boulder while climbing / Stop while resting) are no-ops, so replaying
    /// an already-applied action is safe.
    public func applying(_ event: ManualWorkoutActivityEvent) -> ManualWorkoutActivitySnapshot {
        switch event.action {
        case .beginBoulder where phase == .resting:
            return ManualWorkoutActivitySnapshot(
                phase: .climbing,
                phaseStartedAt: event.at,
                restTargetSeconds: restTargetSeconds,
                boulderCount: boulderCount
            )
        case .endBoulder where phase == .climbing:
            return ManualWorkoutActivitySnapshot(
                phase: .resting,
                phaseStartedAt: event.at,
                restTargetSeconds: restTargetSeconds,
                boulderCount: boulderCount + 1
            )
        default:
            return self
        }
    }
}
