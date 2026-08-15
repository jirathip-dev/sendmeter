import Foundation

/// Pure content model + countdown mapping for the guided protocol's
/// lock-screen Live Activity (#628). The ActivityKit activity lives in the
/// app target; this model is the single source of truth BOTH the app (which
/// starts the activity) and any future widget extension (which renders it)
/// would compile against — the web duplicates the model across its widget and
/// plugin copies with a KEEP-IN-SYNC comment (`ActivityModels.swift`); the
/// native rewrite avoids the duplication by sharing one Core package.
///
/// The lock screen renders its countdown natively from timestamps
/// (`Text(timerInterval:)`), so the app only speaks on state transitions —
/// never on a tick — exactly like the web's `src/lib/liveActivity.ts`
/// contract. The segment wire shape (p/s/rep/set/startS/durS) mirrors the
/// web's `ActivitySegment` so the two implementations stay comparable.
public struct GuidedActivitySegment: Codable, Equatable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case prepare
        case work
        case `switch`
        case rest
        case setRest
        case complete

        public var label: String {
            switch self {
            case .prepare: return "Prepare"
            case .work: return "Hold"
            case .switch: return "Switch side"
            case .rest: return "Rest"
            case .setRest: return "Set rest"
            case .complete: return "Complete"
            }
        }
    }

    public let phase: Phase
    public let side: TindeqSide
    public let rep: Int
    public let set: Int
    public let startS: Double
    public let durS: Double

    public var id: Int { Int(startS * 1_000) }

    public init(phase: Phase, side: TindeqSide, rep: Int, set: Int, startS: Double, durS: Double) {
        self.phase = phase
        self.side = side
        self.rep = rep
        self.set = set
        self.startS = startS
        self.durS = durS
    }

    private enum CodingKeys: String, CodingKey {
        case phase = "p"
        case side = "s"
        case rep
        case set
        case startS
        case durS
    }
}

public struct GuidedProtocolActivityContent: Codable, Equatable, Sendable {
    public let title: String
    public let targetKilograms: Double?
    public let startEpochMs: Double
    public let segments: [GuidedActivitySegment]

    public init(
        title: String,
        targetKilograms: Double?,
        startEpochMs: Double,
        segments: [GuidedActivitySegment]
    ) {
        self.title = title
        self.targetKilograms = targetKilograms
        self.startEpochMs = startEpochMs
        self.segments = segments
    }

    /// Where the protocol is `elapsedSeconds` after Start — the web's
    /// `timelineAt` contract (`src/lib/protocol.ts`). Nil = done.
    public func currentSegment(elapsedSeconds: Double) -> GuidedActivitySegment? {
        for segment in segments where elapsedSeconds < segment.startS + segment.durS {
            return segment
        }
        return nil
    }

    /// Seconds left in the current segment; nil when past the schedule.
    public func remainingSeconds(elapsedSeconds: Double) -> Double? {
        guard let segment = currentSegment(elapsedSeconds: elapsedSeconds) else { return nil }
        return max(0, segment.startS + segment.durS - max(elapsedSeconds, segment.startS))
    }

    /// 0...1 progress through the current segment.
    public func progress(elapsedSeconds: Double) -> Double? {
        guard let segment = currentSegment(elapsedSeconds: elapsedSeconds) else { return nil }
        guard segment.durS > 0 else { return 1 }
        return min(1, max(0, (elapsedSeconds - segment.startS) / segment.durS))
    }

    /// Total prescribed duration, including trailing zero-length stages.
    public var totalSeconds: Double {
        segments.map { $0.startS + $0.durS }.max() ?? 0
    }

    /// Everything the lock screen needs, as plain Codable data at one instant
    /// — the ActivityKit `ContentState` is a thin, un-testable conversion of
    /// this (dates from the epoch millis). Timers render natively from the
    /// segment window, so this is only computed on state transitions.
    public struct Snapshot: Codable, Equatable, Sendable {
        public let title: String
        public let phaseLabel: String
        public let detailLabel: String
        public let segmentStartEpochMs: Double
        public let segmentEndEpochMs: Double
        public let progress: Double
        public let peakKilograms: Double?
        public let targetKilograms: Double?

        public init(
            title: String,
            phaseLabel: String,
            detailLabel: String,
            segmentStartEpochMs: Double,
            segmentEndEpochMs: Double,
            progress: Double,
            peakKilograms: Double?,
            targetKilograms: Double?
        ) {
            self.title = title
            self.phaseLabel = phaseLabel
            self.detailLabel = detailLabel
            self.segmentStartEpochMs = segmentStartEpochMs
            self.segmentEndEpochMs = segmentEndEpochMs
            self.progress = progress
            self.peakKilograms = peakKilograms
            self.targetKilograms = targetKilograms
        }
    }

    public func snapshot(atEpochMs: Double, peakKilograms: Double? = nil) -> Snapshot? {
        let elapsedSeconds = max(0, (atEpochMs - startEpochMs) / 1_000)
        guard let segment = currentSegment(elapsedSeconds: elapsedSeconds) else { return nil }
        var detail = "Set \(segment.set) · Rep \(segment.rep)"
        if segment.side != .unspecified {
            detail += " · \(segment.side.label)"
        }
        let startMs = startEpochMs + segment.startS * 1_000
        let endMs = startEpochMs + (segment.startS + segment.durS) * 1_000
        return Snapshot(
            title: title,
            phaseLabel: segment.phase.label,
            detailLabel: detail,
            segmentStartEpochMs: startMs,
            segmentEndEpochMs: endMs,
            progress: progress(elapsedSeconds: elapsedSeconds) ?? 0,
            peakKilograms: peakKilograms,
            targetKilograms: targetKilograms
        )
    }

    /// Build the activity's schedule from the native protocol run: the stages
    /// are already the flat, timed, side-carrying timeline the fullscreen
    /// walks (same source as `save-per-hold`), so the lock screen and the
    /// in-app countdown can never disagree about what segment is current.
    public static func from(
        run: ForceProtocolRun,
        preset: TindeqPreset,
        targetPlan: ForceTargetPlan,
        fallbackSide: TindeqSide,
        start: Date = Date()
    ) -> GuidedProtocolActivityContent {
        var segments: [GuidedActivitySegment] = []
        var elapsed = 0.0
        for stage in run.stages where stage.durationSeconds > 0 {
            let phase: GuidedActivitySegment.Phase
            switch stage.kind {
            case .prepare: phase = .prepare
            case .work: phase = .work
            case .switchSide: phase = .switch
            case .restBetweenRepetitions: phase = .rest
            case .restBetweenSets: phase = .setRest
            case .complete: continue
            }
            let side = stage.side == .unspecified ? fallbackSide : stage.side
            segments.append(
                GuidedActivitySegment(
                    phase: phase,
                    side: side,
                    rep: stage.repetitionNumber,
                    set: stage.setNumber,
                    startS: elapsed,
                    durS: stage.durationSeconds
                )
            )
            elapsed += stage.durationSeconds
        }
        let target = targetPlan.band(forSet: 1, side: fallbackSide)?.kilograms
        return GuidedProtocolActivityContent(
            title: preset.name,
            targetKilograms: target,
            startEpochMs: start.timeIntervalSince1970 * 1_000,
            segments: segments
        )
    }
}
