import Foundation

/// The Force activity states that gate an extended runtime session and the
/// reduced-luminance presentation.
///
/// Pure Foundation so the policy is host-testable; the WatchKit adapter
/// (`ForceRuntimeCoordinator`) maps these onto `WKExtendedRuntimeSession`.
/// watchOS intentionally dims in Always On / wrist-down, so this policy never
/// claims to prevent dimming — it decides (a) when a runtime session is
/// genuinely needed to keep measured work streaming, (b) what minimal set a
/// reduced-luminance frame must render, and (c) which boundary events deserve
/// a haptic confirmation so a dim pull can be trusted.
public enum ForceActivityState: Sendable, Equatable, CaseIterable {
    /// No Force activity in progress (gauge connected or not measuring).
    case idle
    /// A free-hold or hands-free rep is actively recording.
    case measuring
    /// A guided protocol is in a measured work segment (static hold / movement).
    case guidedWork
    /// A guided protocol is in a prepare/rest/set-rest segment.
    case guidedRest
    /// An interrupted recording is being recovered after transport loss.
    case salvaging
    /// The run reached a terminal state (complete / stopped / failed / discard).
    case finished
}

/// The Force activity family a state belongs to.  Used to disambiguate a
/// `.measuring` state (free hold vs hands-free) and to keep the guided family
/// separate from the always-armed free hold.
public enum ForceActivityMode: Sendable, Equatable, CaseIterable {
    case freeHold
    case handsFree
    case guided
}

/// Why a runtime session is held.  Kept terse and semantic so the coordinator
/// can observe/log without needing manager internals.
public enum ForceRuntimeReason: Sendable, Equatable, CaseIterable {
    case freeHoldPull
    case handsFreePull
    case guidedWork
}

/// The policy answer for whether a runtime session should be held.
public enum ForceRuntimeRequirement: Sendable, Equatable {
    /// No runtime session should be held.
    case none
    /// Hold the runtime session so measured work keeps streaming.
    case isolate(reason: ForceRuntimeReason)
}

/// The minimal, deterministic set of fields a reduced-luminance Force frame
/// should render.  Nonessential controls (buttons, sparklines, progress bars)
/// are intentionally outside this spec — they are dropped when luminance is
/// reduced.
public struct ForceReducedLuminanceSpec: Sendable, Equatable {
    public let showsCurrentForce: Bool
    public let showsPeakForce: Bool
    public let showsPhaseCountdown: Bool
    public let showsSide: Bool
    public let stateWord: String

    public init(
        showsCurrentForce: Bool,
        showsPeakForce: Bool,
        showsPhaseCountdown: Bool,
        showsSide: Bool,
        stateWord: String
    ) {
        self.showsCurrentForce = showsCurrentForce
        self.showsPeakForce = showsPeakForce
        self.showsPhaseCountdown = showsPhaseCountdown
        self.showsSide = showsSide
        self.stateWord = stateWord
    }
}

/// The Force boundary events that can carry a confirmation haptic.
public enum ForceHapticEvent: Sendable, Equatable {
    case start
    case stop
    case save
    case salvage
    case failure
    case finish
}

/// Deterministic policy for the Force runtime session, reduced-luminance
/// presentation, and haptic confirmations.  Mirrors the style of the other
/// pure `*Policy` enums in this module.
public enum ForceRuntimePolicy {
    /// Whether an extended runtime session should be held for the given
    /// activity state.  Only real measured work isolates the runtime
    /// (`.measuring`, `.guidedWork`); rest/prepare and terminal states release
    /// it.  A runtime session is never acquired for its own sake.
    public static func runtimeRequirement(
        for state: ForceActivityState,
        mode: ForceActivityMode
    ) -> ForceRuntimeRequirement {
        switch state {
        case .idle, .guidedRest, .salvaging, .finished:
            return .none
        case .measuring:
            switch mode {
            case .freeHold: return .isolate(reason: .freeHoldPull)
            case .handsFree: return .isolate(reason: .handsFreePull)
            case .guided: return .isolate(reason: .guidedWork)
            }
        case .guidedWork:
            return .isolate(reason: .guidedWork)
        }
    }

    /// The minimal essential set to render when luminance is reduced.
    ///
    /// - `.measuring` / `.guidedWork`: current force, peak force, phase/count,
    ///   side and a terse state word — the live numbers a climber needs at a
    ///   glance while a dim pull is in progress.
    /// - `.guidedRest`: countdown + side but no force readings (not measuring).
    /// - `.idle` / `.salvaging` / `.finished`: no live readings, just a terse
    ///   state word so the screen never looks hung.
    public static func reducedLuminanceSpec(
        for state: ForceActivityState,
        mode: ForceActivityMode
    ) -> ForceReducedLuminanceSpec {
        switch state {
        case .idle:
            return ForceReducedLuminanceSpec(
                showsCurrentForce: false,
                showsPeakForce: false,
                showsPhaseCountdown: false,
                showsSide: false,
                stateWord: "Ready"
            )
        case .measuring:
            return ForceReducedLuminanceSpec(
                showsCurrentForce: true,
                showsPeakForce: true,
                showsPhaseCountdown: true,
                showsSide: mode != .guided,
                stateWord: mode == .handsFree ? "Pull" : "Hold"
            )
        case .guidedWork:
            return ForceReducedLuminanceSpec(
                showsCurrentForce: true,
                showsPeakForce: true,
                showsPhaseCountdown: true,
                showsSide: true,
                stateWord: "Work"
            )
        case .guidedRest:
            return ForceReducedLuminanceSpec(
                showsCurrentForce: false,
                showsPeakForce: false,
                showsPhaseCountdown: true,
                showsSide: true,
                stateWord: "Rest"
            )
        case .salvaging:
            return ForceReducedLuminanceSpec(
                showsCurrentForce: false,
                showsPeakForce: false,
                showsPhaseCountdown: false,
                showsSide: false,
                stateWord: "Saving"
            )
        case .finished:
            return ForceReducedLuminanceSpec(
                showsCurrentForce: false,
                showsPeakForce: false,
                showsPhaseCountdown: false,
                showsSide: false,
                stateWord: "Done"
            )
        }
    }

    /// A start haptic fires only when a transition *enters* measured work —
    /// never on a refresh that stays in the same measured state (which would
    /// re-cue a pull that has been running).  This is the dedupe guard for the
    /// "start" cue: repeated `update` calls with the same state must not replay
    /// it.
    public static func shouldStartHaptic(
        from oldState: ForceActivityState,
        to newState: ForceActivityState
    ) -> Bool {
        func isMeasuredWork(_ state: ForceActivityState) -> Bool {
            state == .measuring || state == .guidedWork
        }
        return isMeasuredWork(newState) && !isMeasuredWork(oldState)
    }

    /// Whether a boundary event warrants a confirmation haptic.  A dim pull
    /// needs an unambiguous acknowledgement for user-initiated outcomes; guided
    /// phase cues are handled by the guided runner itself and are not routed
    /// through this policy.
    public static func shouldAcknowledgeHaptic(for event: ForceHapticEvent) -> Bool {
        switch event {
        case .start, .stop, .save, .salvage, .failure, .finish:
            return true
        }
    }
}
