import Foundation

/// A watch-safe representation of a `tindeq_presets` row. The custom decoder
/// deliberately supplies the web app's compatibility defaults so presets
/// written before movement protocols were introduced remain usable.
public struct WatchForceProtocol: Sendable, Codable, Equatable, Identifiable {
    public enum Mode: String, Sendable, Codable, Equatable {
        case hold
        case reverseAction = "reverse_action"
    }

    public enum PercentBasis: String, Sendable, Codable, Equatable {
        case pr
        case cf
    }

    public enum ToleranceMode: String, Sendable, Codable, Equatable {
        case percent
        case kg
    }

    public enum Labels {
        public static let resistedMovement = "Resisted movement"
        public static let movement = "MOVEMENT"
        public static let concentric = "Concentric"
        public static let eccentric = "Eccentric"
    }

    public struct TimelineSegment: Sendable, Equatable, Identifiable {
        public enum Phase: String, Sendable, Equatable {
            case prepare
            case hold
            case concentric
            case eccentric
            case rest
            case setRest
        }

        public enum Direction: String, Sendable, Equatable {
            case concentric
            case eccentric
        }

        public let id: Int
        public let phase: Phase
        public let direction: Direction?
        public let rep: Int
        public let set: Int
        public let startS: Double
        public let durationS: Double

        public init(
            id: Int,
            phase: Phase,
            direction: Direction? = nil,
            rep: Int,
            set: Int,
            startS: Double,
            durationS: Double
        ) {
            self.id = id
            self.phase = phase
            self.direction = direction
            self.rep = rep
            self.set = set
            self.startS = startS
            self.durationS = durationS
        }
    }

    public struct RunSnapshot: Sendable, Equatable {
        public let elapsedS: Double
        public let remainingS: Double
        public let progress: Double
        public let segment: TimelineSegment?
        public let segmentRemainingS: Double
        public let isComplete: Bool

        public init(
            elapsedS: Double,
            remainingS: Double,
            progress: Double,
            segment: TimelineSegment?,
            segmentRemainingS: Double,
            isComplete: Bool
        ) {
            self.elapsedS = elapsedS
            self.remainingS = remainingS
            self.progress = progress
            self.segment = segment
            self.segmentRemainingS = segmentRemainingS
            self.isComplete = isComplete
        }
    }

    public let id: String
    public let name: String
    public let holdS: Double
    public let holdsS: [Double]?
    public let reps: Int
    public let sets: Int
    public let restRepsS: Double
    public let restSetsS: Double
    public let targetKg: Double?
    public let targetPct: Double?
    public let percentBasis: PercentBasis
    public let percentStep: Double
    public let targetCurve: Bool
    public let alternateSides: Bool
    public let mode: Mode
    public let cadenceOutS: Double
    public let cadenceReturnS: Double
    public let toleranceMode: ToleranceMode
    public let toleranceValue: Double
    public let prepareS: Double
    public let setupNote: String
    public let capacityEvidence: Bool

    public init(
        id: String,
        name: String,
        holdS: Double,
        holdsS: [Double]? = nil,
        reps: Int,
        sets: Int,
        restRepsS: Double,
        restSetsS: Double,
        targetKg: Double? = nil,
        targetPct: Double? = nil,
        percentBasis: PercentBasis = .pr,
        percentStep: Double = 0,
        targetCurve: Bool = false,
        alternateSides: Bool = false,
        mode: Mode = .hold,
        cadenceOutS: Double = 3,
        cadenceReturnS: Double = 3,
        toleranceMode: ToleranceMode = .percent,
        toleranceValue: Double = 10,
        prepareS: Double = 5,
        setupNote: String = "",
        capacityEvidence: Bool = false
    ) {
        self.id = id
        self.name = name
        self.holdS = holdS
        self.holdsS = holdsS
        self.reps = reps
        self.sets = sets
        self.restRepsS = restRepsS
        self.restSetsS = restSetsS
        self.targetKg = targetKg
        self.targetPct = targetPct
        self.percentBasis = percentBasis
        self.percentStep = percentStep
        self.targetCurve = targetCurve
        self.alternateSides = alternateSides
        self.mode = mode
        self.cadenceOutS = cadenceOutS
        self.cadenceReturnS = cadenceReturnS
        self.toleranceMode = toleranceMode
        self.toleranceValue = toleranceValue
        self.prepareS = prepareS
        self.setupNote = setupNote
        self.capacityEvidence = capacityEvidence
    }

    public static let movementStarter = WatchForceProtocol(
        id: "suggested:movement-starter",
        name: "Movement Starter",
        holdS: 40,
        reps: 10,
        sets: 3,
        restRepsS: 0,
        restSetsS: 60,
        mode: .reverseAction,
        cadenceOutS: 3,
        cadenceReturnS: 1,
        prepareS: 5,
        setupNote: Labels.resistedMovement
    )

    public var summary: String {
        let repLabel = reps == 1 ? "rep" : "reps"
        let setLabel = sets == 1 ? "set" : "sets"
        let repsAndSets = "\(reps) \(repLabel) × \(sets) \(setLabel)"
        let rest = sets > 1 ? " · \(formatSeconds(restSetsS)) rest" : ""
        switch mode {
        case .reverseAction:
            return "\(formatSeconds(cadenceOutS)) concentric · \(formatSeconds(cadenceReturnS)) eccentric · \(repsAndSets)\(rest)"
        case .hold:
            return "\(formatSeconds(holdS)) hold · \(repsAndSets)\(rest)"
        }
    }

    /// Exact wall-clock duration, including the preparation countdown.
    public var durationS: Double {
        timeline.last.map { $0.startS + $0.durationS } ?? 0
    }

    /// Pure expansion used by countdown UIs. Movement sets are continuous and
    /// alternate concentric/eccentric directions; static protocols retain the
    /// traditional hold/rest shape.
    public var timeline: [TimelineSegment] {
        var result: [TimelineSegment] = []
        var elapsed = 0.0

        func append(
            _ phase: TimelineSegment.Phase,
            direction: TimelineSegment.Direction? = nil,
            rep: Int,
            set: Int,
            duration: Double
        ) {
            guard duration > 0 else { return }
            result.append(TimelineSegment(
                id: result.count,
                phase: phase,
                direction: direction,
                rep: rep,
                set: set,
                startS: elapsed,
                durationS: duration
            ))
            elapsed += duration
        }

        append(.prepare, rep: 1, set: 1, duration: prepareS)

        guard sets > 0, reps > 0 else { return result }
        for set in 1...sets {
            for rep in 1...reps {
                switch mode {
                case .reverseAction:
                    append(.concentric, direction: .concentric, rep: rep, set: set, duration: cadenceOutS)
                    append(.eccentric, direction: .eccentric, rep: rep, set: set, duration: cadenceReturnS)
                case .hold:
                    append(.hold, rep: rep, set: set, duration: holdDuration(forSet: set))
                    if rep < reps {
                        append(.rest, rep: rep, set: set, duration: restRepsS)
                    }
                }
            }
            if set < sets {
                append(.setRest, rep: reps, set: set, duration: restSetsS)
            }
        }

        return result
    }

    /// Wall-clock-derived run state. This stays correct after a delayed timer
    /// tick or foreground resume; the UI never increments a counter and drifts.
    public func snapshot(at elapsedS: Double) -> RunSnapshot {
        let boundedElapsed = min(max(0, elapsedS), durationS)
        let active = timeline.first {
            boundedElapsed >= $0.startS && boundedElapsed < $0.startS + $0.durationS
        }
        let finished = durationS == 0 || boundedElapsed >= durationS
        return RunSnapshot(
            elapsedS: boundedElapsed,
            remainingS: max(0, durationS - boundedElapsed),
            progress: durationS > 0 ? boundedElapsed / durationS : 1,
            segment: active,
            segmentRemainingS: active.map { max(0, $0.startS + $0.durationS - boundedElapsed) } ?? 0,
            isComplete: finished
        )
    }

    /// All segment boundaries crossed since the previous wall-clock sample.
    /// A runner can process this ordered list exactly once even when a timer
    /// callback is late and spans more than one short cadence phase.
    public func crossedSegments(from previousElapsedS: Double, to elapsedS: Double) -> [TimelineSegment] {
        let lower = max(0, previousElapsedS)
        let upper = min(max(lower, elapsedS), durationS)
        return timeline.filter { segment in
            segment.startS > lower && segment.startS <= upper
        }
    }

    private func holdDuration(forSet set: Int) -> Double {
        guard let holdsS, holdsS.count >= sets else { return holdS }
        return holdsS[set - 1]
    }

    private func formatSeconds(_ seconds: Double) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))s"
        }
        return "\(seconds)s"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case holdS = "hold_s"
        case holdsS = "holds_s"
        case reps
        case sets
        case restRepsS = "rest_reps_s"
        case restSetsS = "rest_sets_s"
        case targetKg = "target_kg"
        case targetPct = "target_pct"
        case percentBasis = "pct_basis"
        case percentStep = "pct_step"
        case targetCurve = "target_curve"
        case alternateSides = "alternate_sides"
        case mode = "protocol_mode"
        case cadenceOutS = "cadence_out_s"
        case cadenceReturnS = "cadence_return_s"
        case toleranceMode = "tolerance_mode"
        case toleranceValue = "tolerance_value"
        case prepareS = "prepare_s"
        case setupNote = "setup_note"
        case capacityEvidence = "capacity_evidence"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        holdS = try values.decode(Double.self, forKey: .holdS)
        holdsS = try values.decodeIfPresent([Double].self, forKey: .holdsS)
        reps = try values.decode(Int.self, forKey: .reps)
        sets = try values.decode(Int.self, forKey: .sets)
        restRepsS = try values.decode(Double.self, forKey: .restRepsS)
        restSetsS = try values.decode(Double.self, forKey: .restSetsS)
        targetKg = try values.decodeIfPresent(Double.self, forKey: .targetKg)
        targetPct = try values.decodeIfPresent(Double.self, forKey: .targetPct)

        let basis = try values.decodeIfPresent(String.self, forKey: .percentBasis)
        percentBasis = basis == PercentBasis.cf.rawValue ? .cf : .pr
        percentStep = try values.decodeIfPresent(Double.self, forKey: .percentStep) ?? 0
        targetCurve = try values.decodeIfPresent(Bool.self, forKey: .targetCurve) ?? false
        alternateSides = try values.decodeIfPresent(Bool.self, forKey: .alternateSides) ?? false

        let decodedMode = try values.decodeIfPresent(String.self, forKey: .mode)
        mode = decodedMode == Mode.reverseAction.rawValue ? .reverseAction : .hold
        cadenceOutS = try values.decodeIfPresent(Double.self, forKey: .cadenceOutS) ?? 3
        cadenceReturnS = try values.decodeIfPresent(Double.self, forKey: .cadenceReturnS) ?? 3
        let decodedTolerance = try values.decodeIfPresent(String.self, forKey: .toleranceMode)
        toleranceMode = decodedTolerance == ToleranceMode.kg.rawValue ? .kg : .percent
        toleranceValue = try values.decodeIfPresent(Double.self, forKey: .toleranceValue) ?? 10
        prepareS = try values.decodeIfPresent(Double.self, forKey: .prepareS) ?? 5
        setupNote = try values.decodeIfPresent(String.self, forKey: .setupNote) ?? ""
        capacityEvidence = try values.decodeIfPresent(Bool.self, forKey: .capacityEvidence) ?? false
    }
}
