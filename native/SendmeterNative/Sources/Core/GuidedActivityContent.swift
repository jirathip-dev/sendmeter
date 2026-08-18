import Foundation

/// Pure content model + countdown mapping for the guided protocol's
/// lock-screen Live Activity (#628). The ActivityKit activity lives in the
/// app target; this model is the single source of truth the app (which starts
/// the activity) compiles against — the widget extension renders only the
/// wire `ContentState`, never this model. The web duplicates the model across
/// its widget and plugin copies with a KEEP-IN-SYNC comment
/// (`ActivityModels.swift`); the native app compiles this model ONCE from
/// Core and the widget renders only the pushed wire state, so no duplicated
/// model exists to drift.
///
/// The lock screen renders its countdown natively from timestamps
/// (`Text(timerInterval:)`), so the app only speaks on state transitions —
/// never on a tick — exactly like the web's `src/lib/liveActivity.ts`
/// contract. The segment wire shape (p/s/rep/set/startS/durS) mirrors the
/// web's `ActivitySegment` so the two implementations stay comparable.
///
/// A snapshot can be produced two ways:
///   * `from(run:…)` builds a fixed wall-clock schedule (the web's
///     `timelineAt` contract), used to size/preview a run up front.
///   * a `RunAnchor` mirrors the run's LIVE state machine
///     (`currentStage` + `stageStartedAt`), so out-of-band advances (Skip
///     Stage, #674 review F3) and the terminal complete stage (#674 F5) are
///     reflected immediately instead of falling back to wall clock.
public struct GuidedActivitySegment: Codable, Equatable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case prepare
        case work
        case `switch`
        case rest
        case setRest
        case complete

        /// Map the run's stage kind to the wire phase token. `.complete` is
        /// produced here too (the anchor path needs it for the terminal
        /// DONE state); the fixed-schedule `from(run:)` skips it because the
        /// complete stage is zero-length.
        public static func from(stageKind: ForceProtocolStageKind) -> Phase {
            switch stageKind {
            case .prepare: return .prepare
            case .work: return .work
            case .switchSide: return .switch
            case .restBetweenRepetitions: return .rest
            case .restBetweenSets: return .setRest
            case .complete: return .complete
            }
        }

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
        /// Stable machine token of the current segment phase — "prepare" |
        /// "work" | "switch" | "rest" | "setRest" | "complete". The widget's
        /// color mapping keys off this (#674); the human label lives in
        /// `phaseLabel`.
        public let phaseToken: String
        public let phaseLabel: String
        public let detailLabel: String
        public let segmentStartEpochMs: Double
        public let segmentEndEpochMs: Double
        public let peakKilograms: Double?
        public let targetKilograms: Double?

        public init(
            title: String,
            phaseToken: String,
            phaseLabel: String,
            detailLabel: String,
            segmentStartEpochMs: Double,
            segmentEndEpochMs: Double,
            peakKilograms: Double?,
            targetKilograms: Double?
        ) {
            self.title = title
            self.phaseToken = phaseToken
            self.phaseLabel = phaseLabel
            self.detailLabel = detailLabel
            self.segmentStartEpochMs = segmentStartEpochMs
            self.segmentEndEpochMs = segmentEndEpochMs
            self.peakKilograms = peakKilograms
            self.targetKilograms = targetKilograms
        }
    }

    public func snapshot(atEpochMs: Double, peakKilograms: Double? = nil) -> Snapshot? {
        let elapsedSeconds = max(0, (atEpochMs - startEpochMs) / 1_000)
        guard let segment = currentSegment(elapsedSeconds: elapsedSeconds) else { return nil }
        return snapshot(
            segment: segment,
            segmentStartEpochMs: startEpochMs + segment.startS * 1_000,
            peakKilograms: peakKilograms
        )
    }

    /// A point-in-time snapshot of the run's LIVE state machine — the current
    /// stage plus how much of it is left, anchored at one instant. The app
    /// builds this from `ForceProtocolRun.currentStage` + `stageStartedAt`
    /// whenever it pushes a lock-screen update, so out-of-band advances (Skip
    /// Stage) and the terminal complete stage stay in sync with what the
    /// fullscreen shows (#674 review F3/F5).
    public struct RunAnchor: Sendable {
        public let stage: ForceProtocolStage
        public let remainingSeconds: Double
        public let anchoredAtEpochMs: Double

        public init(stage: ForceProtocolStage, remainingSeconds: Double, anchoredAtEpochMs: Double) {
            self.stage = stage
            self.remainingSeconds = remainingSeconds
            self.anchoredAtEpochMs = anchoredAtEpochMs
        }

        /// Capture the anchor from a run at an instant.
        public init(run: ForceProtocolRun, at date: Date = Date()) {
            self.init(
                stage: run.currentStage,
                remainingSeconds: run.remainingSeconds(at: date),
                anchoredAtEpochMs: date.timeIntervalSince1970 * 1_000
            )
        }
    }

    /// Everything the lock screen needs from a run ANCHOR — the live
    /// `currentStage` + `stageStartedAt` state machine instead of the fixed
    /// wall-clock schedule. This is the snapshot the app pushes on every
    /// state transition (stage change / Skip Stage / hold-end peak / run
    /// complete), so the card can never disagree with the in-app countdown
    /// (#674 review F3) and the terminal complete stage is reachable (#674
    /// F5). The countdown window starts NOW and runs for the current stage's
    /// full remaining duration; when the stage is the zero-length complete
    /// stage the window is empty and `remainingSeconds == 0`.
    public func snapshot(runAnchor: RunAnchor, peakKilograms: Double? = nil) -> Snapshot {
        let stage = runAnchor.stage
        let nowEpochMs = runAnchor.anchoredAtEpochMs
        let remaining = max(0, runAnchor.remainingSeconds)
        let endEpochMs = nowEpochMs + remaining * 1_000
        var detail = "Set \(stage.setNumber) · Rep \(stage.repetitionNumber)"
        if stage.side != .unspecified {
            detail += " · \(stage.side.label)"
        }
        let phase = GuidedActivitySegment.Phase.from(stageKind: stage.kind)
        return Snapshot(
            title: title,
            phaseToken: phase.rawValue,
            phaseLabel: phase.label,
            detailLabel: detail,
            segmentStartEpochMs: nowEpochMs,
            segmentEndEpochMs: endEpochMs,
            peakKilograms: peakKilograms,
            targetKilograms: targetKilograms
        )
    }

    private func snapshot(segment: GuidedActivitySegment, segmentStartEpochMs: Double, peakKilograms: Double?) -> Snapshot {
        var detail = "Set \(segment.set) · Rep \(segment.rep)"
        if segment.side != .unspecified {
            detail += " · \(segment.side.label)"
        }
        let endEpochMs = segmentStartEpochMs + segment.durS * 1_000
        return Snapshot(
            title: title,
            phaseToken: segment.phase.rawValue,
            phaseLabel: segment.phase.label,
            detailLabel: detail,
            segmentStartEpochMs: segmentStartEpochMs,
            segmentEndEpochMs: endEpochMs,
            peakKilograms: peakKilograms,
            targetKilograms: targetKilograms
        )
    }

    /// Build the activity's schedule from the native protocol run: the stages
    /// are already the flat, timed, side-carrying timeline the fullscreen
    /// walks (same source as `save-per-hold`). The schedule is a faithful
    /// PREVIEW of the run, but the pushed snapshots must come from the live
    /// anchor instead — a Skip Stage or a disconnect re-advances `run` and
    /// wall clock can no longer describe the current segment (#674 review
    /// F3).
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
