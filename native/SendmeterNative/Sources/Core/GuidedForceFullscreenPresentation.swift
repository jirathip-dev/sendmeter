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

/// Sizes for the two elements that must remain usable on the smallest phone:
/// the live trace and the primary circle.  The view may scroll when Dynamic
/// Type makes its intrinsic content taller than the viewport, but it never
/// shrinks either element below these floors.
public struct GuidedForceLayout: Equatable, Sendable {
    public let actionDiameter: Double
    public let chartMinimumHeight: Double
    public let sectionGap: Double
    public let horizontalPadding: Double

    public init(
        actionDiameter: Double,
        chartMinimumHeight: Double,
        sectionGap: Double,
        horizontalPadding: Double
    ) {
        self.actionDiameter = actionDiameter
        self.chartMinimumHeight = chartMinimumHeight
        self.sectionGap = sectionGap
        self.horizontalPadding = horizontalPadding
    }

    /// Resolves a compact layout from the actual available viewport. `textScale`
    /// is supplied by the SwiftUI caller so accessibility sizes reserve more
    /// room without making the chart or action unusably small.
    public static func resolve(
        width: Double,
        height: Double,
        textScale: Double = 1
    ) -> GuidedForceLayout {
        let safeWidth = max(240, width)
        let safeHeight = max(320, height)
        let safeTextScale = min(1.8, max(1, textScale))
        let padding = safeWidth < 360 ? 12 : 16
        let widthBound = min(184, max(96, safeWidth - (Double(padding) * 2)))
        let heightBound = safeHeight < 520
            ? max(96, safeHeight * (safeTextScale > 1.25 ? 0.22 : 0.26))
            : widthBound
        let action = min(widthBound, heightBound)
        let chartFloor = max(
            96,
            min(156, safeHeight * (safeTextScale > 1.25 ? 0.15 : 0.18))
        )
        return GuidedForceLayout(
            actionDiameter: action,
            chartMinimumHeight: chartFloor,
            sectionGap: safeHeight < 520 ? 8 : 12,
            horizontalPadding: Double(padding)
        )
    }
}

public enum GuidedForceFullscreenPresentation {
    private static let epsilon = 0.000_001

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
                detail: "Protocol complete",
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
        case .restBetweenRepetitions:
            return "\(prefix) · unload and breathe"
        case .restBetweenSets:
            return "After set \(stage.setNumber) · unload and reset"
        case .complete:
            return "Protocol complete"
        case .work:
            return side.map { "\(prefix) · \($0)" } ?? prefix
        }
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
