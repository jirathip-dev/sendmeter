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

/// Idle-disarm budget for a live armed stream (#681 review F1). The watch
/// keeps the weight stream running through tap/cap saves, so armed samples
/// keep flowing while the async save runs; without re-basing, the
/// sample-clock idle check would count the whole rep plus pre-rep idle
/// against the save window and spuriously disarm — guaranteed on the
/// 30-minute cap path. The budget is re-based at every armed-epoch boundary
/// (arm, rep start, save-window entry, re-arm, transport loss), so recording
/// time and the save window never count as idle. The web never drives an
/// idle disarm (a nil/zero timeout is always within budget); the type exists
/// for KEEP-IN-SYNC parity and the shared regression tests.
public struct ArmedStreamIdleBudget: Equatable, Sendable {
    /// Device timestamp (µs) of the first sample of the current armed epoch.
    public private(set) var baseUs: UInt32?

    public init() {}

    public init(baseUs: UInt32?) {
        self.baseUs = baseUs
    }
}

public struct ArmedStreamIdleStep: Equatable, Sendable {
    public let budget: ArmedStreamIdleBudget
    /// True when the sample falls at/after `timeoutSeconds` of the epoch —
    /// the caller must disarm the armed stream.
    public let idleExceeded: Bool

    public init(budget: ArmedStreamIdleBudget, idleExceeded: Bool) {
        self.budget = budget
        self.idleExceeded = idleExceeded
    }
}

/// Observe one armed-stream sample against the idle budget. The first sample
/// of an epoch establishes the base instead of disarming, so a sample inside
/// the save window at a device timestamp past the arm timeout (the stale
/// pre-rep base would compute the whole rep as idle) never cancels. UInt32
/// wrapping subtraction mirrors the device clock's 32-bit µs counter.
public func observeArmedStreamIdleBudget(
    _ budget: ArmedStreamIdleBudget,
    sampleUs: UInt32,
    timeoutSeconds: Double?
) -> ArmedStreamIdleStep {
    guard let timeoutSeconds, timeoutSeconds > 0 else {
        return ArmedStreamIdleStep(budget: budget, idleExceeded: false)
    }
    let base = budget.baseUs ?? sampleUs
    return ArmedStreamIdleStep(
        budget: ArmedStreamIdleBudget(baseUs: base),
        idleExceeded: Double(sampleUs &- base) / 1000 >= timeoutSeconds * 1000
    )
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
    /// `endMs` is on the RECORDING clock — the same t0-relative milliseconds
    /// as the sample buffer (`samples[].t`), not the armed stream's absolute
    /// device timestamps. Release can only be detected from `.recording`, so
    /// its below-threshold start is always measured on that clock; the trim
    /// filter compares it directly against `samples[].t`.
    case released(endMs: Double)
    case userTapped
    case cappedAt30Min

    /// Timestamp to trim the recording's low-force tail at; nil for stops
    /// with no proven release point (the whole buffer is the rep).
    /// Exhaustive on purpose (#503): a new case must answer the trim
    /// question here at compile time, exactly like the re-arm question in
    /// `rearmedHandsFreeForce(afterStop:)` — not silently inherit "no trim".
    public var trimEndMs: Double? {
        switch self {
        case .released(let endMs): return endMs
        case .userTapped, .cappedAt30Min: return nil
        }
    }

    /// Whether this stop keeps the weight stream running through the async
    /// save (#681). A `.released` stop already proved `stopGraceMs` of slack,
    /// so the transport can stop outright and re-arm straight to armed; a tap
    /// or the 30-minute cap has no such proof and keeps the stream live so a
    /// release-to-slack edge inside the save window is still observed. The
    /// manager's `keepStreamRunning` is this AND transport availability —
    /// decided here in Core so a new stop reason cannot silently pick the
    /// wrong live-window behavior (#681 review F3).
    public var keepsStreamLive: Bool {
        switch self {
        case .released: return false
        case .userTapped, .cappedAt30Min: return true
        }
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
