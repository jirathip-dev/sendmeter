import Foundation
import SendmeterCore

// MARK: - Shared backend models

private let sessionColumns = "id,date,type,type_label,duration_min,rpe,rpe_confirmed,load,note,phase,group_id,workout_source"
private let recordingColumns = "id,recorded_at,duration_ms,peak_kg,avg_kg,sample_count,note,tag,side,group_id,protocol_run_id,set_no,zone,source,external_load_kg,outcome,planned_duration_ms,actual_duration_ms,rep_no,protocol_mode,target_kg,target_low_kg,target_high_kg,cadence_out_s,cadence_return_s,cadence_markers,set_metrics,setup_note,capacity_evidence,completed_reps,completion_status"
private let presetColumns = "id,name,hold_s,holds_s,reps,sets,rest_reps_s,rest_sets_s,target_kg,target_pct,pct_basis,pct_step,target_curve,alternate_sides,protocol_mode,cadence_out_s,cadence_return_s,tolerance_mode,tolerance_value,prepare_s,setup_note,capacity_evidence"

private struct LiveWorkoutRow: Decodable {
    let workoutID: UUID
    let runID: UUID?
    let userID: UUID?
    let sequence: Int?
    let event: String?
    let terminal: Bool?
    let status: String
    let startedAt: Date
    let heartRate: Double?
    let attemptCount: Int?
    let activeKilocalories: Double?
    let elevationGainMeters: Double?
    let climbing: Bool?
    let climbingSince: Date?
    let restStartedAt: Date?
    let restTargetSeconds: Int?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case status, event, terminal, climbing, sequence
        case workoutID = "workout_id"
        case runID = "run_id"
        case userID = "user_id"
        case startedAt = "started_at"
        case heartRate = "hr"
        case attemptCount = "attempt_count"
        case activeKilocalories = "active_kcal"
        case elevationGainMeters = "elevation_gain_m"
        case climbingSince = "climbing_since"
        case restStartedAt = "rest_started_at"
        case restTargetSeconds = "rest_target_s"
        case updatedAt = "updated_at"
    }

    var model: LiveWorkout {
        LiveWorkout(
            workoutID: workoutID,
            runID: runID ?? workoutID,
            sequence: sequence,
            event: event ?? "telemetry",
            terminal: terminal ?? (status == "ended"),
            status: status,
            startedAt: startedAt,
            heartRate: heartRate,
            attemptCount: attemptCount ?? 0,
            activeKilocalories: activeKilocalories,
            elevationGainMeters: elevationGainMeters,
            climbing: climbing ?? false,
            climbingSince: climbingSince,
            restStartedAt: restStartedAt,
            restTargetSeconds: restTargetSeconds,
            updatedAt: updatedAt,
            userID: userID
        )
    }
}

private struct SessionRow: Decodable {
    let id: UUID
    let date: String
    let type: String
    let typeLabel: String
    let durationMinutes: Int
    let rpe: Double
    let rpeConfirmed: Bool?
    let load: Double
    let note: String?
    let phase: String
    let groupID: UUID?
    let workoutSource: String?

    enum CodingKeys: String, CodingKey {
        case id, date, type, rpe, load, note, phase
        case typeLabel = "type_label"
        case durationMinutes = "duration_min"
        case rpeConfirmed = "rpe_confirmed"
        case groupID = "group_id"
        case workoutSource = "workout_source"
    }

    func model(accountUserID: UUID? = nil, pending: Bool = false) -> Session {
        Session(
            id: id,
            date: date,
            type: type,
            typeLabel: typeLabel,
            durationMinutes: durationMinutes,
            rpe: rpe,
            rpeConfirmed: rpeConfirmed != false,
            load: load,
            note: note ?? "",
            phase: PhaseID(rawValue: phase) ?? .capacity,
            groupID: groupID,
            workoutSource: workoutSource.flatMap(WorkoutSource.init(rawValue:))
                ?? (type == "auto" ? .watch : nil),
            pending: pending,
            accountUserID: accountUserID
        )
    }
}

private struct SessionLoadRow: Decodable {
    let date: String
    let load: Double
}

private struct SessionInsert: Encodable {
    let id: UUID?
    let date: String
    let type: String
    let typeLabel: String
    let durationMinutes: Int
    let rpe: Double
    let rpeConfirmed: Bool?
    let note: String
    let phase: String
    let groupID: UUID?
    let workoutSource: String?

    enum CodingKeys: String, CodingKey {
        case id, date, type, rpe, note, phase
        case typeLabel = "type_label"
        case durationMinutes = "duration_min"
        case rpeConfirmed = "rpe_confirmed"
        case groupID = "group_id"
        case workoutSource = "workout_source"
    }
}

private struct SessionUpdate: Encodable {
    let type: String
    let typeLabel: String
    let durationMinutes: Int
    let rpe: Double
    let rpeConfirmed: Bool
    let note: String

    enum CodingKeys: String, CodingKey {
        case type, rpe, note
        case typeLabel = "type_label"
        case durationMinutes = "duration_min"
        case rpeConfirmed = "rpe_confirmed"
    }
}

private struct SoftDeletePayload: Encodable {
    let deletedAt: Date
    enum CodingKeys: String, CodingKey { case deletedAt = "deleted_at" }
}

private struct RestorePayload: Encodable {
    enum CodingKeys: String, CodingKey { case deletedAt = "deleted_at" }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .deletedAt)
    }
}

private struct SettingsRow: Codable {
    let userID: UUID?
    let currentPhase: String
    let phaseStartDate: String
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case currentPhase = "current_phase"
        case phaseStartDate = "phase_start_date"
        case updatedAt = "updated_at"
    }
}

private struct PhasePeriodRow: Codable {
    let id: UUID
    let phase: String
    let startedOn: String
    let endedOn: String?

    enum CodingKeys: String, CodingKey {
        case id, phase
        case startedOn = "started_on"
        case endedOn = "ended_on"
    }

    var model: PhasePeriod {
        PhasePeriod(
            id: id,
            phase: PhaseID(rawValue: phase) ?? .capacity,
            startedOn: startedOn,
            endedOn: endedOn
        )
    }
}

private struct PhaseCreatePayload: Encodable {
    let phase: String
    let startedOn: String
    enum CodingKeys: String, CodingKey { case phase; case startedOn = "started_on" }
}

private struct PhaseClosePayload: Encodable {
    let endedOn: String
    enum CodingKeys: String, CodingKey { case endedOn = "ended_on" }
}

private struct PhaseReopenPayload: Encodable {
    enum CodingKeys: String, CodingKey { case endedOn = "ended_on" }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .endedOn)
    }
}

private struct PhaseUpdatePayload: Encodable { let phase: String }

private struct HealthMetricRow: Codable {
    let date: String
    let readiness: Int?
    let zone: String?
    let computedAt: Date
    let hrvSDNN: Double?
    let restingHR: Double?
    let sleepHours: Double?
    let sleepDeepHours: Double?
    let sleepREMHours: Double?
    let bodyMassKg: Double?
    let respiratoryRate: Double?

    enum CodingKeys: String, CodingKey {
        case date, readiness, zone
        case computedAt = "computed_at"
        case hrvSDNN = "hrv_sdnn_ms"
        case restingHR = "resting_hr"
        case sleepHours = "sleep_hours"
        case sleepDeepHours = "sleep_deep_hours"
        case sleepREMHours = "sleep_rem_hours"
        case bodyMassKg = "body_mass_kg"
        case respiratoryRate = "resp_rate_bpm"
    }

    var model: HealthMetric {
        HealthMetric(
            date: date,
            readiness: readiness,
            zone: zone,
            computedAt: computedAt,
            hrvSDNNMilliseconds: hrvSDNN,
            restingHeartRate: restingHR,
            sleepHours: sleepHours,
            sleepDeepHours: sleepDeepHours,
            sleepREMHours: sleepREMHours,
            bodyMassKilograms: bodyMassKg,
            respiratoryRate: respiratoryRate
        )
    }
}

private struct HealthMetricUpsert: Encodable {
    let userID: UUID
    let date: String
    let readiness: Int?
    let zone: String?
    // Optional (not just "nullable in the DB") for #661/#109: when a pass
    // keeps an existing score, these three are left OUT of the upsert payload
    // entirely (synthesized `encodeIfPresent` omits nil keys), so Postgres'
    // ON CONFLICT merge only touches the biometric columns and leaves the
    // existing readiness/zone/computed_at untouched.
    let computedAt: Date?
    let hrvSDNN: Double?
    let restingHR: Double?
    let sleepHours: Double?
    let sleepDeepHours: Double?
    let sleepREMHours: Double?
    let bodyMassKg: Double?
    let respiratoryRate: Double?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case date, readiness, zone
        case computedAt = "computed_at"
        case hrvSDNN = "hrv_sdnn_ms"
        case restingHR = "resting_hr"
        case sleepHours = "sleep_hours"
        case sleepDeepHours = "sleep_deep_hours"
        case sleepREMHours = "sleep_rem_hours"
        case bodyMassKg = "body_mass_kg"
        case respiratoryRate = "resp_rate_bpm"
    }
}

private struct CadenceMarkerRow: Codable {
    let milliseconds: Int
    let repetition: Int
    let direction: String

    enum CodingKeys: String, CodingKey {
        case milliseconds = "tMs"
        case repetition = "rep"
        case direction
    }
}

private struct SetMetricsRow: Codable {
    let meanKilograms: Double?
    let coefficientVariationPercent: Double?
    let inTargetPercent: Double?
    let timeUnderTensionMilliseconds: Int
    let driftPercent: Double?
    let cadenceAdherencePercent: Double

    enum CodingKeys: String, CodingKey {
        case meanKilograms = "meanKg"
        case coefficientVariationPercent = "coefficientVariationPct"
        case inTargetPercent = "inTargetPct"
        case timeUnderTensionMilliseconds = "timeUnderTensionMs"
        case driftPercent = "driftPct"
        case cadenceAdherencePercent = "cadenceAdherencePct"
    }
}

private struct RecordingRow: Decodable {
    let id: UUID
    let recordedAt: Date
    let durationMilliseconds: Int
    let peakKilograms: Double?
    let averageKilograms: Double?
    let sampleCount: Int
    let note: String?
    let tag: String?
    let side: String?
    let groupID: UUID?
    let protocolRunID: UUID?
    let setNumber: Int?
    let zone: String?
    let source: String?
    let externalLoadKilograms: Double?
    let outcome: String?
    let plannedDurationMilliseconds: Int?
    let actualDurationMilliseconds: Int?
    let repetitionNumber: Int?
    let protocolMode: String?
    let targetKilograms: Double?
    let targetLowKilograms: Double?
    let targetHighKilograms: Double?
    let cadenceOutSeconds: Double?
    let cadenceReturnSeconds: Double?
    let cadenceMarkers: [CadenceMarkerRow]?
    let setMetrics: SetMetricsRow?
    let setupNote: String?
    let capacityEvidence: Bool?
    let completedRepetitions: Int?
    let completionStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, note, tag, side, zone, source, outcome
        case recordedAt = "recorded_at"
        case durationMilliseconds = "duration_ms"
        case peakKilograms = "peak_kg"
        case averageKilograms = "avg_kg"
        case sampleCount = "sample_count"
        case groupID = "group_id"
        case protocolRunID = "protocol_run_id"
        case setNumber = "set_no"
        case externalLoadKilograms = "external_load_kg"
        case plannedDurationMilliseconds = "planned_duration_ms"
        case actualDurationMilliseconds = "actual_duration_ms"
        case repetitionNumber = "rep_no"
        case protocolMode = "protocol_mode"
        case targetKilograms = "target_kg"
        case targetLowKilograms = "target_low_kg"
        case targetHighKilograms = "target_high_kg"
        case cadenceOutSeconds = "cadence_out_s"
        case cadenceReturnSeconds = "cadence_return_s"
        case cadenceMarkers = "cadence_markers"
        case setMetrics = "set_metrics"
        case setupNote = "setup_note"
        case capacityEvidence = "capacity_evidence"
        case completedRepetitions = "completed_reps"
        case completionStatus = "completion_status"
    }

    var model: TindeqRecording {
        TindeqRecording(
            id: id,
            recordedAt: recordedAt,
            durationMilliseconds: durationMilliseconds,
            peakKilograms: peakKilograms,
            averageKilograms: averageKilograms,
            sampleCount: sampleCount,
            note: note ?? "",
            tag: tag ?? "",
            side: TindeqSide(rawValue: side ?? "") ?? .unspecified,
            groupID: groupID,
            protocolRunID: protocolRunID,
            setNumber: setNumber,
            zone: zone.flatMap(RecordedZone.init(rawValue:)),
            source: RecordingSource(rawValue: source ?? "dynamometer") ?? .dynamometer,
            externalLoadKilograms: externalLoadKilograms,
            outcome: outcome.flatMap(RecordingOutcome.init(rawValue:)),
            plannedDurationMilliseconds: plannedDurationMilliseconds,
            actualDurationMilliseconds: actualDurationMilliseconds,
            repetitionNumber: repetitionNumber,
            protocolMode: ForceProtocolMode(rawValue: protocolMode ?? "hold") ?? .hold,
            targetKilograms: targetKilograms,
            targetLowKilograms: targetLowKilograms,
            targetHighKilograms: targetHighKilograms,
            cadenceOutSeconds: cadenceOutSeconds,
            cadenceReturnSeconds: cadenceReturnSeconds,
            cadenceMarkers: cadenceMarkers?.compactMap {
                guard let direction = CadenceMarker.Direction(rawValue: $0.direction) else { return nil }
                return CadenceMarker(
                    milliseconds: $0.milliseconds,
                    repetition: $0.repetition,
                    direction: direction
                )
            },
            setMetrics: setMetrics.map {
                ReverseActionMetrics(
                    meanKilograms: $0.meanKilograms,
                    coefficientOfVariationPercent: $0.coefficientVariationPercent,
                    inTargetPercent: $0.inTargetPercent,
                    timeUnderTensionMilliseconds: $0.timeUnderTensionMilliseconds,
                    driftPercent: $0.driftPercent,
                    cadenceAdherencePercent: $0.cadenceAdherencePercent
                )
            },
            setupNote: setupNote ?? "",
            capacityEvidence: capacityEvidence,
            completedRepetitions: completedRepetitions,
            completionStatus: completionStatus
        )
    }
}

private struct RecordingSamplesRow: Decodable {
    let samples: [[Double]]
}

private struct RecordingInsert: Encodable {
    let id: UUID
    let recordedAt: Date
    let durationMilliseconds: Int
    let peakKilograms: Double?
    let averageKilograms: Double?
    let sampleCount: Int
    let note: String
    let tag: String
    let side: String
    let groupID: UUID?
    let protocolRunID: UUID?
    let setNumber: Int?
    let zone: String?
    let source: String
    let externalLoadKilograms: Double?
    let outcome: String?
    let plannedDurationMilliseconds: Int?
    let actualDurationMilliseconds: Int?
    let repetitionNumber: Int?
    let protocolMode: String
    let targetKilograms: Double?
    let targetLowKilograms: Double?
    let targetHighKilograms: Double?
    let cadenceOutSeconds: Double?
    let cadenceReturnSeconds: Double?
    let cadenceMarkers: [CadenceMarkerRow]?
    let setMetrics: SetMetricsRow?
    let setupNote: String
    let capacityEvidence: Bool?
    let completedRepetitions: Int?
    let completionStatus: String?
    let samples: [[Double]]

    enum CodingKeys: String, CodingKey {
        case id, note, tag, side, zone, source, outcome, samples
        case recordedAt = "recorded_at"
        case durationMilliseconds = "duration_ms"
        case peakKilograms = "peak_kg"
        case averageKilograms = "avg_kg"
        case sampleCount = "sample_count"
        case groupID = "group_id"
        case protocolRunID = "protocol_run_id"
        case setNumber = "set_no"
        case externalLoadKilograms = "external_load_kg"
        case plannedDurationMilliseconds = "planned_duration_ms"
        case actualDurationMilliseconds = "actual_duration_ms"
        case repetitionNumber = "rep_no"
        case protocolMode = "protocol_mode"
        case targetKilograms = "target_kg"
        case targetLowKilograms = "target_low_kg"
        case targetHighKilograms = "target_high_kg"
        case cadenceOutSeconds = "cadence_out_s"
        case cadenceReturnSeconds = "cadence_return_s"
        case cadenceMarkers = "cadence_markers"
        case setMetrics = "set_metrics"
        case setupNote = "setup_note"
        case capacityEvidence = "capacity_evidence"
        case completedRepetitions = "completed_reps"
        case completionStatus = "completion_status"
    }

    init(_ recording: NewTindeqRecording) {
        id = recording.id
        recordedAt = recording.recordedAt
        durationMilliseconds = recording.durationMilliseconds
        peakKilograms = recording.peakKilograms
        averageKilograms = recording.averageKilograms
        sampleCount = recording.samples.count
        note = recording.note
        tag = recording.tag
        side = recording.side.rawValue
        groupID = recording.groupID
        protocolRunID = recording.protocolRunID
        setNumber = recording.setNumber
        zone = recording.zone?.rawValue
        source = recording.source.rawValue
        externalLoadKilograms = recording.externalLoadKilograms
        outcome = recording.outcome?.rawValue
        plannedDurationMilliseconds = recording.plannedDurationMilliseconds
        actualDurationMilliseconds = recording.actualDurationMilliseconds
        repetitionNumber = recording.repetitionNumber
        protocolMode = recording.protocolMode.rawValue
        targetKilograms = recording.targetKilograms
        targetLowKilograms = recording.targetLowKilograms
        targetHighKilograms = recording.targetHighKilograms
        cadenceOutSeconds = recording.cadenceOutSeconds
        cadenceReturnSeconds = recording.cadenceReturnSeconds
        cadenceMarkers = recording.cadenceMarkers?.map {
            CadenceMarkerRow(
                milliseconds: $0.milliseconds,
                repetition: $0.repetition,
                direction: $0.direction.rawValue
            )
        }
        setMetrics = recording.setMetrics.map {
            SetMetricsRow(
                meanKilograms: $0.meanKilograms,
                coefficientVariationPercent: $0.coefficientOfVariationPercent,
                inTargetPercent: $0.inTargetPercent,
                timeUnderTensionMilliseconds: $0.timeUnderTensionMilliseconds,
                driftPercent: $0.driftPercent,
                cadenceAdherencePercent: $0.cadenceAdherencePercent
            )
        }
        setupNote = recording.setupNote
        capacityEvidence = recording.capacityEvidence
        completedRepetitions = recording.completedRepetitions
        completionStatus = recording.completionStatus
        samples = recording.samples.map { [$0.milliseconds, $0.kilograms] }
    }
}

private struct RecordingMetaUpdate: Encodable {
    let tag: String
    let side: String
    let note: String
}

private struct RecordingGroupUpdate: Encodable {
    let groupID: UUID
    enum CodingKeys: String, CodingKey { case groupID = "group_id" }
}

private struct PresetRow: Codable {
    let id: UUID
    let name: String
    let holdSeconds: Int
    let holdSecondsBySet: [Int]?
    let repetitions: Int
    let sets: Int
    let restBetweenRepetitions: Int
    let restBetweenSets: Int
    let targetKilograms: Double?
    let targetPercentage: Double?
    let percentageBasis: String?
    let percentageStep: Double?
    let targetCurve: Bool?
    let alternateSides: Bool?
    let protocolMode: String?
    let cadenceOutSeconds: Double?
    let cadenceReturnSeconds: Double?
    let toleranceMode: String?
    let toleranceValue: Double?
    let prepareSeconds: Int?
    let setupNote: String?
    let capacityEvidence: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, sets
        case holdSeconds = "hold_s"
        case holdSecondsBySet = "holds_s"
        case repetitions = "reps"
        case restBetweenRepetitions = "rest_reps_s"
        case restBetweenSets = "rest_sets_s"
        case targetKilograms = "target_kg"
        case targetPercentage = "target_pct"
        case percentageBasis = "pct_basis"
        case percentageStep = "pct_step"
        case targetCurve = "target_curve"
        case alternateSides = "alternate_sides"
        case protocolMode = "protocol_mode"
        case cadenceOutSeconds = "cadence_out_s"
        case cadenceReturnSeconds = "cadence_return_s"
        case toleranceMode = "tolerance_mode"
        case toleranceValue = "tolerance_value"
        case prepareSeconds = "prepare_s"
        case setupNote = "setup_note"
        case capacityEvidence = "capacity_evidence"
    }

    var model: TindeqPreset {
        TindeqPreset(
            id: id,
            name: name,
            holdSeconds: max(1, holdSeconds),
            holdSecondsBySet: holdSecondsBySet,
            repetitions: max(1, repetitions),
            sets: max(1, sets),
            restBetweenRepetitionsSeconds: max(0, restBetweenRepetitions),
            restBetweenSetsSeconds: max(0, restBetweenSets),
            targetKilograms: targetKilograms,
            targetPercentage: targetPercentage,
            percentageBasis: TargetPercentageBasis(rawValue: percentageBasis ?? "pr") ?? .personalRecord,
            percentageStep: percentageStep ?? 0,
            targetFromCurve: targetCurve ?? false,
            alternateSides: alternateSides ?? false,
            protocolMode: ForceProtocolMode(rawValue: protocolMode ?? "hold") ?? .hold,
            cadenceOutSeconds: cadenceOutSeconds ?? 3,
            cadenceReturnSeconds: cadenceReturnSeconds ?? 3,
            toleranceMode: toleranceMode ?? "percent",
            toleranceValue: toleranceValue ?? 10,
            prepareSeconds: prepareSeconds ?? 5,
            setupNote: setupNote ?? "",
            capacityEvidence: capacityEvidence ?? false
        )
    }
}

private struct PresetPayload: Encodable {
    let name: String
    let holdSeconds: Int
    let holdSecondsBySet: [Int]?
    let repetitions: Int
    let sets: Int
    let restBetweenRepetitions: Int
    let restBetweenSets: Int
    let targetKilograms: Double?
    let targetPercentage: Double?
    let percentageBasis: String
    let percentageStep: Double
    let targetCurve: Bool
    let alternateSides: Bool
    let protocolMode: String
    let cadenceOutSeconds: Double
    let cadenceReturnSeconds: Double
    let toleranceMode: String
    let toleranceValue: Double
    let prepareSeconds: Int
    let setupNote: String
    let capacityEvidence: Bool

    enum CodingKeys: String, CodingKey {
        case name, sets
        case holdSeconds = "hold_s"
        case holdSecondsBySet = "holds_s"
        case repetitions = "reps"
        case restBetweenRepetitions = "rest_reps_s"
        case restBetweenSets = "rest_sets_s"
        case targetKilograms = "target_kg"
        case targetPercentage = "target_pct"
        case percentageBasis = "pct_basis"
        case percentageStep = "pct_step"
        case targetCurve = "target_curve"
        case alternateSides = "alternate_sides"
        case protocolMode = "protocol_mode"
        case cadenceOutSeconds = "cadence_out_s"
        case cadenceReturnSeconds = "cadence_return_s"
        case toleranceMode = "tolerance_mode"
        case toleranceValue = "tolerance_value"
        case prepareSeconds = "prepare_s"
        case setupNote = "setup_note"
        case capacityEvidence = "capacity_evidence"
    }

    init(_ preset: TindeqPreset) {
        name = String(preset.name.prefix(80))
        holdSeconds = min(1_800, max(1, preset.holdSeconds))
        holdSecondsBySet = preset.holdSecondsBySet?.map { min(1_800, max(1, $0)) }
        repetitions = min(100, max(1, preset.repetitions))
        sets = min(20, max(1, preset.sets))
        restBetweenRepetitions = min(3_600, max(0, preset.restBetweenRepetitionsSeconds))
        restBetweenSets = min(7_200, max(0, preset.restBetweenSetsSeconds))
        targetKilograms = preset.targetKilograms
        targetPercentage = preset.targetPercentage
        percentageBasis = preset.percentageBasis.rawValue
        percentageStep = preset.percentageStep
        targetCurve = preset.targetFromCurve
        alternateSides = preset.alternateSides
        protocolMode = preset.protocolMode.rawValue
        cadenceOutSeconds = max(0.25, preset.cadenceOutSeconds)
        cadenceReturnSeconds = max(0.25, preset.cadenceReturnSeconds)
        toleranceMode = preset.toleranceMode
        toleranceValue = max(0, preset.toleranceValue)
        prepareSeconds = min(60, max(0, preset.prepareSeconds))
        setupNote = String(preset.setupNote.prefix(500))
        capacityEvidence = preset.capacityEvidence
    }
}

private struct RoutineRow: Codable {
    let id: UUID
    let name: String
    let steps: [RoutineStep]
    var model: RoutinePreset { RoutinePreset(id: id, name: name, steps: steps) }
}

private struct RoutinePayload: Encodable {
    let name: String
    let steps: [RoutineStep]
}

private struct WorkoutListRow: Decodable {
    let id: UUID
    let sessionID: UUID?
    let startedAt: Date
    let endedAt: Date
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let activeKilocalories: Double?
    let elevationGainMeters: Double?
    let attemptsConfirmed: Int
    let attemptsDetected: Int
    let rpeConfirmed: Double?
    let rpePredicted: Double?
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, source
        case sessionID = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case averageHeartRate = "avg_hr"
        case maxHeartRate = "max_hr"
        case activeKilocalories = "active_kcal"
        case elevationGainMeters = "elevation_gain_m"
        case attemptsConfirmed = "attempts_confirmed"
        case attemptsDetected = "attempts_detected"
        case rpeConfirmed = "rpe_confirmed"
        case rpePredicted = "rpe_predicted"
    }

    var model: WorkoutListItem {
        WorkoutListItem(
            id: id,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            activeKilocalories: activeKilocalories,
            elevationGainMeters: elevationGainMeters,
            attemptsConfirmed: attemptsConfirmed,
            attemptsDetected: attemptsDetected,
            rpeConfirmed: rpeConfirmed,
            rpePredicted: rpePredicted,
            source: WorkoutSource(rawValue: source) ?? .watch
        )
    }
}

/// A `climb_attempts` row for one workout, fetched for the detail charts
/// (#645): the attempt windows shaded over the HR trace and the effort bars
/// below need the same x-domain contribution as the trace itself.
private struct WorkoutAttemptRow: Decodable {
    let startedAt: Date
    let durationS: Double
    let elevationGainM: Double
    let avgHr: Double?
    let peakHr: Double?
    let effortScore: Double?
    let source: String

    enum CodingKeys: String, CodingKey {
        case source
        case startedAt = "started_at"
        case durationS = "duration_s"
        case elevationGainM = "elevation_gain_m"
        case avgHr = "avg_hr"
        case peakHr = "peak_hr"
        case effortScore = "effort_score"
    }

    var model: WorkoutAttempt {
        WorkoutAttempt(
            startedAt: startedAt,
            durationSeconds: Int(durationS.rounded()),
            elevationGainMeters: elevationGainM,
            averageHeartRate: avgHr,
            peakHeartRate: peakHr,
            effortScore: effortScore,
            source: source
        )
    }
}

/// The lazy raw-trace fetch's row: `climb_workouts.raw` only (#645).
private struct WorkoutRawRow: Decodable {
    let raw: [[Double?]]?
}

private struct PhoneWorkoutAttemptRPC: Encodable {
    let startedAt: Date
    let durationSeconds: Int
    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case durationSeconds = "duration_s"
    }
}

private struct PhoneWorkoutRPC: Encodable {
    let sessionID: UUID
    let workoutID: UUID
    let date: String
    let type: String
    let typeLabel: String
    let durationMinutes: Int
    let rpe: Double
    let note: String
    let phase: String
    let startedAt: Date
    let endedAt: Date
    let attempts: [PhoneWorkoutAttemptRPC]

    enum CodingKeys: String, CodingKey {
        case sessionID = "p_session_id"
        case workoutID = "p_workout_id"
        case date = "p_date"
        case type = "p_type"
        case typeLabel = "p_type_label"
        case durationMinutes = "p_duration_min"
        case rpe = "p_rpe"
        case note = "p_note"
        case phase = "p_phase"
        case startedAt = "p_started_at"
        case endedAt = "p_ended_at"
        case attempts = "p_attempts"
    }
}

private struct LinkRecordingsRPC: Encodable {
    let sessionID: UUID
    let recordingIDs: [UUID]
    enum CodingKeys: String, CodingKey {
        case sessionID = "p_session_id"
        case recordingIDs = "p_recording_ids"
    }
}

private struct RenameTagRPC: Encodable {
    let oldName: String
    let newName: String
    enum CodingKeys: String, CodingKey {
        case oldName = "old_name"
        case newName = "new_name"
    }
}

private struct TagMetadataRow: Decodable {
    let name: String
    let hidden: Bool
}

private struct TagHiddenUpsert: Encodable {
    let name: String
    let hidden: Bool
}

/// What `link_tindeq_recordings_to_session` returns: the group id it stamped
/// on the session + recordings, and the recomputed duration (nil for a
/// non-tindeq session or a group without live recordings). #630's create-
/// session flow reads both back so the optimistic local state matches the
/// transaction's outcome instead of guessing (the old `session.id` stamp was
/// wrong whenever the RPC minted a fresh group id).
public struct LinkRecordingsResult: Decodable, Sendable {
    public let groupID: UUID
    public let durationMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case durationMinutes = "duration_min"
    }
}

private struct EmptyRPC: Encodable {}

// MARK: - Repository

public final class SendmeterRepository: @unchecked Sendable {
    public let transport: PostgRESTClient

    public init(transport: PostgRESTClient = PostgRESTClient()) {
        self.transport = transport
    }

    // MARK: Sessions

    public func fetchSessions(accountUserID: UUID? = nil) async throws -> [Session] {
        let rows: [SessionRow] = try await transport.request(
            path: "rest/v1/sessions",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: sessionColumns),
                URLQueryItem(name: "deleted_at", value: "is.null"),
                URLQueryItem(name: "order", value: "date.desc,created_at.desc")
            ]
        )
        return rows.map { $0.model(accountUserID: accountUserID) }
    }

    /// Session loads for the readiness recompute's ACWR (#661 F2). The
    /// recompute must read the ACWR from the server, never the in-memory
    /// `sessions` (which can be empty on a cold launch, fabricating a score up
    /// to 20 points high). Same shape/soft-delete exclusion as the shipped
    /// plugin's `computeAcwr`. Filtered to the EWMA lookback window.
    public func fetchSessionLoads() async throws -> [SessionLoad] {
        let cutoff = LocalDateSupport.daysAgo(90)
        let rows: [SessionLoadRow] = try await transport.request(
            path: "rest/v1/sessions",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "date,load"),
                URLQueryItem(name: "date", value: "gte.\(cutoff)"),
                URLQueryItem(name: "deleted_at", value: "is.null"),
                URLQueryItem(name: "order", value: "date.desc,created_at.desc")
            ]
        )
        return rows.map { SessionLoad(date: $0.date, load: $0.load) }
    }

    /// Today's `health_metrics` row, if any. The #109 write policy needs the
    /// existing row's readiness + date to decide whether an automatic sync may
    /// overwrite today's score; the #661 keep-last-reading rule needs its
    /// readiness when a fresh compute yields nil.
    public func fetchTodayHealthMetric() async throws -> HealthMetric? {
        let today = LocalDateSupport.string(from: Date())
        let rows: [HealthMetricRow] = try await transport.request(
            path: "rest/v1/health_metrics",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "date,readiness,zone,computed_at,hrv_sdnn_ms,resting_hr,sleep_hours,sleep_deep_hours,sleep_rem_hours,body_mass_kg,resp_rate_bpm"),
                URLQueryItem(name: "date", value: "eq.\(today)")
            ]
        )
        return rows.first.map(\.model)
    }

    public func fetchDeletedSessions(accountUserID: UUID? = nil) async throws -> [Session] {
        let rows: [SessionRow] = try await transport.request(
            path: "rest/v1/sessions",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: sessionColumns),
                URLQueryItem(name: "deleted_at", value: "not.is.null"),
                URLQueryItem(name: "order", value: "deleted_at.desc")
            ]
        )
        return rows.map { $0.model(accountUserID: accountUserID) }
    }

    public func fetchSession(id: UUID, accountUserID: UUID? = nil) async throws -> Session? {
        let rows: [SessionRow] = try await transport.request(
            path: "rest/v1/sessions",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: sessionColumns),
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        return rows.first?.model(accountUserID: accountUserID)
    }

    public func insertSession(
        _ draft: SessionDraft,
        id: UUID? = nil,
        rpeConfirmed: Bool? = nil,
        groupID: UUID? = nil,
        workoutSource: WorkoutSource? = nil
    ) async throws -> Session {
        let payload = SessionInsert(
            id: id,
            date: draft.date,
            type: draft.type,
            typeLabel: draft.typeLabel,
            durationMinutes: min(600, max(1, draft.durationMinutes)),
            rpe: min(10, max(1, draft.rpe)),
            rpeConfirmed: rpeConfirmed,
            note: String(draft.note.prefix(2_000)),
            phase: draft.phase.rawValue,
            groupID: groupID,
            workoutSource: workoutSource?.rawValue
        )
        let body = try await transport.encode(payload)
        do {
            let result: OneOrMany<SessionRow> = try await transport.request(
                path: "rest/v1/sessions",
                method: .post,
                queryItems: [URLQueryItem(name: "select", value: sessionColumns)],
                body: body,
                prefer: "return=representation"
            )
            guard let row = result.first else { throw URLError(.cannotParseResponse) }
            return row.model()
        } catch let error as PostgRESTError where error.code == "23505" || error.statusCode == 409 {
            if let id, let existing = try await fetchSession(id: id) { return existing }
            throw error
        }
    }

    public func updateSession(_ session: Session) async throws -> Session {
        let payload = SessionUpdate(
            type: session.type,
            typeLabel: session.typeLabel,
            durationMinutes: min(600, max(1, session.durationMinutes)),
            rpe: min(10, max(1, session.rpe)),
            rpeConfirmed: true,
            note: String(session.note.prefix(2_000))
        )
        let body = try await transport.encode(payload)
        let result: OneOrMany<SessionRow> = try await transport.request(
            path: "rest/v1/sessions",
            method: .patch,
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(session.id.uuidString.lowercased())"),
                URLQueryItem(name: "select", value: sessionColumns)
            ],
            body: body,
            prefer: "return=representation"
        )
        guard let row = result.first else { throw URLError(.cannotParseResponse) }
        return row.model()
    }

    public func softDeleteSession(id: UUID, at date: Date = Date()) async throws {
        try await patchVoid(
            table: "sessions",
            id: id,
            payload: SoftDeletePayload(deletedAt: date)
        )
    }

    public func restoreSession(id: UUID) async throws {
        try await patchVoid(table: "sessions", id: id, payload: RestorePayload())
    }

    public func purgeSession(id: UUID) async throws {
        try await transport.requestVoid(
            path: "rest/v1/sessions",
            method: .delete,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")]
        )
    }

    // MARK: Settings and phases

    public func fetchSettings(userID: UUID, today: String) async throws -> UserSettings {
        let rows: [SettingsRow] = try await transport.request(
            path: "rest/v1/user_settings",
            method: .get,
            queryItems: [URLQueryItem(name: "select", value: "user_id,current_phase,phase_start_date,updated_at")]
        )
        if let row = rows.first {
            return UserSettings(
                currentPhase: PhaseID(rawValue: row.currentPhase) ?? .capacity,
                phaseStartDate: row.phaseStartDate
            )
        }
        let settings = UserSettings(currentPhase: .capacity, phaseStartDate: today)
        try await updateSettings(settings, userID: userID)
        return settings
    }

    public func updateSettings(_ settings: UserSettings, userID: UUID) async throws {
        let row = SettingsRow(
            userID: userID,
            currentPhase: settings.currentPhase.rawValue,
            phaseStartDate: settings.phaseStartDate,
            updatedAt: Date()
        )
        let body = try await transport.encode(row)
        try await transport.requestVoid(
            path: "rest/v1/user_settings",
            method: .post,
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id")],
            body: body,
            prefer: "resolution=merge-duplicates,return=minimal"
        )
    }

    public func fetchPhasePeriods() async throws -> [PhasePeriod] {
        let rows: [PhasePeriodRow] = try await transport.request(
            path: "rest/v1/phase_periods",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "id,phase,started_on,ended_on"),
                URLQueryItem(name: "order", value: "started_on.desc,created_at.desc")
            ]
        )
        return rows.map(\.model)
    }

    public func switchPhase(
        to newPhase: PhaseID,
        currentPeriods: [PhasePeriod],
        today: String,
        userID: UUID
    ) async throws -> (periods: [PhasePeriod], settings: UserSettings) {
        let plan = PhaseTransitionPlanner.plan(
            periods: currentPeriods,
            newPhase: newPhase,
            today: today
        )
        for mutation in plan.mutations {
            switch mutation {
            case let .create(phase, startedOn):
                let body = try await transport.encode(
                    PhaseCreatePayload(phase: phase.rawValue, startedOn: startedOn)
                )
                try await transport.requestVoid(
                    path: "rest/v1/phase_periods",
                    method: .post,
                    body: body,
                    prefer: "return=minimal"
                )
            case let .delete(periodID):
                try await transport.requestVoid(
                    path: "rest/v1/phase_periods",
                    method: .delete,
                    queryItems: [URLQueryItem(name: "id", value: "eq.\(periodID.uuidString.lowercased())")]
                )
            case let .updatePhase(periodID, phase):
                try await patchVoid(
                    table: "phase_periods",
                    id: periodID,
                    payload: PhaseUpdatePayload(phase: phase.rawValue)
                )
            case let .close(periodID, endedOn):
                try await patchVoid(
                    table: "phase_periods",
                    id: periodID,
                    payload: PhaseClosePayload(endedOn: endedOn)
                )
            case let .reopen(periodID):
                try await patchVoid(
                    table: "phase_periods",
                    id: periodID,
                    payload: PhaseReopenPayload()
                )
            case let .updateSettings(phase, startedOn):
                try await updateSettings(
                    UserSettings(currentPhase: phase, phaseStartDate: startedOn),
                    userID: userID
                )
            }
        }
        let periods = try await fetchPhasePeriods()
        let open = periods.first(where: { $0.endedOn == nil })
        let settings = UserSettings(
            currentPhase: open?.phase ?? newPhase,
            phaseStartDate: open?.startedOn ?? today
        )
        return (periods, settings)
    }

    // MARK: Health

    public func fetchHealthMetrics(limit: Int = 60) async throws -> [HealthMetric] {
        let rows: [HealthMetricRow] = try await transport.request(
            path: "rest/v1/health_metrics",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "date,readiness,zone,computed_at,hrv_sdnn_ms,resting_hr,sleep_hours,sleep_deep_hours,sleep_rem_hours,body_mass_kg,resp_rate_bpm"),
                URLQueryItem(name: "order", value: "date.desc"),
                URLQueryItem(name: "limit", value: String(max(1, limit)))
            ]
        )
        return rows.map(\.model)
    }

    public func upsertHealthMetric(_ metric: HealthMetric, userID: UUID) async throws {
        let payload = HealthMetricUpsert(
            userID: userID,
            date: metric.date,
            readiness: metric.readiness,
            zone: metric.zone,
            computedAt: metric.computedAt,
            hrvSDNN: metric.hrvSDNNMilliseconds,
            restingHR: metric.restingHeartRate,
            sleepHours: metric.sleepHours,
            sleepDeepHours: metric.sleepDeepHours,
            sleepREMHours: metric.sleepREMHours,
            bodyMassKg: metric.bodyMassKilograms,
            respiratoryRate: metric.respiratoryRate
        )
        let body = try await transport.encode(payload)
        try await transport.requestVoid(
            path: "rest/v1/health_metrics",
            method: .post,
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id,date")],
            body: body,
            prefer: "resolution=merge-duplicates,return=minimal"
        )
    }

    // MARK: Recordings

    public func fetchRecordings() async throws -> [TindeqRecording] {
        let rows: [RecordingRow] = try await transport.request(
            path: "rest/v1/tindeq_recordings",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: recordingColumns),
                URLQueryItem(name: "deleted_at", value: "is.null"),
                URLQueryItem(name: "order", value: "recorded_at.desc")
            ]
        )
        return rows.map(\.model)
    }

    public func fetchDeletedRecordings() async throws -> [TindeqRecording] {
        let rows: [RecordingRow] = try await transport.request(
            path: "rest/v1/tindeq_recordings",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: recordingColumns),
                URLQueryItem(name: "deleted_at", value: "not.is.null"),
                URLQueryItem(name: "order", value: "deleted_at.desc")
            ]
        )
        return rows.map(\.model)
    }

    public func fetchRecording(id: UUID) async throws -> TindeqRecording? {
        let rows: [RecordingRow] = try await transport.request(
            path: "rest/v1/tindeq_recordings",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: recordingColumns),
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        return rows.first?.model
    }

    public func fetchRecordingSamples(id: UUID) async throws -> [TindeqSample] {
        let rows: [RecordingSamplesRow] = try await transport.request(
            path: "rest/v1/tindeq_recordings",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "samples"),
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        return rows.first?.samples.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return TindeqSample(milliseconds: pair[0], kilograms: pair[1])
        } ?? []
    }

    public func insertRecording(_ recording: NewTindeqRecording) async throws -> TindeqRecording {
        let body = try await transport.encode(RecordingInsert(recording))
        do {
            let result: OneOrMany<RecordingRow> = try await transport.request(
                path: "rest/v1/tindeq_recordings",
                method: .post,
                queryItems: [URLQueryItem(name: "select", value: recordingColumns)],
                body: body,
                prefer: "return=representation"
            )
            guard let row = result.first else { throw URLError(.cannotParseResponse) }
            return row.model
        } catch let error as PostgRESTError where error.code == "23505" || error.statusCode == 409 {
            if let existing = try await fetchRecording(id: recording.id) { return existing }
            throw error
        }
    }

    public func updateRecordingMeta(
        id: UUID,
        tag: String,
        side: TindeqSide,
        note: String
    ) async throws -> TindeqRecording {
        let body = try await transport.encode(
            RecordingMetaUpdate(
                tag: String(tag.prefix(120)),
                side: side.rawValue,
                note: String(note.prefix(2_000))
            )
        )
        let result: OneOrMany<RecordingRow> = try await transport.request(
            path: "rest/v1/tindeq_recordings",
            method: .patch,
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "select", value: recordingColumns)
            ],
            body: body,
            prefer: "return=representation"
        )
        guard let row = result.first else { throw URLError(.cannotParseResponse) }
        return row.model
    }

    public func updateRecordingGroup(id: UUID, groupID: UUID) async throws {
        try await patchVoid(
            table: "tindeq_recordings",
            id: id,
            payload: RecordingGroupUpdate(groupID: groupID)
        )
    }

    public func softDeleteRecording(id: UUID, at date: Date = Date()) async throws {
        try await patchVoid(
            table: "tindeq_recordings",
            id: id,
            payload: SoftDeletePayload(deletedAt: date)
        )
    }

    public func restoreRecording(id: UUID) async throws {
        try await patchVoid(table: "tindeq_recordings", id: id, payload: RestorePayload())
    }

    public func purgeRecording(id: UUID) async throws {
        try await transport.requestVoid(
            path: "rest/v1/tindeq_recordings",
            method: .delete,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")]
        )
    }

    /// #490: atomically mint the session's group id (if it has none), stamp
    /// it onto the recordings, and (for tindeq sessions) recompute the
    /// session's duration from the recordings' actual span — one DB
    /// transaction, so a failure leaves nothing changed. Nil when handed an
    /// empty id list (nothing to do); otherwise returns the RPC's stamped
    /// group id + recomputed duration.
    public func linkRecordingsToSession(
        sessionID: UUID,
        recordingIDs: [UUID]
    ) async throws -> LinkRecordingsResult? {
        guard !recordingIDs.isEmpty else { return nil }
        let body = try await transport.encode(
            LinkRecordingsRPC(sessionID: sessionID, recordingIDs: recordingIDs)
        )
        let result: OneOrMany<LinkRecordingsResult> = try await transport.request(
            path: "rest/v1/rpc/link_tindeq_recordings_to_session",
            method: .post,
            body: body
        )
        return result.first
    }

    // MARK: Tag registry (SL-92, #631)

    /// Every registry row for the signed-in user. A tag has a row here only
    /// once it's hidden (or carries a curve — native computes curves
    /// on-device and doesn't persist them) — visible tags are derived from
    /// distinct recording tags (`TagCatalog.entries`).
    public func fetchTagMetadata() async throws -> [TagMetadata] {
        let rows: [TagMetadataRow] = try await transport.request(
            path: "rest/v1/tindeq_tags",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "name,hidden"),
                URLQueryItem(name: "order", value: "name.asc")
            ]
        )
        return rows.map { TagMetadata(name: $0.name, hidden: $0.hidden) }
    }

    /// Hide/unhide a tag. Upserts the registry row (user_id defaults to
    /// auth.uid() via RLS); the recordings are never touched.
    public func setTagHidden(name: String, hidden: Bool) async throws {
        let body = try await transport.encode(TagHiddenUpsert(name: name, hidden: hidden))
        try await transport.requestVoid(
            path: "rest/v1/tindeq_tags",
            method: .post,
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id,name")],
            body: body,
            prefer: "resolution=merge-duplicates,return=minimal"
        )
    }

    /// Rename a tag EVERYWHERE — the DB function repoints every recording
    /// carrying `oldName` to `newName` and clears the stale registry row,
    /// atomically, scoped to the caller by `security invoker` RLS. If
    /// `newName` already exists the two tags merge.
    public func renameTag(oldName: String, newName: String) async throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw PostgRESTError(
                code: nil,
                message: "Tag name can't be empty",
                details: nil,
                hint: nil,
                statusCode: 422
            )
        }
        let body = try await transport.encode(RenameTagRPC(oldName: oldName, newName: name))
        try await transport.requestVoid(
            path: "rest/v1/rpc/rename_tindeq_tag",
            method: .post,
            body: body
        )
    }

    // MARK: Presets

    public func fetchPresets() async throws -> [TindeqPreset] {
        let rows: [PresetRow] = try await transport.request(
            path: "rest/v1/tindeq_presets",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: presetColumns),
                URLQueryItem(name: "order", value: "created_at.desc")
            ]
        )
        return rows.map(\.model)
    }

    public func insertPreset(_ preset: TindeqPreset) async throws -> TindeqPreset {
        let body = try await transport.encode(PresetPayload(preset))
        let result: OneOrMany<PresetRow> = try await transport.request(
            path: "rest/v1/tindeq_presets",
            method: .post,
            queryItems: [URLQueryItem(name: "select", value: presetColumns)],
            body: body,
            prefer: "return=representation"
        )
        guard let row = result.first else { throw URLError(.cannotParseResponse) }
        return row.model
    }

    public func updatePreset(_ preset: TindeqPreset) async throws -> TindeqPreset {
        let body = try await transport.encode(PresetPayload(preset))
        let result: OneOrMany<PresetRow> = try await transport.request(
            path: "rest/v1/tindeq_presets",
            method: .patch,
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(preset.id.uuidString.lowercased())"),
                URLQueryItem(name: "select", value: presetColumns)
            ],
            body: body,
            prefer: "return=representation"
        )
        guard let row = result.first else { throw URLError(.cannotParseResponse) }
        return row.model
    }

    public func deletePreset(id: UUID) async throws {
        try await transport.requestVoid(
            path: "rest/v1/tindeq_presets",
            method: .delete,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")]
        )
    }

    // MARK: Routines and workouts

    public func fetchRoutinePresets() async throws -> [RoutinePreset] {
        let rows: [RoutineRow] = try await transport.request(
            path: "rest/v1/routine_presets",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "id,name,steps"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ]
        )
        return rows.map(\.model)
    }

    public func insertRoutine(_ routine: RoutinePreset) async throws -> RoutinePreset {
        let body = try await transport.encode(
            RoutinePayload(name: String(routine.name.prefix(80)), steps: routine.steps)
        )
        let result: OneOrMany<RoutineRow> = try await transport.request(
            path: "rest/v1/routine_presets",
            method: .post,
            queryItems: [URLQueryItem(name: "select", value: "id,name,steps")],
            body: body,
            prefer: "return=representation"
        )
        guard let row = result.first else { throw URLError(.cannotParseResponse) }
        return row.model
    }

    public func updateRoutine(_ routine: RoutinePreset) async throws -> RoutinePreset {
        let body = try await transport.encode(
            RoutinePayload(name: String(routine.name.prefix(80)), steps: routine.steps)
        )
        let result: OneOrMany<RoutineRow> = try await transport.request(
            path: "rest/v1/routine_presets",
            method: .patch,
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(routine.id.uuidString.lowercased())"),
                URLQueryItem(name: "select", value: "id,name,steps")
            ],
            body: body,
            prefer: "return=representation"
        )
        guard let row = result.first else { throw URLError(.cannotParseResponse) }
        return row.model
    }

    public func deleteRoutine(id: UUID) async throws {
        try await transport.requestVoid(
            path: "rest/v1/routine_presets",
            method: .delete,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")]
        )
    }

    public func fetchWorkouts(limit: Int = 30) async throws -> [WorkoutListItem] {
        let rows: [WorkoutListRow] = try await transport.request(
            path: "rest/v1/climb_workouts",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "id,session_id,started_at,ended_at,avg_hr,max_hr,active_kcal,elevation_gain_m,attempts_confirmed,attempts_detected,rpe_confirmed,rpe_predicted,source"),
                URLQueryItem(name: "order", value: "started_at.desc"),
                URLQueryItem(name: "limit", value: String(max(1, limit)))
            ]
        )
        return rows.map(\.model)
    }

    /// The workout's `climb_attempts` (web's embedded `climb_attempts`
    /// sub-query of `fetchWorkoutById`): the attempt windows the HR chart
    /// shades and the effort bars plot on the same x-domain. A workout with
    /// no attempts yields `[]` — the charts then show the trace alone.
    public func fetchWorkoutAttempts(id: UUID) async throws -> [WorkoutAttempt] {
        let rows: [WorkoutAttemptRow] = try await transport.request(
            path: "rest/v1/climb_attempts",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "started_at,duration_s,elevation_gain_m,avg_hr,peak_hr,effort_score,source"),
                URLQueryItem(name: "workout_id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "order", value: "started_at.asc")
            ]
        )
        return rows.map(\.model)
    }

    /// The workout's HR trace (web `fetchWorkoutRaw`): `climb_workouts.raw`
    /// is `[[t_s, alt_m, motion_rms, hr], ...]`, shaped into `{t, hr}` samples
    /// by `WorkoutRawTrace.hrSeries`. Nil when the workout kept no trace
    /// (older builds, phone workouts) — the HR chart just doesn't render.
    /// `fetchWorkouts` deliberately never selects `raw`, so expanding a row
    /// costs one lazy single-row fetch, mirroring `fetchRecordingSamples`.
    public func fetchWorkoutRaw(id: UUID) async throws -> [WorkoutHrSample]? {
        let rows: [WorkoutRawRow] = try await transport.request(
            path: "rest/v1/climb_workouts",
            method: .get,
            queryItems: [
                URLQueryItem(name: "select", value: "raw"),
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        guard let row = rows.first, let raw = row.raw, !raw.isEmpty else { return nil }
        return WorkoutRawTrace.hrSeries(raw)
    }

    /// The current `live_workouts` row (one per user). The realtime channel
    /// delivers rows as the watch upserts them; this is the authoritative
    /// initial fetch / foreground reconciliation, fed into the same mirror
    /// cursor as `server-fallback` (#626).
    public func fetchLiveWorkout() async throws -> LiveWorkout? {
        let rows: [LiveWorkoutRow] = try await transport.request(
            path: "rest/v1/live_workouts",
            method: .get,
            queryItems: [
                URLQueryItem(
                    name: "select",
                    value: "workout_id,run_id,user_id,sequence,event,terminal,status,started_at,hr,attempt_count,active_kcal,elevation_gain_m,climbing,climbing_since,rest_started_at,rest_target_s,updated_at"
                ),
                URLQueryItem(name: "order", value: "updated_at.desc"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        return rows.first?.model
    }

    public func insertPhoneWorkout(_ draft: WorkoutDraft, timeZone: TimeZone = .current) async throws -> Session {
        guard let endedAt = draft.endedAt else { throw URLError(.badServerResponse) }
        let durationMinutes = max(1, min(600, Int(ceil(endedAt.timeIntervalSince(draft.startedAt) / 60))))
        let count = draft.attempts.count
        let payload = PhoneWorkoutRPC(
            sessionID: draft.sessionID,
            workoutID: draft.workoutID,
            date: LocalDateSupport.string(from: endedAt, timeZone: timeZone),
            type: draft.type,
            typeLabel: draft.typeLabel,
            durationMinutes: durationMinutes,
            rpe: min(10, max(1, draft.rpe)),
            note: "\(count) boulder\(count == 1 ? "" : "s")",
            phase: draft.phase.rawValue,
            startedAt: draft.startedAt,
            endedAt: endedAt,
            attempts: draft.attempts.map {
                PhoneWorkoutAttemptRPC(
                    startedAt: $0.startedAt,
                    durationSeconds: max(1, $0.durationSeconds)
                )
            }
        )
        let body = try await transport.encode(payload)
        let result: OneOrMany<SessionRow> = try await transport.request(
            path: "rest/v1/rpc/create_phone_workout",
            method: .post,
            body: body
        )
        guard let row = result.first else { throw URLError(.cannotParseResponse) }
        return row.model(accountUserID: draft.accountUserID)
    }

    // MARK: Account

    public func deleteAccount() async throws {
        let body = try await transport.encode(EmptyRPC())
        try await transport.requestVoid(
            path: "rest/v1/rpc/delete_account",
            method: .post,
            body: body
        )
    }

    // MARK: Helpers

    private func patchVoid<Payload: Encodable>(
        table: String,
        id: UUID,
        payload: Payload
    ) async throws {
        let body = try await transport.encode(payload)
        try await transport.requestVoid(
            path: "rest/v1/\(table)",
            method: .patch,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")],
            body: body,
            prefer: "return=minimal"
        )
    }
}
