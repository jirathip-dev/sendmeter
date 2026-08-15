import Foundation

public enum WorkoutEngineError: Error, Equatable, Sendable {
    case workoutAlreadyFinished
    case attemptAlreadyRunning
    case noAttemptRunning
    case invalidEndTime
    case emptyWorkout
}

public struct PhoneWorkoutEngine: Codable, Equatable, Sendable {
    public private(set) var draft: WorkoutDraft
    public private(set) var attemptStartedAt: Date?

    public init(
        accountUserID: UUID,
        phase: PhaseID,
        startedAt: Date = Date(),
        type: String = "board",
        typeLabel: String = "Board Climbing",
        rpe: Double = 7
    ) {
        self.draft = WorkoutDraft(
            accountUserID: accountUserID,
            startedAt: startedAt,
            type: type,
            typeLabel: typeLabel,
            rpe: rpe,
            phase: phase
        )
        self.attemptStartedAt = nil
    }

    public mutating func startAttempt(at date: Date = Date()) throws {
        guard draft.endedAt == nil else { throw WorkoutEngineError.workoutAlreadyFinished }
        guard attemptStartedAt == nil else { throw WorkoutEngineError.attemptAlreadyRunning }
        guard date >= draft.startedAt else { throw WorkoutEngineError.invalidEndTime }
        attemptStartedAt = date
    }

    @discardableResult
    public mutating func endAttempt(at date: Date = Date()) throws -> WorkoutAttempt {
        guard draft.endedAt == nil else { throw WorkoutEngineError.workoutAlreadyFinished }
        guard let started = attemptStartedAt else { throw WorkoutEngineError.noAttemptRunning }
        guard date >= started else { throw WorkoutEngineError.invalidEndTime }
        let duration = max(1, Int(date.timeIntervalSince(started).rounded()))
        let attempt = WorkoutAttempt(startedAt: started, durationSeconds: duration)
        draft.attempts.append(attempt)
        attemptStartedAt = nil
        return attempt
    }

    public mutating func cancelAttempt() {
        attemptStartedAt = nil
    }

    public mutating func setRPE(_ rpe: Double) {
        draft.rpe = min(10, max(1, rpe))
    }

    public mutating func setWorkoutType(id: String, label: String) {
        draft.type = id
        draft.typeLabel = label
    }

    @discardableResult
    public mutating func finish(at date: Date = Date()) throws -> WorkoutDraft {
        guard draft.endedAt == nil else { throw WorkoutEngineError.workoutAlreadyFinished }
        guard date >= draft.startedAt else { throw WorkoutEngineError.invalidEndTime }
        if attemptStartedAt != nil {
            _ = try endAttempt(at: date)
        }
        guard !draft.attempts.isEmpty else { throw WorkoutEngineError.emptyWorkout }
        draft.endedAt = date
        return draft
    }

    public var elapsedSeconds: Int {
        let end = draft.endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(draft.startedAt)))
    }

    public var durationMinutes: Int {
        guard let endedAt = draft.endedAt else {
            return max(1, Int(ceil(Date().timeIntervalSince(draft.startedAt) / 60)))
        }
        return max(1, min(600, Int(ceil(endedAt.timeIntervalSince(draft.startedAt) / 60))))
    }
}

// MARK: - Guided routines

public enum RoutineStageKind: String, Codable, Sendable {
    case work
    case rest
    case complete
}

public struct RoutineStage: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: RoutineStageKind
    public let label: String
    public let detail: String?
    public let stepIndex: Int
    public let repetition: Int
    public let durationSeconds: Int

    public init(
        id: UUID = UUID(),
        kind: RoutineStageKind,
        label: String,
        detail: String?,
        stepIndex: Int,
        repetition: Int,
        durationSeconds: Int
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.stepIndex = stepIndex
        self.repetition = repetition
        self.durationSeconds = durationSeconds
    }
}

public enum RoutineEngine {
    public static func stages(for preset: RoutinePreset) -> [RoutineStage] {
        var stages: [RoutineStage] = []
        for (stepIndex, step) in preset.steps.enumerated() {
            let reps = max(1, step.repetitions)
            for repetition in 1...reps {
                stages.append(
                    RoutineStage(
                        kind: .work,
                        label: step.label,
                        detail: step.detail,
                        stepIndex: stepIndex,
                        repetition: repetition,
                        durationSeconds: max(1, step.seconds)
                    )
                )
                if repetition < reps && step.restSeconds > 0 {
                    stages.append(
                        RoutineStage(
                            kind: .rest,
                            label: "Rest",
                            detail: "Before \(step.label) \(repetition + 1)/\(reps)",
                            stepIndex: stepIndex,
                            repetition: repetition,
                            durationSeconds: step.restSeconds
                        )
                    )
                }
            }
        }
        stages.append(
            RoutineStage(
                kind: .complete,
                label: "Complete",
                detail: nil,
                stepIndex: max(0, preset.steps.count - 1),
                repetition: 1,
                durationSeconds: 0
            )
        )
        return stages
    }
}

public struct RoutineRun: Codable, Equatable, Sendable {
    public let presetID: UUID
    public let stages: [RoutineStage]
    public private(set) var currentIndex: Int
    public private(set) var stageStartedAt: Date?
    public private(set) var pausedElapsedSeconds: Int
    public private(set) var isPaused: Bool

    public init(preset: RoutinePreset) {
        self.presetID = preset.id
        self.stages = RoutineEngine.stages(for: preset)
        self.currentIndex = 0
        self.stageStartedAt = nil
        self.pausedElapsedSeconds = 0
        self.isPaused = false
    }

    public var currentStage: RoutineStage { stages[currentIndex] }
    public var isComplete: Bool { currentStage.kind == .complete }

    public mutating func start(at date: Date = Date()) {
        guard !isComplete else { return }
        stageStartedAt = date
        pausedElapsedSeconds = 0
        isPaused = false
    }

    public mutating func pause(at date: Date = Date()) {
        guard !isPaused, let started = stageStartedAt, !isComplete else { return }
        pausedElapsedSeconds += max(0, Int(date.timeIntervalSince(started)))
        stageStartedAt = nil
        isPaused = true
    }

    public mutating func resume(at date: Date = Date()) {
        guard isPaused, !isComplete else { return }
        stageStartedAt = date
        isPaused = false
    }

    public func elapsedSeconds(at date: Date = Date()) -> Int {
        let live = stageStartedAt.map { max(0, Int(date.timeIntervalSince($0))) } ?? 0
        return pausedElapsedSeconds + live
    }

    public func remainingSeconds(at date: Date = Date()) -> Int {
        max(0, currentStage.durationSeconds - elapsedSeconds(at: date))
    }

    @discardableResult
    public mutating func advanceIfNeeded(at date: Date = Date()) -> Bool {
        guard !isComplete, elapsedSeconds(at: date) >= currentStage.durationSeconds else {
            return false
        }
        advance(at: date)
        return true
    }

    public mutating func advance(at date: Date = Date()) {
        guard currentIndex < stages.count - 1 else { return }
        currentIndex += 1
        pausedElapsedSeconds = 0
        isPaused = false
        stageStartedAt = isComplete ? nil : date
    }

    public mutating func skip(at date: Date = Date()) {
        advance(at: date)
    }
}
