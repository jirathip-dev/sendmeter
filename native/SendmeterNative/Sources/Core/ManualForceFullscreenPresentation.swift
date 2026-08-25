import Foundation

/// Presentation lifecycle for a regular phone Force recording. The live
/// samples and persistence remain owned by `TindeqBluetooth`/`AppModel`; this
/// small state machine only owns the fullscreen viewport's action semantics.
/// In particular, minimizing never transitions to idle and a failed durable
/// save leaves the completed buffer available for retry.
public enum ManualForceFullscreenPhase: String, Equatable, Sendable {
    case idle
    case armed
    case measuring
    case saving
    case readyToSave
    case saved
    case interrupted
}

public struct ManualForceFullscreenLifecycle: Equatable, Sendable {
    public private(set) var phase: ManualForceFullscreenPhase

    public init(phase: ManualForceFullscreenPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    public mutating func open(armed: Bool) -> Bool {
        guard phase == .idle else { return false }
        phase = armed ? .armed : .measuring
        return true
    }

    /// A hands-free pull promoted the armed stream to a real recording.
    @discardableResult
    public mutating func beginRecording() -> Bool {
        guard phase == .armed || phase == .measuring else { return false }
        phase = .measuring
        return true
    }

    /// A successful hands-free save has re-armed the stream for the next pull.
    @discardableResult
    public mutating func rearm() -> Bool {
        guard phase == .measuring || phase == .armed || phase == .saving else { return false }
        phase = .armed
        return true
    }

    /// Claims a manual save before its first persistence await.
    @discardableResult
    public mutating func requestSave() -> Bool {
        guard phase == .measuring || phase == .readyToSave else { return false }
        phase = .saving
        return true
    }

    public mutating func saveSucceeded() {
        guard phase == .saving else { return }
        phase = .saved
    }

    public mutating func saveFailed() {
        guard phase == .saving else { return }
        phase = .readyToSave
    }

    /// The transport can finish a regular pull at its safety cap without a
    /// user tapping Stop. Keep the completed buffer visible until the same
    /// explicit durable-save action is taken.
    @discardableResult
    public mutating func markReadyToSave() -> Bool {
        guard phase == .measuring else { return false }
        phase = .readyToSave
        return true
    }

    @discardableResult
    public mutating func cancelArm() -> Bool {
        guard phase == .armed else { return false }
        phase = .idle
        return true
    }

    public mutating func interrupted() {
        guard phase != .idle, phase != .saved else { return }
        phase = .interrupted
    }

    public var keepsRecordingAliveWhenMinimized: Bool {
        switch phase {
        case .armed, .measuring, .saving, .readyToSave:
            return true
        case .idle, .saved, .interrupted:
            return false
        }
    }

    public var canDismiss: Bool {
        phase == .idle || phase == .saved || phase == .interrupted
    }
}

public struct ManualForceStagePresentation: Equatable, Sendable {
    public let label: String
    public let detail: String
    public let accent: GuidedForceAccent
    public let symbol: String

    public init(
        label: String,
        detail: String,
        accent: GuidedForceAccent,
        symbol: String
    ) {
        self.label = label
        self.detail = detail
        self.accent = accent
        self.symbol = symbol
    }
}

public enum ManualForceFullscreenPresentation {
    public static func stage(
        phase: ManualForceFullscreenPhase,
        exercise: String,
        side: TindeqSide,
        elapsedSeconds: Double
    ) -> ManualForceStagePresentation {
        let exerciseText = exercise.isEmpty ? "Free pull" : exercise
        let sideText = side == .unspecified ? nil : side.label
        let context = sideText.map { "\(exerciseText) · \($0)" } ?? exerciseText
        let elapsed = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
        let elapsedText = formatClock(elapsed)

        switch phase {
        case .idle:
            return ManualForceStagePresentation(
                label: "READY",
                detail: context,
                accent: .primary,
                symbol: "waveform.path.ecg"
            )
        case .armed:
            return ManualForceStagePresentation(
                label: "PULL TO START",
                detail: "Hands-free · \(context)",
                accent: .caution,
                symbol: "scope"
            )
        case .measuring:
            return ManualForceStagePresentation(
                label: "MEASURING",
                detail: "\(context) · \(elapsedText)",
                accent: .optimal,
                symbol: "record.circle.fill"
            )
        case .saving:
            return ManualForceStagePresentation(
                label: "SAVING",
                detail: "Keeping this pull on device while it syncs",
                accent: .caution,
                symbol: "arrow.down.doc.fill"
            )
        case .readyToSave:
            return ManualForceStagePresentation(
                label: "READY TO SAVE",
                detail: "The completed pull is still available to retry",
                accent: .caution,
                symbol: "externaldrive.fill"
            )
        case .saved:
            return ManualForceStagePresentation(
                label: "SAVED",
                detail: "Pull queued on this device",
                accent: .optimal,
                symbol: "checkmark.circle.fill"
            )
        case .interrupted:
            return ManualForceStagePresentation(
                label: "CONNECTION LOST",
                detail: "The existing recovery path is preserving this pull",
                accent: .alert,
                symbol: "bolt.horizontal.circle.fill"
            )
        }
    }

    private static func formatClock(_ seconds: Double) -> String {
        let whole = max(0, Int(floor(seconds)))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
