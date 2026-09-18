import Foundation

/// The presentation state for the native guided Force fullscreen.
///
/// The view owns no protocol vocabulary of its own: these labels and phase
/// boundaries are derived from the same `ForceProtocolRun` stage that drives
/// persistence.  Keeping this Foundation-only makes the small-phone layout,
/// reverse-action direction boundary, and accessibility copy testable without
/// a simulator.
public enum GuidedForcePhase: String, Equatable, Sendable {
    case prepare
    case hold
    case reverseOut
    case reverseReturn
    case switchSide
    case rest
    case setRest
    case complete
    case paused
}

public enum GuidedForceAccent: String, Equatable, Sendable {
    case primary
    case optimal
    case caution
    case alert
    case execution
}

public struct GuidedForceStagePresentation: Equatable, Sendable {
    public let phase: GuidedForcePhase
    public let label: String
    public let detail: String
    public let accent: GuidedForceAccent
    public let symbol: String
    public let progress: Double

    public init(
        phase: GuidedForcePhase,
        label: String,
        detail: String,
        accent: GuidedForceAccent,
        symbol: String,
        progress: Double
    ) {
        self.phase = phase
        self.label = label
        self.detail = detail
        self.accent = accent
        self.symbol = symbol
        self.progress = progress
    }
}

/// Sizes for the element that must remain usable on the smallest phone: the
/// live trace. The view may scroll when Dynamic Type makes its intrinsic
/// content taller than the viewport, but it never shrinks the trace below its
/// floor. #899: the STOP/FINISH action circle is gone, so no bottom action
/// block reserves space in the fit estimate.
public struct GuidedForceLayout: Equatable, Sendable {
    public let chartMinimumHeight: Double
    public let sectionGap: Double
    public let horizontalPadding: Double
    public let essentialContentHeight: Double
    public let viewportHeight: Double

    public init(
        chartMinimumHeight: Double,
        sectionGap: Double,
        horizontalPadding: Double,
        essentialContentHeight: Double = 0,
        viewportHeight: Double = 0
    ) {
        self.chartMinimumHeight = chartMinimumHeight
        self.sectionGap = sectionGap
        self.horizontalPadding = horizontalPadding
        self.essentialContentHeight = essentialContentHeight
        self.viewportHeight = viewportHeight
    }

    public var essentialContentFits: Bool {
        essentialContentHeight <= viewportHeight
    }

    /// A bounded chart height for the fitting layout. Compact or large-type
    /// layouts deliberately use the floor and let the surrounding scroll view
    /// carry the overflow; roomy layouts give the trace the remaining block.
    public var flexibleChartHeight: Double {
        guard essentialContentFits else { return chartMinimumHeight }
        return chartMinimumHeight + max(0, viewportHeight - essentialContentHeight)
    }

    /// Resolves a compact layout from the actual available viewport. `textScale`
    /// is supplied by the SwiftUI caller so accessibility sizes reserve more
    /// room without making the chart unusably small.
    public static func resolve(
        width: Double,
        height: Double,
        textScale: Double = 1
    ) -> GuidedForceLayout {
        let safeWidth = max(240, width)
        let safeHeight = max(320, height)
        let safeTextScale = min(1.8, max(1, textScale))
        let padding = safeWidth < 360 ? 12 : 16
        let sectionGap = safeHeight < 520 ? 8.0 : 12.0
        let bannerHeight = safeTextScale > 1.25
            ? 176.0
            : (safeHeight < 520 ? 132.0 : 160.0)
        let chartFloor = max(
            96,
            min(156, safeHeight * (safeTextScale > 1.25 ? 0.15 : 0.18))
        )
        // #899: no bottom action circle anymore — the estimate covers the
        // top bar, protocol identity header, phase banner, status row,
        // target coach, live chart, and the pause/skip controls row. Keeping
        // the estimate honest matters: a falsely-fitting layout would clip
        // the controls instead of scrolling.
        let essentialHeight = 52.0
            + 46.0
            + bannerHeight
            + 44.0
            + 84.0
            + chartFloor
            + 52.0
            + (sectionGap * 6)
            + 24.0
        return GuidedForceLayout(
            chartMinimumHeight: chartFloor,
            sectionGap: sectionGap,
            horizontalPadding: Double(padding),
            essentialContentHeight: essentialHeight,
            viewportHeight: safeHeight
        )
    }
}

/// Synchronous ownership gate for the app-target guided runner.
///
/// The fullscreen is allowed to disappear while the runner continues, so
/// terminal actions and stage advances can race on the main actor around an
/// async durable save. Keeping this decision pure makes the important rule
/// testable without importing SwiftUI or the App target: once terminal state
/// is claimed, no new stage advance may begin or commit.
public struct GuidedForceSessionPolicy: Equatable, Sendable {
    public private(set) var isTerminal = false
    public private(set) var isAdvancing = false
    public private(set) var isPausing = false

    public init() {}

    @discardableResult
    public mutating func claimTerminal() -> Bool {
        guard !isTerminal else { return false }
        isTerminal = true
        return true
    }

    @discardableResult
    public mutating func claimAdvance() -> Bool {
        guard !isTerminal, !isAdvancing, !isPausing else { return false }
        isAdvancing = true
        return true
    }

    @discardableResult
    public mutating func claimPause() -> Bool {
        guard !isTerminal, !isAdvancing, !isPausing else { return false }
        isPausing = true
        return true
    }

    public mutating func finishAdvance() {
        isAdvancing = false
    }

    public mutating func finishPause() {
        isPausing = false
    }

    public var canTick: Bool { !isTerminal && !isPausing }
    public var canStartStage: Bool { !isTerminal && !isAdvancing && !isPausing }
    public var canCommitAdvance: Bool { !isTerminal && isAdvancing && !isPausing }
    public var canPause: Bool { !isTerminal && !isAdvancing && !isPausing }
    public var canResume: Bool { canPause }

    public static func recordingIsPartial(for intent: GuidedForceAdvanceIntent) -> Bool {
        intent == .skip
    }
}

/// Single-flight waiter for a terminal guided-run settlement. The caller must
/// make the synchronous terminal claim before calling `start`: that keeps the
/// ticker and Live Activity from producing another event while the first
/// caller's durable preserve and gauge-session end are suspended.
@MainActor
public final class GuidedForceTerminalSettlement {
    private var task: Task<Void, Never>?

    public init() {}

    public var isClaimed: Bool { task != nil }

    /// Start the durable terminal operation once, or return the existing task
    /// so Stop, End, disconnect teardown, and auth teardown all await exactly
    /// the same settlement.
    @discardableResult
    public func start(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        if let task { return task }
        let task = Task { @MainActor in
            await operation()
        }
        self.task = task
        return task
    }

    public func wait() async {
        await task?.value
    }
}

public enum GuidedForceAdvanceIntent: Equatable, Sendable {
    case scheduled
    case skip
}

public enum GuidedForceAuthTransitionStep: Equatable, Sendable {
    case teardownGuidedProtocol
    case drainQueue
    case revokeAuth
}

/// The native App target owns the guided runner, while auth/account reset is
/// coordinated there as well. Keeping this order as a pure policy makes the
/// pre-revocation seam explicit and testable: an old-account pull must be
/// salvaged before the account scope is invalidated.
public enum GuidedForceAuthTransitionPolicy {
    public static func steps(hasActiveProtocol: Bool) -> [GuidedForceAuthTransitionStep] {
        hasActiveProtocol
            ? [.teardownGuidedProtocol, .drainQueue, .revokeAuth]
            : [.drainQueue, .revokeAuth]
    }

    /// Password recovery may hand the app a replacement account (or no
    /// session while the recovery URL is being resolved). Preserve an old
    /// account's active pull before that scope is replaced. A recovery event
    /// for the same account is only a mode change and must keep the run alive.
    public static func passwordRecoveryNeedsTeardown(
        currentUserID: UUID?,
        nextUserID: UUID?
    ) -> Bool {
        guard currentUserID != nil else { return false }
        return currentUserID != nextUserID
    }

    /// An async old-owner cleanup may finish after a new guided session has
    /// been installed. Only the owner that is still current may clear the
    /// presentation and its auth callback.
    public static func canClearGuidedOwner(
        currentOwnerID: UUID?,
        settledOwnerID: UUID
    ) -> Bool {
        currentOwnerID == settledOwnerID
    }
}

public enum GuidedForceHandsFreeTimingPolicy {
    public static func isWaitingForPull(
        handsFreeEnabled: Bool,
        measurementObserved: Bool
    ) -> Bool {
        handsFreeEnabled && !measurementObserved
    }

    public static func shouldReanchor(
        handsFreeEnabled: Bool,
        isMeasuring: Bool,
        measurementObserved: Bool
    ) -> Bool {
        handsFreeEnabled && isMeasuring && !measurementObserved
    }
}

public enum GuidedForceFullscreenPresentation {
    private static let epsilon = 0.000_001

    /// #940: the completion line — ONE source of truth for the panel's
    /// next-step copy (and its accessibility label). It names the inline
    /// action and states where the gauge session's explicit end lives, because
    /// #941 keeps that session live after the protocol ends.
    public static let completionDetail = "Protocol complete · Done returns to your session"

    /// Maps a native stage to the large phase banner. Reverse Action is stored
    /// as one continuous work stage so that it persists one set per recording;
    /// the direction boundary is therefore derived from the stage-local clock
    /// instead of changing the persistence state machine.
    public static func stage(
        _ stage: ForceProtocolStage,
        preset: TindeqPreset,
        elapsedSeconds: Double,
        isPaused: Bool = false
    ) -> GuidedForceStagePresentation {
        let boundedElapsed = min(
            max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0),
            max(0, stage.durationSeconds)
        )
        let progress = stage.durationSeconds > 0
            ? min(1, max(0, boundedElapsed / stage.durationSeconds))
            : 1

        if isPaused {
            return GuidedForceStagePresentation(
                phase: .paused,
                label: "PAUSED",
                detail: detail(for: stage, paused: true),
                accent: .caution,
                symbol: "pause.fill",
                progress: progress
            )
        }

        switch stage.kind {
        case .prepare:
            return make(
                phase: .prepare,
                label: "GET READY",
                detail: detail(for: stage),
                accent: .caution,
                symbol: "hourglass",
                progress: progress
            )
        case .work where preset.protocolMode == .reverseAction:
            let outSeconds = max(0.25, preset.cadenceOutSeconds)
            let returnSeconds = max(0.25, preset.cadenceReturnSeconds)
            let cycle = outSeconds + returnSeconds
            let directionElapsed = boundedElapsed >= stage.durationSeconds
                ? max(0, boundedElapsed - epsilon)
                : boundedElapsed
            let cycleOffset = directionElapsed.truncatingRemainder(dividingBy: cycle)
            let repetition = min(
                max(1, preset.repetitions),
                max(1, Int(directionElapsed / cycle) + 1)
            )
            if cycleOffset < outSeconds {
                return make(
                    phase: .reverseOut,
                    label: "OUT",
                    detail: reverseDetail(stage: stage, repetition: repetition, preset: preset),
                    accent: .execution,
                    symbol: "arrow.up.right",
                    progress: progress
                )
            }
            return make(
                phase: .reverseReturn,
                label: "RETURN",
                detail: reverseDetail(stage: stage, repetition: repetition, preset: preset),
                accent: .primary,
                symbol: "arrow.down.left",
                progress: progress
            )
        case .work:
            return make(
                phase: .hold,
                label: "HOLD",
                detail: detail(for: stage),
                accent: .optimal,
                symbol: "waveform.path.ecg",
                progress: progress
            )
        case .switchSide:
            return make(
                phase: .switchSide,
                label: "SWITCH HANDS",
                detail: detail(for: stage),
                accent: .caution,
                symbol: "arrow.left.arrow.right",
                progress: progress
            )
        case .restBetweenRepetitions:
            return make(
                phase: .rest,
                label: "REST",
                detail: detail(for: stage),
                accent: .primary,
                symbol: "pause.fill",
                progress: progress
            )
        case .restBetweenSets:
            return make(
                phase: .setRest,
                label: "SET REST",
                detail: detail(for: stage),
                accent: .primary,
                symbol: "pause.fill",
                progress: progress
            )
        case .complete:
            return make(
                phase: .complete,
                label: "DONE",
                detail: completionDetail,
                accent: .optimal,
                symbol: "checkmark.circle.fill",
                progress: 1
            )
        }
    }

    private static func make(
        phase: GuidedForcePhase,
        label: String,
        detail: String,
        accent: GuidedForceAccent,
        symbol: String,
        progress: Double
    ) -> GuidedForceStagePresentation {
        GuidedForceStagePresentation(
            phase: phase,
            label: label,
            detail: detail,
            accent: accent,
            symbol: symbol,
            progress: progress
        )
    }

    private static func detail(
        for stage: ForceProtocolStage,
        paused: Bool = false
    ) -> String {
        let prefix = "Set \(stage.setNumber) · Rep \(stage.repetitionNumber)"
        let side = stage.side == .unspecified ? nil : stage.side.label
        if paused {
            return side.map { "\(prefix) · \($0) · resume when ready" }
                ?? "\(prefix) · resume when ready"
        }
        switch stage.kind {
        case .prepare:
            return "\(prefix) · load the Progressor"
        case .switchSide:
            return side.map { "Next: \($0) · \(prefix)" } ?? prefix
        case .restBetweenRepetitions, .restBetweenSets:
            // #939: a rest describes the stage it leads INTO — what the user
            // is about to do — instead of the set that just ended.
            return restLine(for: stage)
        case .complete:
            return completionDetail
        case .work:
            return side.map { "\(prefix) · \($0)" } ?? prefix
        }
    }

    /// #939: the rest line as a shared value. This is the ONE source of truth
    /// for what a rest says: the fullscreen banner renders it through
    /// `detail(for:)` and the Live Activity card renders it in
    /// `GuidedProtocolActivityContent.snapshot(runAnchor:)`, so the lock screen
    /// cannot describe a rest differently from the phone. Nil when the stage is
    /// not a rest.
    public static func restDetail(for stage: ForceProtocolStage) -> String? {
        switch stage.kind {
        case .restBetweenRepetitions, .restBetweenSets:
            return restLine(for: stage)
        default:
            return nil
        }
    }

    private static func restLine(for stage: ForceProtocolStage) -> String {
        // Nothing left to hand off to: the run finishes after this rest. Never
        // invent a next set here (#939) — the schedule emits a rest before
        // `.complete` only if a future protocol shape asks for one.
        guard let handoff = stage.handoff else { return "Last set done · finishing" }
        let hold = "\(Int(handoff.durationSeconds.rounded()))s"
        let cue = handoff.mode == .reverseAction ? "reverse action" : "hold"
        let side = handoff.side == .unspecified ? "" : " · \(handoff.side.label)"
        // Reverse Action repeats are cadence markers inside one continuous
        // stage, so a set rest quotes the set and its duration, not a rep
        // index the user is not at yet.
        let repetition = handoff.mode == .hold ? "Rep \(handoff.repetitionNumber)" : nil
        if stage.kind == .restBetweenRepetitions {
            return "Next: Rep \(handoff.repetitionNumber)/\(handoff.repetitionTotal) · \(hold) \(cue)\(side)"
        }
        let nextRep = repetition.map { " · \($0)" } ?? ""
        return "Next: Set \(handoff.setNumber)\(nextRep) · \(hold) \(cue)\(side)"
    }

    private static func reverseDetail(
        stage: ForceProtocolStage,
        repetition: Int,
        preset: TindeqPreset
    ) -> String {
        let side = stage.side == .unspecified ? nil : " · \(stage.side.label)"
        return "Set \(stage.setNumber) · Rep \(repetition)/\(max(1, preset.repetitions))\(side ?? "")"
    }
}
