import Foundation

// MARK: - Training block guidance (#545)

/// The conservative, user-curated guidance state for the current training
/// block. Sendmeter never switches a block on its own — every state is a
/// recommendation the person chooses to act on.
public enum BlockGuidanceState: String, Equatable, Sendable {
    case continueCurrent
    case reviewDuration
    case considerNext
    case considerRecovery
}

/// How far the current block has progressed versus the phase's typical week
/// range.
public enum BlockDurationSignal: String, Equatable, Sendable {
    case within
    case nearing
    case beyond
}

/// How the measured ACWR sits against the phase's target band, with a margin
/// so a single borderline day is not treated as materially off target.
public enum BlockLoadSignal: String, Equatable, Sendable {
    case onTarget
    case above
    case below
    case noData
}

/// The recent readiness trend feeding the guidance decision.
public enum BlockReadinessSignal: String, Equatable, Sendable {
    case stable
    case low
    case falling
    case noData
}

public struct BlockGuidanceSignals: Equatable, Sendable {
    public let duration: BlockDurationSignal
    public let load: BlockLoadSignal
    public let readiness: BlockReadinessSignal

    public init(
        duration: BlockDurationSignal,
        load: BlockLoadSignal,
        readiness: BlockReadinessSignal
    ) {
        self.duration = duration
        self.load = load
        self.readiness = readiness
    }
}

public struct BlockGuidance: Equatable, Sendable {
    public let state: BlockGuidanceState
    public let signals: BlockGuidanceSignals
    public let nextPhase: PhaseID?

    public init(
        state: BlockGuidanceState,
        signals: BlockGuidanceSignals,
        nextPhase: PhaseID?
    ) {
        self.state = state
        self.signals = signals
        self.nextPhase = nextPhase
    }
}

public enum TrainingBlockGuidance: Sendable {
    /// How far outside the target band an ACWR must sit before it counts as
    /// "materially above/below" rather than on target.
    public static let acwrMaterialMargin = 0.05
    /// A readiness score below this is treated as low regardless of trend.
    public static let readinessLowThreshold = 40
    /// The most-recent score must trail the prior few days' mean by at least
    /// this much to count as a falling trend, so one noisy day is ignored.
    public static let readinessFallingMargin = 5.0

    public static func blockGuidance(
        phase: PhaseDefinition,
        age: BlockAge?,
        acwr: Double?,
        readinessHistory: [HealthMetric],
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> BlockGuidance {
        let duration = durationSignal(age: age, phase: phase)
        let load = loadSignal(acwr: acwr, phase: phase)
        let readiness = readinessSignal(
            from: readinessHistory,
            referenceDate: referenceDate,
            timeZone: timeZone
        )
        let nextPhase = phase.id.nextLogical

        let state: BlockGuidanceState
        if duration == .within {
            // A block that is still comfortably inside its typical window is
            // never switched on a single readiness/ACWR datapoint.
            state = .continueCurrent
        } else if readiness == .low || readiness == .falling {
            state = .considerRecovery
        } else if duration == .beyond && load == .onTarget && readiness == .stable && nextPhase != nil {
            state = .considerNext
        } else {
            state = .reviewDuration
        }

        return BlockGuidance(
            state: state,
            signals: BlockGuidanceSignals(duration: duration, load: load, readiness: readiness),
            nextPhase: nextPhase
        )
    }

    static func durationSignal(age: BlockAge?, phase: PhaseDefinition) -> BlockDurationSignal {
        guard let age else { return .within }
        if age.week < phase.typicalWeeksLow { return .within }
        if age.week > phase.typicalWeeksHigh { return .beyond }
        return .nearing
    }

    static func loadSignal(acwr: Double?, phase: PhaseDefinition) -> BlockLoadSignal {
        guard let acwr else { return .noData }
        if acwr < phase.acwrLow - acwrMaterialMargin { return .below }
        if acwr > phase.acwrHigh + acwrMaterialMargin { return .above }
        return .onTarget
    }

    static func readinessSignal(
        from history: [HealthMetric],
        referenceDate: Date,
        timeZone: TimeZone
    ) -> BlockReadinessSignal {
        let windowStart = LocalDateSupport.daysAgo(13, from: referenceDate, timeZone: timeZone)
        let scored = history
            .filter { $0.date >= windowStart }
            .sorted { $0.date < $1.date }
            .compactMap { $0.readiness }
        guard let last = scored.last else { return .noData }
        if last < readinessLowThreshold { return .low }
        let prior = scored.dropLast().suffix(3)
        guard prior.count >= 2 else { return .stable }
        let priorMean = Double(prior.reduce(0, +)) / Double(prior.count)
        if Double(last) < priorMean - readinessFallingMargin { return .falling }
        return .stable
    }
}
