import Foundation
import Observation
import SendLogWatchCore
import WatchKit

/// App-scoped bridge between the Force activity policy (`ForceRuntimePolicy`)
/// and the watchOS extended-runtime session.
///
/// One session is owned here, keyed to the Force activity state rather than
/// any SwiftUI view's lifetime, so a measurement keeps its runtime across view
/// refreshes and navigation.  Free hold, hands-free pulls and guided measured
/// work all route through the single `update(_:mode:)` seam — there is no
/// per-view keep-awake logic anywhere else.
///
/// The runtime session is *best-effort*, not a correctness gate: if watchOS
/// refuses to start a session (app not frontmost, expired, resource limit) or
/// ends one early, measurement, recording and persistence proceed unchanged.
/// The display simply falls back to the system's reduced-luminance treatment,
/// which the views already present via `isLuminanceReduced`.
///
/// Force is a short, therapy-style measured activity — not a HealthKit
/// workout — so this deliberately uses `WKExtendedRuntimeSession` rather than
/// `HKWorkoutSession`.  No bundle identifier is touched; the session type is
/// granted from the existing `WKBackgroundModes` declaration.
@MainActor
@Observable
final class ForceRuntimeCoordinator: NSObject, WKExtendedRuntimeSessionDelegate {
    private(set) var activityState: ForceActivityState = .idle
    private(set) var activityMode: ForceActivityMode = .freeHold

    @ObservationIgnored private var runtimeSession: WKExtendedRuntimeSession?
    @ObservationIgnored private var activelyHolding = false

    /// The reduced-luminance presentation spec for the current activity.
    var reducedLuminanceSpec: ForceReducedLuminanceSpec {
        ForceRuntimePolicy.reducedLuminanceSpec(for: activityState, mode: activityMode)
    }

    /// Derives the current Force activity state/mode from the live app-scoped
    /// managers and reconciles the runtime session.  The managers are read
    /// synchronously here (no captured copies) so a foreground refresh or an
    /// `onChange` observer always sees the latest values.
    func sync(tindeq: TindeqManager, runner: GuidedForceRunner) {
        update(state: activityState(tindeq: tindeq, runner: runner),
               mode: activityMode(tindeq: tindeq, runner: runner))
    }

    private func activityState(tindeq: TindeqManager, runner: GuidedForceRunner) -> ForceActivityState {
        if runner.isActive {
            switch runner.phase {
            case .preparing, .rest: return .guidedRest
            case .work: return .guidedWork
            case .idle, .completed, .failed, .stopping: return .finished
            }
        }
        switch tindeq.status {
        case .measuring: return .measuring
        case .unsupported, .idle, .scanning, .connecting, .connected: return .idle
        }
    }

    private func activityMode(tindeq: TindeqManager, runner: GuidedForceRunner) -> ForceActivityMode {
        if runner.isActive { return .guided }
        if tindeq.handsFreeRequested { return .handsFree }
        return .freeHold
    }

    /// Reconciles the runtime session and reduced-luminance spec against the
    /// current Force activity.  Called synchronously by the app-scoped state
    /// observers (`onChange(of: tindeq.status)` / `onChange(of: runner.phase)`),
    /// which read live manager values rather than any captured copy.
    func update(_ state: ForceActivityState, mode: ForceActivityMode) {
        let oldState = activityState
        activityState = state
        activityMode = mode

        switch ForceRuntimePolicy.runtimeRequirement(for: state, mode: mode) {
        case .isolate:
            beginRuntimeIfNeeded()
        case .none:
            endRuntime()
        }

        // A start cue on entering measured work keeps a pull trustworthy when
        // the wrist is already down.  Guided work already cues its own phase
        // haptics in the guided runner, so leave that duplication out — this
        // only confirms a free-hold / hands-free start.
        if oldState != state, state == .measuring {
            acknowledge(.start)
        }
    }

    /// Plays a confirmation haptic for a Force boundary event, per the Core
    /// policy.  The guided runner still owns its own phase cues; this is for
    /// the explicit user/boundary confirmations the policy specifies.
    func acknowledge(_ event: ForceHapticEvent) {
        guard ForceRuntimePolicy.shouldAcknowledgeHaptic(for: event) else { return }
        WKInterfaceDevice.current().play(Haptic.hapticType(for: event))
    }

    /// Drops the runtime session and resets the held activity.  Used at app
    /// teardown so no stale session outlives the scene.
    func invalidate() {
        endRuntime()
        activityState = .idle
        activityMode = .freeHold
    }

    private func beginRuntimeIfNeeded() {
        // Dedupe guard BEFORE any system call that could re-enter.  A runtime
        // session is best-effort, never a correctness gate.
        guard !activelyHolding else { return }

        let session = runtimeSession ?? WKExtendedRuntimeSession.session()
        runtimeSession = session
        session.delegate = self
        // Mark intent BEFORE `start()`: if watchOS synchronously reports a
        // start failure through the delegate, we still want that callback to
        // clear `activelyHolding` (and this path never leaves it set with no
        // session). `start()` must be called while the app is frontmost; a
        // `mustBeActiveToStartOrSchedule` failure is graceful degradation,
        // not a measurement gate.
        activelyHolding = true
        session.start()
    }

    private func endRuntime() {
        guard activelyHolding else { return }
        activelyHolding = false
        runtimeSession?.invalidate()
        runtimeSession = nil
    }

    // MARK: - WKExtendedRuntimeSessionDelegate

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // `activelyHolding` is set synchronously at `start()`; the session is
        // already running.  Nothing to reconcile here.
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard self.runtimeSession === extendedRuntimeSession else { return }
            // The system is about to end the session.  Measured work keeps
            // going best-effort; release bookkeeping so a later `isolate` can
            // request a fresh session if the activity is still measured.
            self.activelyHolding = false
            self.runtimeSession = nil
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWithReason reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.runtimeSession === extendedRuntimeSession else { return }
            self.activelyHolding = false
            self.runtimeSession = nil
        }
    }
}

/// Maps Core haptic events onto the WatchKit haptic type the policy invites.
private enum Haptic {
    static func hapticType(for event: ForceHapticEvent) -> WKHapticType {
        switch event {
        case .start: return .start
        case .stop: return .stop
        case .save, .salvage: return .notification
        case .failure: return .failure
        case .finish: return .success
        }
    }
}
