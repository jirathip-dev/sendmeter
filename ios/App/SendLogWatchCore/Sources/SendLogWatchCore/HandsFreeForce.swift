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
    /// Guard 1 (#682): a rep peaking below this is a trivial non-rep (swing,
    /// transport bump, partner steadying the gauge) and is discarded at
    /// persist time. Never raises the detection threshold: a recording that
    /// started is filtered only on full evidence at the save boundary.
    public let minPeakKg: Double
    /// Guard 1 (#682): a rep shorter than this is a trivial non-rep. Filtered
    /// at persist time, when the full duration is known.
    public let minDurationMs: Double
    /// Guard 2 (#682): a sustained load that stays inside a flatline band for
    /// this long is a non-human load (rope/ hang bag, sensor drift) and is
    /// terminated as `.staticLoad` rather than left recording.
    /// The guard keys on load SHAPE, not on "how long a human might hold":
    /// `ForceProtocol` holds can legitimately run up to 240 s (default 40 s),
    /// so this window is deliberately NOT "longer than any legitimate free
    /// hold". It is the COMBINATION of a tight 0.25 kg peak-to-peak band held
    /// continuously for 30 s that marks a dead/static load; a human hold's
    /// tremor/re-grip micro-adjustments normally break that band well before
    /// 30 s. Residual device-only risk: a genuinely motionless hand could in
    /// principle stay inside the band past the window, which the load-shape
    /// guard cannot distinguish from a dead load without an IMU signal.
    public let flatlineWindowMs: Double
    /// Guard 2 (#682): peak-to-peak band used to decide the load is flat.
    public let flatlineBandKg: Double

    public init(
        startKg: Double,
        stopKg: Double,
        startStableMs: Double,
        stopGraceMs: Double,
        minPeakKg: Double = 3,
        minDurationMs: Double = 1_500,
        flatlineWindowMs: Double = 30_000,
        flatlineBandKg: Double = 0.25
    ) {
        self.startKg = startKg
        self.stopKg = stopKg
        self.startStableMs = startStableMs
        self.stopGraceMs = stopGraceMs
        self.minPeakKg = minPeakKg
        self.minDurationMs = minDurationMs
        self.flatlineWindowMs = flatlineWindowMs
        self.flatlineBandKg = flatlineBandKg
    }

    public static let `default` = HandsFreeForceConfig(
        startKg: 2,
        stopKg: 1,
        startStableMs: 600,
        stopGraceMs: 1_500,
        minPeakKg: 3,
        minDurationMs: 1_500,
        flatlineWindowMs: 30_000,
        flatlineBandKg: 0.25
    )
}

public enum HandsFreeForceState: Equatable, Sendable {
    case idle
    case waitingForSlack
    case armed(aboveSinceMs: Double?)
    case recording(belowSinceMs: Double?, flatWatch: HandsFreeForceFlatWatch?)
    case stopping
}

/// Rolling min/max of the load since the current flat window began (#682).
/// Guard 2's tracker, carried in the `.recording` state so the machine can
/// terminate a sustained non-human load at the first sample of the flat
/// segment. Mirrors the KEEP-IN-SYNC TS shape (`HandsFreeForceFlatWatch`).
public struct HandsFreeForceFlatWatch: Equatable, Sendable {
    /// Recording-clock time (ms) of the first sample of the current window.
    public let sinceMs: Double
    /// Rolling min kg since `sinceMs`.
    public let minKg: Double
    /// Rolling max kg since `sinceMs`.
    public let maxKg: Double

    public init(sinceMs: Double, minKg: Double, maxKg: Double) {
        self.sinceMs = sinceMs
        self.minKg = minKg
        self.maxKg = maxKg
    }
}

public enum HandsFreeForceAction: Equatable, Sendable {
    case start
    case stop
}

public struct HandsFreeForceStep: Equatable, Sendable {
    public let state: HandsFreeForceState
    public let action: HandsFreeForceAction?
    /// Set (non-nil) only when `action == .stop` because Guard 2 (#682)
    /// terminated the recording: the sustained flat load reached
    /// `flatlineWindowMs`. It is the START of the flat window on the
    /// recording clock — the trim the saved rep must end at. `nil` for a
    /// release-triggered stop (the trim is derived from `belowSinceMs` at the
    /// call site) and for every non-stop step.
    public let staticLoadEndMs: Double?

    public init(state: HandsFreeForceState, action: HandsFreeForceAction?, staticLoadEndMs: Double? = nil) {
        self.state = state
        self.action = action
        self.staticLoadEndMs = staticLoadEndMs
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
/// 10-minute cap path. The budget is re-based at every armed-epoch boundary
/// (arm, rep start, save-window entry, re-arm, transport loss), so recording
/// time and the save window never count as idle. Swift-only, outside the
/// KEEP-IN-SYNC ported region: the web has no idle-disarm concept
/// (`src/lib/handsFreeForce.ts` carries no budget/timeout state), so this
/// type has no TS counterpart — only the watch's TindeqManager drives it.
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
/// another pull. Otherwise a "Save now" while still hanging turns the
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
        // Guard 2 (#682): the recording owes its flat-watch tracker to the
        // sample that claimed Start — the first sample of the rep is also the
        // first sample of its (yet-unproven) flat window.
        return HandsFreeForceStep(
            state: .recording(
                belowSinceMs: nil,
                flatWatch: HandsFreeForceFlatWatch(sinceMs: atMs, minKg: kg, maxKg: kg)
            ),
            action: .start
        )

    case .recording(let existingBelowSinceMs, let existingFlatWatch):
        let flatWatch = advancingHandsFreeForceFlatWatch(existingFlatWatch, atMs: atMs, kg: kg, config: config)
        // Guard 2 (#682): a sustained load that stayed inside the flatline
        // band for `flatlineWindowMs` is a proven non-human load — terminate
        // before release detection. The trim is the START of the flat window
        // (the band may have been flat longer than the window), which
        // `advancingHandsFreeForceFlatWatch` resets to the sample that broke
        // the band, so it is exactly the first sample of the continuous flat
        // segment that terminated the recording.
        if atMs - flatWatch.sinceMs >= config.flatlineWindowMs {
            return HandsFreeForceStep(state: .stopping, action: .stop, staticLoadEndMs: flatWatch.sinceMs)
        }
        guard kg <= config.stopKg else {
            return HandsFreeForceStep(state: .recording(belowSinceMs: nil, flatWatch: flatWatch), action: nil)
        }
        let belowSinceMs: Double
        if let existingBelowSinceMs, atMs >= existingBelowSinceMs {
            belowSinceMs = existingBelowSinceMs
        } else {
            belowSinceMs = atMs
        }
        guard atMs - belowSinceMs >= config.stopGraceMs else {
            return HandsFreeForceStep(state: .recording(belowSinceMs: belowSinceMs, flatWatch: flatWatch), action: nil)
        }
        return HandsFreeForceStep(state: .stopping, action: .stop)
    }
}

/// Advance Guard 2's rolling min/max flat-watch tracker (#682). Each sample
/// widens the range; if the widened peak-to-peak range breaks
/// `flatlineBandKg`, the window resets to this sample (the new continuous
/// flat segment's first sample). A nil tracker (a `.recording` state created
/// without a watch, e.g. in a unit fixture) seeds from the current sample.
private func advancingHandsFreeForceFlatWatch(
    _ current: HandsFreeForceFlatWatch?,
    atMs: Double,
    kg: Double,
    config: HandsFreeForceConfig
) -> HandsFreeForceFlatWatch {
    guard let current else {
        return HandsFreeForceFlatWatch(sinceMs: atMs, minKg: kg, maxKg: kg)
    }
    let minKg = min(current.minKg, kg)
    let maxKg = max(current.maxKg, kg)
    if maxKg - minKg > config.flatlineBandKg {
        return HandsFreeForceFlatWatch(sinceMs: atMs, minKg: kg, maxKg: kg)
    }
    return HandsFreeForceFlatWatch(sinceMs: current.sinceMs, minKg: minKg, maxKg: maxKg)
}

/// Why a recording stopped (issue #503). `.released` is the only case that
/// may re-arm without observing slack first: its grace window already proved
/// `stopGraceMs` of unloaded gauge. Every other stop can happen mid-hold,
/// where re-arming immediately turns the same continuous load into a phantom
/// rep (#467). `.released` and `.staticLoad` both carry a trim timestamp —
/// the proven cut point on the recording clock — while `.userTapped` and
/// `.cappedAt30Min` keep the whole buffer. Binding the timestamp into the
/// case makes the coupling structural: a call site cannot trim a recording
/// without declaring the reason, and cannot declare the reason without the
/// proof timestamp. Watch-side only — not part of the ported
/// `handsFreeForce.ts` machine (the web stop path has no save/restart dark
/// window to bridge).
public enum HandsFreeStopReason: Equatable, Sendable {
    /// `endMs` is on the RECORDING clock — the same t0-relative milliseconds
    /// as the sample buffer (`samples[].t`), not the armed stream's absolute
    /// device timestamps. Release can only be detected from `.recording`, so
    /// its below-threshold start is always measured on that clock; the trim
    /// filter compares it directly against `samples[].t`.
    case released(endMs: Double)
    /// Guard 2 (#682): the load stayed inside the flatline band for
    /// `flatlineWindowMs` — a proven non-human sustained load. `endMs` is the
    /// START of the flat window on the recording clock; the saved rep is
    /// truncated there (drop the flat tail), and Guard 1 still evaluates the
    /// trimmed recording at persist. Keeps the stream live (the static load
    /// may still be hanging; a release-to-slack edge inside the async save is
    /// what the machine needs to observe) and re-arms through
    /// `waitingForSlack`, because it has no proof of slack. Same
    /// live/re-arm semantics as `.userTapped`/`.cappedAt30Min`, but with a
    /// proven trim point.
    case staticLoad(endMs: Double)
    case userTapped
    case cappedAt30Min

    /// Timestamp to trim the recording's low-force tail at; nil for stops
    /// with no proven cut point (the whole buffer is the rep).
    /// Exhaustive on purpose (#503): a new case must answer the trim
    /// question here at compile time, exactly like the re-arm question in
    /// `rearmedHandsFreeForce(afterStop:)` — not silently inherit "no trim".
    public var trimEndMs: Double? {
        switch self {
        case .released(let endMs): return endMs
        case .staticLoad(let endMs): return endMs
        case .userTapped, .cappedAt30Min: return nil
        }
    }

    /// Whether this stop keeps the weight stream running through the async
    /// save (#681). A `.released` stop already proved `stopGraceMs` of slack,
    /// so the transport can stop outright and re-arm straight to armed; a tap
    /// or the 10-minute cap has no such proof and keeps the stream live so a
    /// release-to-slack edge inside the save window is still observed. A
    /// `.staticLoad` stop (#682) is the same: the sustained non-human load
    /// gives no slack proof, so keeping the stream live lets the machine
    /// observe the release when the load is cut and re-arm for the next real
    /// pull. The manager's `keepStreamRunning` is this AND transport
    /// availability — decided here in Core so a new stop reason cannot
    /// silently pick the wrong live-window behavior (#681 review F3).
    public var keepsStreamLive: Bool {
        switch self {
        case .released: return false
        case .userTapped, .cappedAt30Min, .staticLoad: return true
        }
    }
}

/// The state a hands-free stream re-arms into after a save, decided by WHY
/// the recording stopped rather than by which optional parameters a call
/// site happened to pass. Automatic release has already proved
/// `stopGraceMs` of slack, so requiring another slack sample after the
/// stop/save/restart dark window would silently miss a fast next rep; a tap,
/// the 10-minute cap, or a `.staticLoad` termination has no such proof and
/// must gate the same continuous load behind fresh slack before re-arming.
public func rearmedHandsFreeForce(afterStop reason: HandsFreeStopReason) -> HandsFreeForceState {
    switch reason {
    case .released: return armedHandsFreeForce()
    case .userTapped, .cappedAt30Min, .staticLoad: return rearmedHandsFreeForce()
    }
}

/// Guard 1 (#682): the persist-boundary verdict for a hands-free rep. Runs
/// LAST, after any termination (including a `.staticLoad` truncation), on the
/// recording's final evidence. A trivial non-rep — a swing, a transport bump,
/// a partner steadying the gauge — that cleared the detection thresholds is
/// discarded here, silently, and must never enter the recording queue nor be
/// reported as queued. Deliberately does NOT raise `startKg`/`startStableMs`:
/// those are detection thresholds; filtering belongs at persist time, on full
/// evidence. KEEP-IN-SYNC with `recordingVerdict` in `src/lib/handsFreeForce.ts`.
public enum HandsFreeForceRecordingVerdict: Equatable, Sendable {
    case persist
    case discard(reason: HandsFreeForceDiscardReason)
}

public enum HandsFreeForceDiscardReason: Equatable, Sendable {
    case belowMinPeak
    case belowMinDuration
}

public func recordingVerdict(
    peakKg: Double,
    durationMs: Double,
    config: HandsFreeForceConfig = .default
) -> HandsFreeForceRecordingVerdict {
    if peakKg < config.minPeakKg {
        return .discard(reason: .belowMinPeak)
    }
    if durationMs < config.minDurationMs {
        return .discard(reason: .belowMinDuration)
    }
    return .persist
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
