import Foundation

/// Pure timing rules for the native Manual workout fullscreen.
///
/// The running workout remains owned by `PhoneWorkoutEngine`; this module only
/// derives the current rest window from the immutable workout start and the
/// attempts already recorded. That makes minimize/resume and rest-target
/// changes deterministic without adding a second state machine.
public enum ManualWorkoutPhase: Equatable, Sendable {
    case climbing
    case resting
    case restOver
}

public enum ManualWorkoutRest {
    public static let restTargetKey = "sendmeter:rest-target-s"
    public static let restTargets = [60, 120, 180, 300]
    public static let defaultRestTarget = 180

    public struct Schedule: Equatable, Sendable {
        public let key: String
        public let restStartedAt: Date
        public let deadline: Date
        public let targetSeconds: Int

        public init(restStartedAt: Date, targetSeconds: Int) {
            let validatedTarget = ManualWorkoutRest.validatedTarget(targetSeconds)
            self.restStartedAt = restStartedAt
            self.deadline = restStartedAt.addingTimeInterval(TimeInterval(validatedTarget))
            self.targetSeconds = validatedTarget
            self.key = ManualWorkoutRest.alertKey(
                restStartedAt: restStartedAt,
                targetSeconds: validatedTarget
            )
        }
    }

    public enum FeedbackDecision: Equatable, Sendable {
        case none
        case playForeground
        case suppressForBackgroundNotification
    }

    public static func validatedTarget(_ seconds: Int) -> Int {
        restTargets.contains(seconds) ? seconds : defaultRestTarget
    }

    /// The current rest starts at the end of the last completed attempt. A
    /// brand-new workout has been resting since its start, matching the web
    /// fullscreen and making its first countdown immediately useful.
    public static func restStartedAt(
        workoutStartedAt: Date,
        attempts: [WorkoutAttempt]
    ) -> Date {
        guard let last = attempts.last else { return workoutStartedAt }
        return last.startedAt.addingTimeInterval(TimeInterval(last.durationSeconds))
    }

    public static func schedule(
        workoutStartedAt: Date,
        attempts: [WorkoutAttempt],
        targetSeconds: Int
    ) -> Schedule {
        Schedule(
            restStartedAt: restStartedAt(
                workoutStartedAt: workoutStartedAt,
                attempts: attempts
            ),
            targetSeconds: targetSeconds
        )
    }

    public static func notificationDelay(
        now: Date,
        deadline: Date,
        minimumDelay: TimeInterval = 1
    ) -> TimeInterval? {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0, minimumDelay > 0 else { return nil }
        return max(minimumDelay, remaining)
    }

    public static func feedbackDecision(
        now: Date,
        schedule: Schedule,
        sceneIsActive: Bool,
        deadlinePassedWhileBackground: Bool,
        notificationWasScheduled: Bool,
        lastFeedbackKey: String?
    ) -> FeedbackDecision {
        guard sceneIsActive, now >= schedule.deadline, lastFeedbackKey != schedule.key else {
            return .none
        }

        if deadlinePassedWhileBackground, notificationWasScheduled {
            return .suppressForBackgroundNotification
        }

        return .playForeground
    }

    public static func elapsedSeconds(
        now: Date,
        workoutStartedAt: Date,
        attempts: [WorkoutAttempt]
    ) -> TimeInterval {
        max(0, now.timeIntervalSince(restStartedAt(workoutStartedAt: workoutStartedAt, attempts: attempts)))
    }

    public static func remainingSeconds(
        now: Date,
        workoutStartedAt: Date,
        attempts: [WorkoutAttempt],
        targetSeconds: Int
    ) -> TimeInterval {
        max(
            0,
            TimeInterval(validatedTarget(targetSeconds)) - elapsedSeconds(
                now: now,
                workoutStartedAt: workoutStartedAt,
                attempts: attempts
            )
        )
    }

    public static func progress(
        now: Date,
        workoutStartedAt: Date,
        attempts: [WorkoutAttempt],
        targetSeconds: Int
    ) -> Double {
        let target = TimeInterval(validatedTarget(targetSeconds))
        let elapsed = elapsedSeconds(
            now: now,
            workoutStartedAt: workoutStartedAt,
            attempts: attempts
        )
        return min(1, max(0, elapsed / target))
    }

    public static func phase(
        attemptStartedAt: Date?,
        restRemaining: TimeInterval
    ) -> ManualWorkoutPhase {
        if attemptStartedAt != nil { return .climbing }
        return restRemaining <= 0 ? .restOver : .resting
    }

    /// Includes the selected target so changing it after zero can re-arm the
    /// one-shot alert for the newly selected countdown.
    public static func alertKey(restStartedAt: Date, targetSeconds: Int) -> String {
        "\(restStartedAt.timeIntervalSince1970)-\(validatedTarget(targetSeconds))"
    }
}
