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
    public let workoutStartedAt: Date
    public let action: ManualWorkoutActivityAction
    public let at: Date

    public init(workoutStartedAt: Date, action: ManualWorkoutActivityAction, at: Date) {
        self.workoutStartedAt = workoutStartedAt
        self.action = action
        self.at = at
    }

    public func matches(workoutStartedAt: Date) -> Bool {
        self.workoutStartedAt == workoutStartedAt
    }
}

/// Filters queued lock-screen actions to the workout that owns them. A stale
/// event from a previous workout must never replay into the next one.
public enum ManualWorkoutActivityDrain {
    public static func matching(
        _ events: [ManualWorkoutActivityEvent],
        workoutStartedAt: Date
    ) -> [ManualWorkoutActivityEvent] {
        events.filter { $0.matches(workoutStartedAt: workoutStartedAt) }
    }
}

/// Replays lock-screen intents into the authoritative phone engine. Delivery
/// is at-least-once, so an already-applied or no-longer-valid event is an
/// expected per-event no-op; it must not roll back earlier successful events
/// from the same drained batch.
public enum ManualWorkoutActivityReplay {
    public static func applying(
        _ events: [ManualWorkoutActivityEvent],
        to engine: PhoneWorkoutEngine
    ) -> PhoneWorkoutEngine {
        var current = engine
        for event in events {
            do {
                switch event.action {
                case .beginBoulder:
                    try current.startAttempt(at: event.at)
                case .endBoulder:
                    _ = try current.endAttempt(at: event.at)
                }
            } catch {
                // Duplicate/stale lock-screen delivery is deliberately ignored
                // without undoing transitions already accepted in this batch.
                continue
            }
        }
        return current
    }
}

/// Decides whether a launch/foreground sweep may end manual workout
/// activities. The in-memory active-workout marker is set by
/// `ManualWorkoutActivityManager.start` and cleared by `end`, so a live
/// workout is protected even if ActivityKit has temporarily dropped the
/// in-process handle. The manual workout itself (#936: held in memory by
/// `ManualWorkoutLifecycleCoordinator`) is never persisted, so after a relaunch
/// there is by definition no live workout to protect and the sweep may retire
/// stranded cards.
public enum ManualWorkoutActivityReconcileGuard {
    public static func shouldReconcile(
        isActive: Bool,
        activeWorkoutStartedAt: Date?
    ) -> Bool {
        !isActive && activeWorkoutStartedAt == nil
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
