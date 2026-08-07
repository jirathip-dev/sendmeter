import Foundation

// KEEP-IN-SYNC: direct port of `src/lib/handsFreeForce.ts`. Keep phases,
// thresholds, timestamp recovery, and transition claims aligned. This file is
// Foundation-only so the same behavior runs under Linux CI before the watch
// app wires it to CoreBluetooth.

public struct HandsFreeForceConfig: Equatable, Sendable {
    /// Load that must be held continuously before an armed pull begins.
    public let startKg: Double
    /// Lower release threshold. Keeping it below startKg provides hysteresis.
    public let stopKg: Double
    public let startStableMs: Double
    public let stopGraceMs: Double

    public init(startKg: Double, stopKg: Double, startStableMs: Double, stopGraceMs: Double) {
        self.startKg = startKg
        self.stopKg = stopKg
        self.startStableMs = startStableMs
        self.stopGraceMs = stopGraceMs
    }

    public static let `default` = HandsFreeForceConfig(
        startKg: 2,
        stopKg: 1,
        startStableMs: 600,
        stopGraceMs: 1_500
    )
}

public enum HandsFreeForceState: Equatable, Sendable {
    case idle
    case waitingForSlack
    case armed(aboveSinceMs: Double?)
    case recording(belowSinceMs: Double?)
    case stopping
}

public enum HandsFreeForceAction: Equatable, Sendable {
    case start
    case stop
}

public struct HandsFreeForceStep: Equatable, Sendable {
    public let state: HandsFreeForceState
    public let action: HandsFreeForceAction?

    public init(state: HandsFreeForceState, action: HandsFreeForceAction?) {
        self.state = state
        self.action = action
    }
}

public enum HandsFreeForceInactiveStatus: Equatable, Sendable {
    case connected
    case idle
    case unsupported
}

public func armedHandsFreeForce() -> HandsFreeForceState {
    .armed(aboveSinceMs: nil)
}

/// A post-save re-arm must observe an unloaded gauge before it can recognize
/// another pull. Otherwise a manual Stop & Save while still hanging turns the
/// same continuous load into a phantom second rep after `startStableMs`.
public func rearmedHandsFreeForce() -> HandsFreeForceState {
    .waitingForSlack
}

public func idleHandsFreeForce() -> HandsFreeForceState {
    .idle
}

/// Reconcile the control claim while the transport reports an inactive
/// status. `connected + armed/waitingForSlack` is the intentional overlap:
/// the state machine owns a live weight stream while the transport-facing
/// status remains connected.
public func handsFreeForceAtInactiveStatus(
    _ state: HandsFreeForceState,
    status: HandsFreeForceInactiveStatus
) -> HandsFreeForceState {
    if status == .connected {
        switch state {
        case .armed, .waitingForSlack: return state
        case .idle, .recording, .stopping: break
        }
    }
    return state == .idle ? state : idleHandsFreeForce()
}

/// Observe one live force sample. The returned state claims an emitted action
/// before the caller performs any async work: `recording` claims Start and
/// `stopping` claims Stop, so repeated samples cannot emit the same action.
public func stepHandsFreeForce(
    _ state: HandsFreeForceState,
    atMs: Double,
    kg: Double,
    config: HandsFreeForceConfig = .default
) -> HandsFreeForceStep {
    switch state {
    case .idle, .stopping:
        return HandsFreeForceStep(state: state, action: nil)

    case .waitingForSlack:
        return kg <= config.stopKg
            ? HandsFreeForceStep(state: armedHandsFreeForce(), action: nil)
            : HandsFreeForceStep(state: state, action: nil)

    case .armed(let existingAboveSinceMs):
        guard kg >= config.startKg else {
            let next = existingAboveSinceMs == nil ? state : HandsFreeForceState.armed(aboveSinceMs: nil)
            return HandsFreeForceStep(state: next, action: nil)
        }
        let aboveSinceMs: Double
        if let existingAboveSinceMs, atMs >= existingAboveSinceMs {
            aboveSinceMs = existingAboveSinceMs
        } else {
            aboveSinceMs = atMs
        }
        guard atMs - aboveSinceMs >= config.startStableMs else {
            return HandsFreeForceStep(state: .armed(aboveSinceMs: aboveSinceMs), action: nil)
        }
        return HandsFreeForceStep(state: .recording(belowSinceMs: nil), action: .start)

    case .recording(let existingBelowSinceMs):
        guard kg <= config.stopKg else {
            let next = existingBelowSinceMs == nil ? state : HandsFreeForceState.recording(belowSinceMs: nil)
            return HandsFreeForceStep(state: next, action: nil)
        }
        let belowSinceMs: Double
        if let existingBelowSinceMs, atMs >= existingBelowSinceMs {
            belowSinceMs = existingBelowSinceMs
        } else {
            belowSinceMs = atMs
        }
        guard atMs - belowSinceMs >= config.stopGraceMs else {
            return HandsFreeForceStep(state: .recording(belowSinceMs: belowSinceMs), action: nil)
        }
        return HandsFreeForceStep(state: .stopping, action: .stop)
    }
}

/// Why a recording stopped (issue #503). `.released` is the only case that
/// carries a trim timestamp — the state machine's own below-threshold start —
/// and the only case that may re-arm without observing slack first: its grace
/// window already proved `stopGraceMs` of unloaded gauge. Every other stop
/// can happen mid-hold, where re-arming immediately turns the same continuous
/// load into a phantom rep (#467). Binding the timestamp into the case makes
/// the coupling structural: a call site cannot trim the low-force tail
/// without declaring release, and cannot declare release without the proof
/// timestamp. Watch-side only — not part of the ported `handsFreeForce.ts`
/// machine (the web stop path has no save/restart dark window to bridge).
public enum HandsFreeStopReason: Equatable, Sendable {
    case released(endMs: Double)
    case userTapped
    case cappedAt30Min

    /// Timestamp to trim the recording's low-force tail at; nil for stops
    /// with no proven release point (the whole buffer is the rep).
    public var trimEndMs: Double? {
        if case .released(let endMs) = self { return endMs }
        return nil
    }
}

/// The state a hands-free stream re-arms into after a save, decided by WHY
/// the recording stopped rather than by which optional parameters a call
/// site happened to pass. Automatic release has already proved
/// `stopGraceMs` of slack, so requiring another slack sample after the
/// stop/save/restart dark window would silently miss a fast next rep; a tap
/// or the 30-minute cap has no such proof and must gate the same continuous
/// load behind fresh slack before re-arming.
public func rearmedHandsFreeForce(afterStop reason: HandsFreeStopReason) -> HandsFreeForceState {
    switch reason {
    case .released: return armedHandsFreeForce()
    case .userTapped, .cappedAt30Min: return rearmedHandsFreeForce()
    }
}

/// Labels and identity snapshotted when a rep starts. The stop path consumes
/// this value synchronously, before its first persistence await, so an
/// auto-stop racing a tap cannot enqueue the same rep twice.
public struct HandsFreeForceRepClaim: Equatable, Sendable {
    public let id: UUID
    public let tag: String
    public let side: String

    public init(id: UUID, tag: String, side: String) {
        self.id = id
        self.tag = tag
        self.side = side
    }
}

public struct HandsFreeForceRepClaims: Equatable, Sendable {
    public private(set) var active: HandsFreeForceRepClaim?

    public init() {}

    /// Starts one claim only when no recording is already active.
    @discardableResult
    public mutating func begin(id: UUID = UUID(), tag: String, side: String) -> HandsFreeForceRepClaim? {
        guard active == nil else { return nil }
        let claim = HandsFreeForceRepClaim(id: id, tag: tag, side: side)
        active = claim
        return claim
    }

    /// The check and removal are one synchronous operation. Callers must do
    /// this before constructing any Task or reaching any `await`.
    public mutating func claimStop() -> HandsFreeForceRepClaim? {
        guard let claim = active else { return nil }
        active = nil
        return claim
    }

    public mutating func discard() {
        active = nil
    }
}
