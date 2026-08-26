import Foundation

/// The four visual states of the native routine runner. There is deliberately
/// no transition/countdown state: the 3–2–1 cue is audio-only.
public enum RoutineRunnerVisualState: String, Codable, Equatable, Hashable, Sendable {
    case working
    case rest
    case paused
    case done

    public var title: String {
        switch self {
        case .working: return "WORKING OUT"
        case .rest: return "REST"
        case .paused: return "PAUSED"
        case .done: return "DONE"
        }
    }
}

/// Stage-local context used by both the runner UI and its next-phase preview.
/// A rest stage points at the repetition it is preparing, so the displayed
/// rep number stays useful while the timer is resting.
public struct RoutineRunnerStageContext: Equatable, Sendable {
    public let stage: RoutineStage
    public let stepNumber: Int
    public let stepCount: Int
    public let repetitionNumber: Int
    public let repetitionCount: Int
    public let repetitionsRemaining: Int

    public init(stage: RoutineStage, preset: RoutinePreset) {
        self.stage = stage
        self.stepCount = preset.steps.count

        guard stage.kind != .complete,
              preset.steps.indices.contains(stage.stepIndex)
        else {
            self.stepNumber = 0
            self.repetitionNumber = 0
            self.repetitionCount = 0
            self.repetitionsRemaining = 0
            return
        }

        let step = preset.steps[stage.stepIndex]
        let repetitions = max(1, step.repetitions)
        let displayedRepetition = stage.kind == .rest
            ? min(repetitions, max(1, stage.repetition + 1))
            : min(repetitions, max(1, stage.repetition))

        self.stepNumber = stage.stepIndex + 1
        self.repetitionNumber = displayedRepetition
        self.repetitionCount = repetitions
        // "To go" includes the currently displayed rep: Rep 3 of 8 means
        // six reps remain in this step, matching the approved runner copy.
        self.repetitionsRemaining = max(0, repetitions - displayedRepetition + 1)
    }
}

/// A render-ready, wall-clock-derived routine snapshot. The runner keeps the
/// existing `RoutineRun` and `PersistedRoutineRun` authorities; this type only
/// derives display context from them and never writes persistence.
public struct RoutineRunnerSnapshot: Equatable, Sendable {
    public let current: RoutineRunnerStageContext
    public let next: RoutineRunnerStageContext?
    public let visualState: RoutineRunnerVisualState
    public let stageNumber: Int
    public let stageCount: Int
    public let currentRemainingSeconds: Int
    public let currentRemainingFraction: Double
    public let totalRoutineSeconds: Int
    public let timelineElapsedSeconds: Int
    public let actualElapsedSeconds: Int
    public let timelineRemainingSeconds: Int
    public let isPaused: Bool
    public let isComplete: Bool

    public init(
        run: RoutineRun,
        preset: RoutinePreset,
        wallClock: PersistedRoutineRun,
        at date: Date
    ) {
        let activeStages = run.stages.filter { $0.kind != .complete }
        let totalSeconds = activeStages.reduce(0) { $0 + max(0, $1.durationSeconds) }
        let currentStage = run.currentStage
        let currentContext = RoutineRunnerStageContext(stage: currentStage, preset: preset)
        let nextContext: RoutineRunnerStageContext?
        if run.currentIndex + 1 < run.stages.count {
            let candidate = run.stages[run.currentIndex + 1]
            nextContext = candidate.kind == .complete
                ? nil
                : RoutineRunnerStageContext(stage: candidate, preset: preset)
        } else {
            nextContext = nil
        }

        let isComplete = run.isComplete
        let visualState: RoutineRunnerVisualState
        if isComplete {
            visualState = .done
        } else if run.isPaused {
            visualState = .paused
        } else {
            visualState = currentStage.kind == .rest ? .rest : .working
        }

        let nowMs = date.millisecondsSince1970
        let timelineElapsed = max(
            0,
            min(
                totalSeconds,
                Int(RoutineGate.elapsedS(wallClock, nowMs: nowMs).rounded(.down))
            )
        )
        let actualElapsed = max(
            0,
            Int(RoutineGate.realElapsedS(wallClock, nowMs: nowMs).rounded(.down))
        )
        let remaining = run.remainingSeconds(at: date)
        let fraction = currentStage.durationSeconds > 0
            ? min(1, max(0, Double(remaining) / Double(currentStage.durationSeconds)))
            : 0

        self.current = currentContext
        self.next = nextContext
        self.visualState = visualState
        self.stageNumber = isComplete
            ? activeStages.count
            : min(activeStages.count, max(1, run.currentIndex + 1))
        self.stageCount = activeStages.count
        self.currentRemainingSeconds = remaining
        self.currentRemainingFraction = fraction
        self.totalRoutineSeconds = totalSeconds
        self.timelineElapsedSeconds = timelineElapsed
        self.actualElapsedSeconds = actualElapsed
        self.timelineRemainingSeconds = max(0, totalSeconds - timelineElapsed)
        self.isPaused = run.isPaused
        self.isComplete = isComplete
    }
}
