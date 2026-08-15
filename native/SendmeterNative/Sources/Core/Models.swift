import Foundation

// MARK: - Training phases

public enum PhaseID: String, Codable, CaseIterable, Sendable, Identifiable {
    case capacity
    case strength
    case power
    case execution

    public var id: String { rawValue }
}

public struct PhaseDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: PhaseID
    public let name: String
    public let colorHex: String
    public let acwrLow: Double
    public let acwrHigh: Double
    public let weeks: String
    public let summary: String
    public let tools: [String]
    public let intensity: String

    public init(
        id: PhaseID,
        name: String,
        colorHex: String,
        acwrLow: Double,
        acwrHigh: Double,
        weeks: String,
        summary: String,
        tools: [String],
        intensity: String
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.acwrLow = acwrLow
        self.acwrHigh = acwrHigh
        self.weeks = weeks
        self.summary = summary
        self.tools = tools
        self.intensity = intensity
    }
}

public enum PhaseCatalog {
    public static let all: [PhaseDefinition] = [
        PhaseDefinition(
            id: .capacity,
            name: "Capacity",
            colorHex: "#2E96F0",
            acwrLow: 0.9,
            acwrHigh: 1.1,
            weeks: "4–6 wks",
            summary: "Aerobic base, density repeaters, high volume low intensity",
            tools: ["Density repeaters", "ARC traversing", "Low-intensity hangs"],
            intensity: "50–65%"
        ),
        PhaseDefinition(
            id: .strength,
            name: "Strength",
            colorHex: "#DDB13A",
            acwrLow: 0.8,
            acwrHigh: 1.0,
            weeks: "3–5 wks",
            summary: "Max recruitment, heavy hangs, limit bouldering",
            tools: ["Max hangs 7–10s", "Limit bouldering", "Weighted fingerboard"],
            intensity: "85–100%"
        ),
        PhaseDefinition(
            id: .power,
            name: "Power",
            colorHex: "#E5743A",
            acwrLow: 0.8,
            acwrHigh: 1.0,
            weeks: "2–4 wks",
            summary: "Explosive contact strength, campus board, dynamic moves",
            tools: ["Campus board", "Dynamic bouldering", "Limit board problems"],
            intensity: "Max effort"
        ),
        PhaseDefinition(
            id: .execution,
            name: "Execution",
            colorHex: "#7B83EB",
            acwrLow: 0.7,
            acwrHigh: 0.9,
            weeks: "2–3 wks",
            summary: "Performance consolidation, projecting, fatigue clearance",
            tools: ["Projecting", "Footwork drills", "Easy-moderate volume"],
            intensity: "Moderate"
        )
    ]

    public static func definition(for id: PhaseID) -> PhaseDefinition {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

public struct PhasePeriod: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var phase: PhaseID
    public var startedOn: String
    public var endedOn: String?

    public init(id: UUID, phase: PhaseID, startedOn: String, endedOn: String?) {
        self.id = id
        self.phase = phase
        self.startedOn = startedOn
        self.endedOn = endedOn
    }
}

public struct UserSettings: Codable, Equatable, Sendable {
    public var currentPhase: PhaseID
    public var phaseStartDate: String

    public init(currentPhase: PhaseID = .capacity, phaseStartDate: String) {
        self.currentPhase = currentPhase
        self.phaseStartDate = phaseStartDate
    }
}

// MARK: - Training sessions

public enum WorkoutSource: String, Codable, Sendable {
    case watch
    case phone
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var date: String
    public var type: String
    public var typeLabel: String
    public var durationMinutes: Int
    public var rpe: Double
    public var rpeConfirmed: Bool
    public var load: Double
    public var note: String
    public var phase: PhaseID
    public var groupID: UUID?
    public var workoutSource: WorkoutSource?
    public var pending: Bool
    public var accountUserID: UUID?

    public init(
        id: UUID,
        date: String,
        type: String,
        typeLabel: String,
        durationMinutes: Int,
        rpe: Double,
        rpeConfirmed: Bool = true,
        load: Double? = nil,
        note: String = "",
        phase: PhaseID,
        groupID: UUID? = nil,
        workoutSource: WorkoutSource? = nil,
        pending: Bool = false,
        accountUserID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.type = type
        self.typeLabel = typeLabel
        self.durationMinutes = durationMinutes
        self.rpe = rpe
        self.rpeConfirmed = rpeConfirmed
        self.load = load ?? Double(durationMinutes) * rpe
        self.note = note
        self.phase = phase
        self.groupID = groupID
        self.workoutSource = workoutSource
        self.pending = pending
        self.accountUserID = accountUserID
    }
}

public struct SessionDraft: Codable, Equatable, Sendable {
    public var date: String
    public var type: String
    public var typeLabel: String
    public var durationMinutes: Int
    public var rpe: Double
    public var note: String
    public var phase: PhaseID

    public init(
        date: String,
        type: String,
        typeLabel: String,
        durationMinutes: Int,
        rpe: Double,
        note: String,
        phase: PhaseID
    ) {
        self.date = date
        self.type = type
        self.typeLabel = typeLabel
        self.durationMinutes = durationMinutes
        self.rpe = rpe
        self.note = note
        self.phase = phase
    }
}

public struct SessionTypeDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let defaultRPE: Double
    public let defaultDurationMinutes: Int

    public init(id: String, label: String, defaultRPE: Double, defaultDurationMinutes: Int) {
        self.id = id
        self.label = label
        self.defaultRPE = defaultRPE
        self.defaultDurationMinutes = defaultDurationMinutes
    }
}

public enum SessionTypeCatalog {
    public static let all: [SessionTypeDefinition] = [
        .init(id: "fingerboard", label: "Fingerboard", defaultRPE: 6, defaultDurationMinutes: 45),
        .init(id: "board", label: "Board Climbing", defaultRPE: 8, defaultDurationMinutes: 60),
        .init(id: "gym", label: "Gym Session", defaultRPE: 6, defaultDurationMinutes: 90),
        .init(id: "outdoor", label: "Outdoor / Projecting", defaultRPE: 5, defaultDurationMinutes: 180),
        .init(id: "antagonist", label: "Antagonist / Mobility", defaultRPE: 4, defaultDurationMinutes: 30),
        .init(id: "routine", label: "Routine", defaultRPE: 4, defaultDurationMinutes: 20),
        .init(id: "arc", label: "ARC / Traversing", defaultRPE: 4, defaultDurationMinutes: 40),
        .init(id: "campus", label: "Campus Board", defaultRPE: 9, defaultDurationMinutes: 30),
        .init(id: "custom", label: "Custom", defaultRPE: 6, defaultDurationMinutes: 60),
        .init(id: "auto", label: "Auto-tracked", defaultRPE: 6, defaultDurationMinutes: 60),
        .init(id: "tindeq", label: "Tindeq", defaultRPE: 5, defaultDurationMinutes: 30)
    ]

    public static func definition(for id: String) -> SessionTypeDefinition {
        all.first(where: { $0.id == id }) ?? all.first(where: { $0.id == "custom" })!
    }
}

// MARK: - Health and load

public struct HealthMetric: Codable, Equatable, Sendable, Identifiable {
    public var id: String { date }
    public let date: String
    public let readiness: Int?
    public let zone: String?
    public let computedAt: Date
    public let hrvSDNNMilliseconds: Double?
    public let restingHeartRate: Double?
    public let sleepHours: Double?
    public let sleepDeepHours: Double?
    public let sleepREMHours: Double?
    public let bodyMassKilograms: Double?
    public let respiratoryRate: Double?

    public init(
        date: String,
        readiness: Int?,
        zone: String?,
        computedAt: Date,
        hrvSDNNMilliseconds: Double?,
        restingHeartRate: Double?,
        sleepHours: Double?,
        sleepDeepHours: Double?,
        sleepREMHours: Double?,
        bodyMassKilograms: Double?,
        respiratoryRate: Double?
    ) {
        self.date = date
        self.readiness = readiness
        self.zone = zone
        self.computedAt = computedAt
        self.hrvSDNNMilliseconds = hrvSDNNMilliseconds
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
        self.sleepDeepHours = sleepDeepHours
        self.sleepREMHours = sleepREMHours
        self.bodyMassKilograms = bodyMassKilograms
        self.respiratoryRate = respiratoryRate
    }
}

public struct ACWRData: Codable, Equatable, Sendable {
    public let acute: Double
    public let chronic: Double
    public let ratio: Double?

    public init(acute: Double, chronic: Double, ratio: Double?) {
        self.acute = acute
        self.chronic = chronic
        self.ratio = ratio
    }
}

public enum ACWRStatus: String, Codable, Sendable {
    case noData = "No data"
    case underTraining = "Under-training"
    case low = "Low"
    case optimal = "Optimal"
    case caution = "Caution"
    case danger = "Danger"
}

public struct WeeklyLoad: Codable, Equatable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let total: Double

    public init(label: String, total: Double) {
        self.label = label
        self.total = total
    }
}

// MARK: - Force / Tindeq

public struct TindeqSample: Codable, Equatable, Sendable {
    public let milliseconds: Double
    public let kilograms: Double

    public init(milliseconds: Double, kilograms: Double) {
        self.milliseconds = milliseconds
        self.kilograms = kilograms
    }
}

public enum TindeqSide: String, Codable, CaseIterable, Sendable, Identifiable {
    case unspecified = ""
    case left
    case right
    case both

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unspecified: return "Not set"
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Both"
        }
    }
}

public enum RecordedZone: String, Codable, CaseIterable, Sendable {
    case warmup
    case prehab
    case strength
    case power
    case capacity
    case endurance
}

public enum ForceProtocolMode: String, Codable, Sendable {
    case hold
    case reverseAction = "reverse_action"
}

public enum RecordingSource: String, Codable, Sendable {
    case dynamometer
    case manual
}

public enum RecordingOutcome: String, Codable, Sendable {
    case tooEasy = "too_easy"
    case good
    case failed
}

public struct CadenceMarker: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case out
        case `return`
    }

    public let milliseconds: Int
    public let repetition: Int
    public let direction: Direction

    public init(milliseconds: Int, repetition: Int, direction: Direction) {
        self.milliseconds = milliseconds
        self.repetition = repetition
        self.direction = direction
    }
}

public struct ReverseActionMetrics: Codable, Equatable, Sendable {
    public let meanKilograms: Double?
    public let coefficientOfVariationPercent: Double?
    public let inTargetPercent: Double?
    public let timeUnderTensionMilliseconds: Int
    public let driftPercent: Double?
    public let cadenceAdherencePercent: Double

    public init(
        meanKilograms: Double?,
        coefficientOfVariationPercent: Double?,
        inTargetPercent: Double?,
        timeUnderTensionMilliseconds: Int,
        driftPercent: Double?,
        cadenceAdherencePercent: Double
    ) {
        self.meanKilograms = meanKilograms
        self.coefficientOfVariationPercent = coefficientOfVariationPercent
        self.inTargetPercent = inTargetPercent
        self.timeUnderTensionMilliseconds = timeUnderTensionMilliseconds
        self.driftPercent = driftPercent
        self.cadenceAdherencePercent = cadenceAdherencePercent
    }
}

public struct TindeqRecording: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let recordedAt: Date
    public let durationMilliseconds: Int
    public let peakKilograms: Double?
    public let averageKilograms: Double?
    public let sampleCount: Int
    public var note: String
    public var tag: String
    public var side: TindeqSide
    public var groupID: UUID?
    public let protocolRunID: UUID?
    public let setNumber: Int?
    public let zone: RecordedZone?
    public let source: RecordingSource
    public let externalLoadKilograms: Double?
    public let outcome: RecordingOutcome?
    public let plannedDurationMilliseconds: Int?
    public let actualDurationMilliseconds: Int?
    public let repetitionNumber: Int?
    public let protocolMode: ForceProtocolMode
    public let targetKilograms: Double?
    public let targetLowKilograms: Double?
    public let targetHighKilograms: Double?
    public let cadenceOutSeconds: Double?
    public let cadenceReturnSeconds: Double?
    public let cadenceMarkers: [CadenceMarker]?
    public let setMetrics: ReverseActionMetrics?
    public let setupNote: String
    public let capacityEvidence: Bool?
    public let completedRepetitions: Int?
    public let completionStatus: String?

    public init(
        id: UUID,
        recordedAt: Date,
        durationMilliseconds: Int,
        peakKilograms: Double?,
        averageKilograms: Double?,
        sampleCount: Int,
        note: String,
        tag: String,
        side: TindeqSide,
        groupID: UUID?,
        protocolRunID: UUID? = nil,
        setNumber: Int? = nil,
        zone: RecordedZone? = nil,
        source: RecordingSource = .dynamometer,
        externalLoadKilograms: Double? = nil,
        outcome: RecordingOutcome? = nil,
        plannedDurationMilliseconds: Int? = nil,
        actualDurationMilliseconds: Int? = nil,
        repetitionNumber: Int? = nil,
        protocolMode: ForceProtocolMode = .hold,
        targetKilograms: Double? = nil,
        targetLowKilograms: Double? = nil,
        targetHighKilograms: Double? = nil,
        cadenceOutSeconds: Double? = nil,
        cadenceReturnSeconds: Double? = nil,
        cadenceMarkers: [CadenceMarker]? = nil,
        setMetrics: ReverseActionMetrics? = nil,
        setupNote: String = "",
        capacityEvidence: Bool? = nil,
        completedRepetitions: Int? = nil,
        completionStatus: String? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.durationMilliseconds = durationMilliseconds
        self.peakKilograms = peakKilograms
        self.averageKilograms = averageKilograms
        self.sampleCount = sampleCount
        self.note = note
        self.tag = tag
        self.side = side
        self.groupID = groupID
        self.protocolRunID = protocolRunID
        self.setNumber = setNumber
        self.zone = zone
        self.source = source
        self.externalLoadKilograms = externalLoadKilograms
        self.outcome = outcome
        self.plannedDurationMilliseconds = plannedDurationMilliseconds
        self.actualDurationMilliseconds = actualDurationMilliseconds
        self.repetitionNumber = repetitionNumber
        self.protocolMode = protocolMode
        self.targetKilograms = targetKilograms
        self.targetLowKilograms = targetLowKilograms
        self.targetHighKilograms = targetHighKilograms
        self.cadenceOutSeconds = cadenceOutSeconds
        self.cadenceReturnSeconds = cadenceReturnSeconds
        self.cadenceMarkers = cadenceMarkers
        self.setMetrics = setMetrics
        self.setupNote = setupNote
        self.capacityEvidence = capacityEvidence
        self.completedRepetitions = completedRepetitions
        self.completionStatus = completionStatus
    }
}

public struct NewTindeqRecording: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let accountUserID: UUID
    public let recordedAt: Date
    public let durationMilliseconds: Int
    public let peakKilograms: Double?
    public let averageKilograms: Double?
    public var note: String
    public var tag: String
    public var side: TindeqSide
    public var groupID: UUID?
    public let protocolRunID: UUID?
    public let setNumber: Int?
    public let zone: RecordedZone?
    public let samples: [TindeqSample]
    public let source: RecordingSource
    public let externalLoadKilograms: Double?
    public let outcome: RecordingOutcome?
    public let plannedDurationMilliseconds: Int?
    public let actualDurationMilliseconds: Int?
    public let repetitionNumber: Int?
    public let protocolMode: ForceProtocolMode
    public let targetKilograms: Double?
    public let targetLowKilograms: Double?
    public let targetHighKilograms: Double?
    public let cadenceOutSeconds: Double?
    public let cadenceReturnSeconds: Double?
    public let cadenceMarkers: [CadenceMarker]?
    public let setMetrics: ReverseActionMetrics?
    public let setupNote: String
    public let capacityEvidence: Bool?
    public let completedRepetitions: Int?
    public let completionStatus: String?

    public init(
        id: UUID = UUID(),
        accountUserID: UUID,
        recordedAt: Date = Date(),
        durationMilliseconds: Int,
        peakKilograms: Double?,
        averageKilograms: Double?,
        note: String,
        tag: String,
        side: TindeqSide,
        groupID: UUID?,
        protocolRunID: UUID? = nil,
        setNumber: Int? = nil,
        zone: RecordedZone? = nil,
        samples: [TindeqSample],
        source: RecordingSource = .dynamometer,
        externalLoadKilograms: Double? = nil,
        outcome: RecordingOutcome? = nil,
        plannedDurationMilliseconds: Int? = nil,
        actualDurationMilliseconds: Int? = nil,
        repetitionNumber: Int? = nil,
        protocolMode: ForceProtocolMode = .hold,
        targetKilograms: Double? = nil,
        targetLowKilograms: Double? = nil,
        targetHighKilograms: Double? = nil,
        cadenceOutSeconds: Double? = nil,
        cadenceReturnSeconds: Double? = nil,
        cadenceMarkers: [CadenceMarker]? = nil,
        setMetrics: ReverseActionMetrics? = nil,
        setupNote: String = "",
        capacityEvidence: Bool? = nil,
        completedRepetitions: Int? = nil,
        completionStatus: String? = nil
    ) {
        self.id = id
        self.accountUserID = accountUserID
        self.recordedAt = recordedAt
        self.durationMilliseconds = durationMilliseconds
        self.peakKilograms = peakKilograms
        self.averageKilograms = averageKilograms
        self.note = note
        self.tag = tag
        self.side = side
        self.groupID = groupID
        self.protocolRunID = protocolRunID
        self.setNumber = setNumber
        self.zone = zone
        self.samples = samples
        self.source = source
        self.externalLoadKilograms = externalLoadKilograms
        self.outcome = outcome
        self.plannedDurationMilliseconds = plannedDurationMilliseconds
        self.actualDurationMilliseconds = actualDurationMilliseconds
        self.repetitionNumber = repetitionNumber
        self.protocolMode = protocolMode
        self.targetKilograms = targetKilograms
        self.targetLowKilograms = targetLowKilograms
        self.targetHighKilograms = targetHighKilograms
        self.cadenceOutSeconds = cadenceOutSeconds
        self.cadenceReturnSeconds = cadenceReturnSeconds
        self.cadenceMarkers = cadenceMarkers
        self.setMetrics = setMetrics
        self.setupNote = setupNote
        self.capacityEvidence = capacityEvidence
        self.completedRepetitions = completedRepetitions
        self.completionStatus = completionStatus
    }
}

public enum TargetPercentageBasis: String, Codable, Sendable {
    case personalRecord = "pr"
    case criticalForce = "cf"
}

public struct TindeqPreset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var holdSeconds: Int
    public var holdSecondsBySet: [Int]?
    public var repetitions: Int
    public var sets: Int
    public var restBetweenRepetitionsSeconds: Int
    public var restBetweenSetsSeconds: Int
    public var targetKilograms: Double?
    public var targetPercentage: Double?
    public var percentageBasis: TargetPercentageBasis
    public var percentageStep: Double
    public var targetFromCurve: Bool
    public var alternateSides: Bool
    public var protocolMode: ForceProtocolMode
    public var cadenceOutSeconds: Double
    public var cadenceReturnSeconds: Double
    public var toleranceMode: String
    public var toleranceValue: Double
    public var prepareSeconds: Int
    public var setupNote: String
    public var capacityEvidence: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        holdSeconds: Int,
        holdSecondsBySet: [Int]? = nil,
        repetitions: Int,
        sets: Int,
        restBetweenRepetitionsSeconds: Int,
        restBetweenSetsSeconds: Int,
        targetKilograms: Double? = nil,
        targetPercentage: Double? = nil,
        percentageBasis: TargetPercentageBasis = .personalRecord,
        percentageStep: Double = 0,
        targetFromCurve: Bool = false,
        alternateSides: Bool = false,
        protocolMode: ForceProtocolMode = .hold,
        cadenceOutSeconds: Double = 3,
        cadenceReturnSeconds: Double = 3,
        toleranceMode: String = "percent",
        toleranceValue: Double = 10,
        prepareSeconds: Int = 5,
        setupNote: String = "",
        capacityEvidence: Bool = false
    ) {
        self.id = id
        self.name = name
        self.holdSeconds = holdSeconds
        self.holdSecondsBySet = holdSecondsBySet
        self.repetitions = repetitions
        self.sets = sets
        self.restBetweenRepetitionsSeconds = restBetweenRepetitionsSeconds
        self.restBetweenSetsSeconds = restBetweenSetsSeconds
        self.targetKilograms = targetKilograms
        self.targetPercentage = targetPercentage
        self.percentageBasis = percentageBasis
        self.percentageStep = percentageStep
        self.targetFromCurve = targetFromCurve
        self.alternateSides = alternateSides
        self.protocolMode = protocolMode
        self.cadenceOutSeconds = cadenceOutSeconds
        self.cadenceReturnSeconds = cadenceReturnSeconds
        self.toleranceMode = toleranceMode
        self.toleranceValue = toleranceValue
        self.prepareSeconds = prepareSeconds
        self.setupNote = setupNote
        self.capacityEvidence = capacityEvidence
    }

    public func holdSeconds(forSet set: Int) -> Int {
        guard let overrides = holdSecondsBySet, set > 0, set <= overrides.count else {
            return max(1, holdSeconds)
        }
        return max(1, overrides[set - 1])
    }
}

// MARK: - Workout and routines

public struct RoutineStep: Codable, Equatable, Sendable, Identifiable {
    /// Local SwiftUI identity only. The shared JSON schema intentionally does
    /// not persist an id for a routine step; older TypeScript rows contain
    /// only `label`, optional `detail`, `s`, optional `reps`, and optional
    /// `restS`.
    public let id: UUID
    public var label: String
    public var detail: String?
    public var seconds: Int
    public var repetitions: Int
    public var restSeconds: Int

    public init(
        id: UUID = UUID(),
        label: String,
        detail: String? = nil,
        seconds: Int,
        repetitions: Int = 1,
        restSeconds: Int = 0
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.seconds = seconds
        self.repetitions = repetitions
        self.restSeconds = restSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case label, detail
        case seconds = "s"
        case repetitions = "reps"
        case restSeconds = "restS"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.label = try container.decode(String.self, forKey: .label)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.seconds = max(1, try container.decode(Int.self, forKey: .seconds))
        self.repetitions = max(1, try container.decodeIfPresent(Int.self, forKey: .repetitions) ?? 1)
        self.restSeconds = max(0, try container.decodeIfPresent(Int.self, forKey: .restSeconds) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(label.prefix(120)), forKey: .label)
        try container.encodeIfPresent(detail.map { String($0.prefix(500)) }, forKey: .detail)
        try container.encode(max(1, seconds), forKey: .seconds)
        if repetitions != 1 {
            try container.encode(max(1, repetitions), forKey: .repetitions)
        }
        if restSeconds > 0 {
            try container.encode(restSeconds, forKey: .restSeconds)
        }
    }
}

public struct RoutinePreset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var steps: [RoutineStep]

    public init(id: UUID = UUID(), name: String, steps: [RoutineStep]) {
        self.id = id
        self.name = name
        self.steps = steps
    }
}

public struct WorkoutAttempt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let durationSeconds: Int
    public let elevationGainMeters: Double
    public let averageHeartRate: Double?
    public let peakHeartRate: Double?
    public let effortScore: Double?
    public let source: String

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        durationSeconds: Int,
        elevationGainMeters: Double = 0,
        averageHeartRate: Double? = nil,
        peakHeartRate: Double? = nil,
        effortScore: Double? = nil,
        source: String = "manual"
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.elevationGainMeters = elevationGainMeters
        self.averageHeartRate = averageHeartRate
        self.peakHeartRate = peakHeartRate
        self.effortScore = effortScore
        self.source = source
    }
}

public struct WorkoutDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let workoutID: UUID
    public let accountUserID: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var attempts: [WorkoutAttempt]
    public var type: String
    public var typeLabel: String
    public var rpe: Double
    public var phase: PhaseID

    public init(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        workoutID: UUID = UUID(),
        accountUserID: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        attempts: [WorkoutAttempt] = [],
        type: String = "board",
        typeLabel: String = "Board Climbing",
        rpe: Double = 7,
        phase: PhaseID
    ) {
        self.id = id
        self.sessionID = sessionID
        self.workoutID = workoutID
        self.accountUserID = accountUserID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attempts = attempts
        self.type = type
        self.typeLabel = typeLabel
        self.rpe = rpe
        self.phase = phase
    }
}

public struct WorkoutListItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID?
    public let startedAt: Date
    public let endedAt: Date
    public let averageHeartRate: Double?
    public let attemptsConfirmed: Int
    public let attemptsDetected: Int
    public let rpeConfirmed: Double?
    public let source: WorkoutSource

    public init(
        id: UUID,
        sessionID: UUID?,
        startedAt: Date,
        endedAt: Date,
        averageHeartRate: Double?,
        attemptsConfirmed: Int,
        attemptsDetected: Int,
        rpeConfirmed: Double?,
        source: WorkoutSource
    ) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.averageHeartRate = averageHeartRate
        self.attemptsConfirmed = attemptsConfirmed
        self.attemptsDetected = attemptsDetected
        self.rpeConfirmed = rpeConfirmed
        self.source = source
    }
}

public struct LiveWorkout: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { workoutID }
    public let workoutID: UUID
    public let runID: UUID
    public let sequence: Int?
    public let event: String
    public let terminal: Bool
    public let status: String
    public let startedAt: Date
    public let heartRate: Double?
    public let attemptCount: Int
    public let activeKilocalories: Double?
    public let elevationGainMeters: Double?
    public let climbing: Bool
    public let climbingSince: Date?
    public let restStartedAt: Date?
    public let restTargetSeconds: Int?
    public let updatedAt: Date

    public init(
        workoutID: UUID,
        runID: UUID,
        sequence: Int?,
        event: String,
        terminal: Bool,
        status: String,
        startedAt: Date,
        heartRate: Double?,
        attemptCount: Int,
        activeKilocalories: Double?,
        elevationGainMeters: Double?,
        climbing: Bool,
        climbingSince: Date?,
        restStartedAt: Date?,
        restTargetSeconds: Int?,
        updatedAt: Date
    ) {
        self.workoutID = workoutID
        self.runID = runID
        self.sequence = sequence
        self.event = event
        self.terminal = terminal
        self.status = status
        self.startedAt = startedAt
        self.heartRate = heartRate
        self.attemptCount = attemptCount
        self.activeKilocalories = activeKilocalories
        self.elevationGainMeters = elevationGainMeters
        self.climbing = climbing
        self.climbingSince = climbingSince
        self.restStartedAt = restStartedAt
        self.restTargetSeconds = restTargetSeconds
        self.updatedAt = updatedAt
    }
}
