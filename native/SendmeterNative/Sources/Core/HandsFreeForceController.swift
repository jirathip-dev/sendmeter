import Foundation
import SendLogWatchCore

/// Drives the hands-free arming loop (#628) over the shared
/// `SendLogWatchCore/HandsFreeForce` state machine — the SAME machine the
/// web (`src/lib/handsFreeForce.ts`) and the watch run, so the arm thresholds,
/// hysteresis and timestamp recovery are already pinned by their test suites.
/// This controller is only the phone-side glue: it feeds live force samples
/// into the machine, claims each emitted action exactly once, and reconciles
/// the machine state with the transport.
///
/// Two stop policies cover the two surfaces:
/// - `.automatic` (free pulls on the Force tab): a release-triggered stop
///   auto-saves the rep via `onStopAndSave`, then the caller calls
///   `rearmAfterSave()` once the save is durable — the machine re-arms into
///   the phase `rearmedHandsFreeForce(afterStop:)` decides (armed directly
///   for a proven release, waiting-for-slack for a manual tap).
/// - `.callerOwned` (guided protocols): the protocol's stage timer owns every
///   stop/save (save-per-hold must stay intact — never double-count); the
///   machine only gates WHEN a work stage starts measuring (load applied),
///   and the protocol re-arms on the next work stage via `arm()`.
@MainActor
public final class HandsFreeForceController {
    public enum StopPolicy: Equatable, Sendable {
        /// The controller owns the release-triggered stop/save loop.
        case automatic
        /// The caller (guided protocol) owns every stop and save.
        case callerOwned
    }

    public private(set) var state: HandsFreeForceState = .idle {
        didSet {
            let oldFlags = Self.observationFlags(for: oldValue)
            let newFlags = Self.observationFlags(for: state)
            guard oldFlags.armed != newFlags.armed
                || oldFlags.measuring != newFlags.measuring
            else { return }
            onStateChange?()
        }
    }
    public var stopPolicy: StopPolicy = .automatic

    /// AppModel's Observation bridge. The controller stays a Foundation/Core
    /// type so it can keep its iOS 16/macOS 13 package floor; the app model
    /// turns each state transition into one tracked revision for Force views.
    public var onStateChange: (() -> Void)?

    /// Start the device's weight stream WITHOUT recording (the Progressor
    /// only publishes force after the start command; arming keeps the stream
    /// live so the machine can watch the load before the recording begins).
    public var onArmStream: () -> Void = {}
    /// Stop the device's weight stream.
    public var onDisarmStream: () -> Void = {}
    /// Promote the live stream to a real recording (pre-start samples are
    /// discarded by the transport — arming load never leaks into a save).
    public var onBeginRecording: () -> Void = {}
    /// The claimed stop: save the just-stopped rep. Called at most once per
    /// rep — the machine's `.stopping` phase is the claim.
    public var onStopAndSave: () -> Void = {}
    /// Restart the weight stream after a durable save so the machine can see
    /// the next pull.
    public var onAutoReArm: () -> Void = {}

    private let config: HandsFreeForceConfig
    private var pendingStopReason: HandsFreeStopReason?
    private var recordingStartedFeedMs: Double?
    private var pendingTrimEndMs: Double?

    public init(config: HandsFreeForceConfig = .default) {
        self.config = config
    }

    private static func observationFlags(
        for state: HandsFreeForceState
    ) -> (armed: Bool, measuring: Bool) {
        switch state {
        case .armed, .waitingForSlack:
            return (true, false)
        case .recording:
            return (false, true)
        case .idle, .stopping:
            return (false, false)
        }
    }

    /// The stream is live and the machine owns it: `.armed`/`.waitingForSlack`
    /// are the intentional overlap where the machine holds the stream while
    /// the transport-facing status remains connected (same reconciliation as
    /// `handsFreeForceAtInactiveStatus`).
    public var isArmed: Bool {
        if case .armed = state { return true }
        return state == .waitingForSlack
    }

    public var isMeasuring: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Arm from any non-recording state. `.recording` means the caller never
    /// stopped the previous rep — a caller bug; refuse rather than discard
    /// the live recording.
    public func arm() {
        if case .recording = state { return }
        guard !isArmed else { return }
        state = armedHandsFreeForce()
        onArmStream()
    }

    /// Disarm and stop the stream. Safe from any state; a no-op when already
    /// idle.
    public func disarm() {
        guard state != .idle else { return }
        state = idleHandsFreeForce()
        pendingStopReason = nil
        pendingTrimEndMs = nil
        onDisarmStream()
    }

    /// Observe one live force sample. The machine's phase transition claims
    /// the emitted action before any async work, so repeated samples cannot
    /// emit the same action twice.
    public func feed(atMs: Double, kg: Double) {
        let previous = state
        let step = stepHandsFreeForce(previous, atMs: atMs, kg: kg, config: config)
        state = step.state
        switch step.action {
        case .start:
            recordingStartedFeedMs = atMs
            onBeginRecording()
        case .stop:
            guard stopPolicy == .automatic else { return }
            if let staticLoadEndMs = step.staticLoadEndMs {
                // Guard 2 (#682): the machine proved a sustained flat load
                // (non-human rope/hang bag, sensor drift). The trim is the
                // START of the flat window on the feed clock; convert it to
                // the RECORDING clock (the summary samples are t0-relative)
                // exactly like the release path below.
                let recordingStart = recordingStartedFeedMs ?? atMs
                pendingStopReason = .staticLoad(endMs: max(0, staticLoadEndMs - recordingStart))
                pendingTrimEndMs = max(0, staticLoadEndMs - recordingStart)
            } else {
                pendingStopReason = .released(endMs: 0)
                if case let .recording(belowSinceMs, _) = previous, let belowSinceMs {
                    // The release point on the RECORDING clock (the samples are
                    // t0-relative): the feed clock minus when the recording began
                    // (#503's trim contract — the saved rep must end at the
                    // proven release, not at the first below-threshold sample).
                    let recordingStart = recordingStartedFeedMs ?? atMs
                    pendingTrimEndMs = max(0, belowSinceMs - recordingStart)
                } else {
                    pendingTrimEndMs = nil
                }
            }
            onStopAndSave()
        case nil:
            break
        }
    }

    /// Manual Stop & Save while hands-free is recording — the tap case
    /// (#467): the same continuous load must observe slack before the next
    /// pull can be recognized.
    public func stopManually() {
        guard isMeasuring else { return }
        state = .stopping
        guard stopPolicy == .automatic else { return }
        pendingStopReason = .userTapped
        pendingTrimEndMs = nil
        onStopAndSave()
    }

    /// Cancel an armed-but-not-yet-recording stream (the user tapped Arm and
    /// changed their mind).
    public func cancelArm() {
        guard isArmed else { return }
        state = idleHandsFreeForce()
        pendingStopReason = nil
        pendingTrimEndMs = nil
        onDisarmStream()
    }

    /// The trim timestamp for the just-stopped rep, on the RECORDING clock —
    /// nil for stops with no proven release point (manual tap, or nothing
    /// measured). Consumed by the save path and cleared here, so a trim can
    /// never be applied to a later rep.
    public func consumeTrimEndMilliseconds() -> Double? {
        defer { pendingTrimEndMs = nil }
        return pendingTrimEndMs
    }

    /// Call after the stop's save is DURABLE: re-arm into the phase the stop
    /// reason dictates (proven release → armed immediately; manual tap →
    /// waiting-for-slack) and restart the stream.
    public func rearmAfterSave() {
        guard let reason = pendingStopReason else { return }
        pendingStopReason = nil
        state = rearmedHandsFreeForce(afterStop: reason)
        onAutoReArm()
    }

    /// Reconcile the machine with a lost transport (BLE drop, Bluetooth off):
    /// nothing is armed or recording any more, and a disconnect must never
    /// re-arm.
    public func handleDisconnected() {
        state = idleHandsFreeForce()
        pendingStopReason = nil
        pendingTrimEndMs = nil
        onDisarmStream()
    }
}
