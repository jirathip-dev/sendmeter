import Foundation

/// #1004: the terminal outcome of one guided-launch attempt, decided at the
/// launch boundary and applied to the attempt's own lifecycle state.
///
/// Only `launched` leaves a session behind; every other case releases the
/// in-flight flag and (for a deadline) surfaces a retryable failure. There is
/// deliberately no case that leaves the flag set: "the flag cannot outlive the
/// attempt" is expressed as this closed set, not as a rule the view has to
/// remember at each `return`.
public enum GuidedLaunchOutcome: Equatable, Sendable {
    /// The session was constructed and is ready to present.
    case launched
    /// The awaited resolution did not settle inside the deadline. The work may
    /// still be running; the attempt itself is over.
    ///
    /// `loadFailureClass` is the account's most recent recorded launch/load
    /// failure class (#964), when one exists: the launch's own resolution has
    /// no error to report (it degrades to an empty plan), so the honest "why"
    /// is the load failure the account already recorded — the same class the
    /// banner and the Dashboard's failure row use.
    case timedOut(loadFailureClass: FriendlyErrorClass?)
    /// A newer attempt (or an account/selection change) took ownership while
    /// this one was awaiting. Nothing failed; nothing is shown.
    case superseded
}

/// Why a guided launch did not start, in the one shape the Force surface
/// renders.
public enum GuidedLaunchFailureReason: Equatable, Sendable {
    case deadlineExceeded(loadFailureClass: FriendlyErrorClass?)
}

/// #1004: the retryable failure state of the guided launch. `preset` is part
/// of the failure, so "a retry that re-runs it" re-runs *that* attempt rather
/// than whatever is currently selected.
public struct GuidedLaunchFailure: Equatable, Sendable {
    public let reason: GuidedLaunchFailureReason
    public let preset: TindeqPreset

    public init(reason: GuidedLaunchFailureReason, preset: TindeqPreset) {
        self.reason = reason
        self.preset = preset
    }

    /// The user-facing "why". A recorded load-failure class names its own
    /// family (and its own remedy); with no recorded class the deadline is
    /// named as the timeout it is.
    public var message: String {
        switch reason {
        case .deadlineExceeded(let loadFailureClass):
            return UserFacingError.message(for: loadFailureClass ?? .timeout)
        }
    }

    /// Always retryable: the failure releases the flag, so the retry is a
    /// fresh attempt with the same preset.
    public var isRetryable: Bool { true }
}

/// #1004: the launch attempt's own identity, and the only owner of the
/// in-flight flag.
///
/// The defect this replaces: `guidedLaunchInFlight` was a bare `Bool` set
/// before an unstructured `Task` and cleared on the branches that happened to
/// return, so a resolution that never settled (or a branch that forgot) left
/// the primary action locked for the life of the process. Here the flag is
/// owned by an attempt: `begin` starts one and returns its id, and the SINGLE
/// settlement entry point clears the flag for every outcome. A stale attempt's
/// late settlement is a no-op — it can neither clear a newer attempt's flag
/// nor resurrect its own.
public struct GuidedLaunchLifecycle: Equatable, Sendable {
    public private(set) var inFlight: Bool = false
    public private(set) var attemptID: UUID?
    public private(set) var failure: GuidedLaunchFailure?
    private var currentPreset: TindeqPreset?

    public init() {}

    /// Starts an attempt for `preset` and returns its id. A fresh attempt
    /// supersedes any previous failure notice (it is being retried right now).
    @discardableResult
    public mutating func begin(preset: TindeqPreset, attemptID: UUID = UUID()) -> UUID {
        self.attemptID = attemptID
        currentPreset = preset
        inFlight = true
        failure = nil
        return attemptID
    }

    /// Whether `attemptID` is the attempt that currently owns the flag.
    public func owns(_ attemptID: UUID) -> Bool {
        inFlight && self.attemptID == attemptID
    }

    /// Applies one attempt's terminal outcome.
    ///
    /// Every outcome releases the flag; only the owning attempt may settle.
    /// Returns `false` for a stale settlement.
    @discardableResult
    public mutating func settle(_ attemptID: UUID, outcome: GuidedLaunchOutcome) -> Bool {
        guard owns(attemptID) else { return false }
        inFlight = false
        self.attemptID = nil
        switch outcome {
        case .launched, .superseded:
            currentPreset = nil
        case .timedOut(let loadFailureClass):
            let preset = currentPreset
            currentPreset = nil
            if let preset {
                failure = GuidedLaunchFailure(
                    reason: .deadlineExceeded(loadFailureClass: loadFailureClass),
                    preset: preset
                )
            }
        }
        return true
    }

    /// The preset a retry must re-run, when a retryable failure is showing.
    public var retryPreset: TindeqPreset? { failure?.preset }
}

/// #1004: the inputs that decide the held-pull recovery controls.
///
/// `sessionActive` (the Force surface's `guidedSessionIsActive ||
/// guidedLaunchInFlight`) is carried as an input so the pin can prove it is
/// INERT: the deadlock was exactly this flag disabling Save and Discard while
/// `hasUnsavedRecording` disabled Start.
public struct ForceRecoveryControlsState: Equatable, Sendable {
    public let hasUnsavedRecording: Bool
    public let saving: Bool
    public let sessionActive: Bool
    /// The most recent save attempt for the currently held pull failed.
    public let saveFailed: Bool

    public init(
        hasUnsavedRecording: Bool,
        saving: Bool,
        sessionActive: Bool,
        saveFailed: Bool
    ) {
        self.hasUnsavedRecording = hasUnsavedRecording
        self.saving = saving
        self.sessionActive = sessionActive
        self.saveFailed = saveFailed
    }
}

/// What the held-pull recovery card offers, given the state above.
public struct ForceRecoveryControls: Equatable, Sendable {
    public let showsRecoveryCard: Bool
    public let canSave: Bool
    public let canDiscard: Bool
    /// A failed save must fall back to offering discard — visibly, not only
    /// by leaving the button enabled.
    public let offersDiscardFallback: Bool

    public init(
        showsRecoveryCard: Bool,
        canSave: Bool,
        canDiscard: Bool,
        offersDiscardFallback: Bool
    ) {
        self.showsRecoveryCard = showsRecoveryCard
        self.canSave = canSave
        self.canDiscard = canDiscard
        self.offersDiscardFallback = offersDiscardFallback
    }

    /// The one invariant the Force surface must never break: while a pull is
    /// held and no save is in flight, at least one recovery action is
    /// available. ("Exactly one working action" — both are legitimately
    /// offered; the forbidden state is neither.)
    public var hasWorkingRecoveryAction: Bool { canSave || canDiscard }
}

public enum ForceRecoveryActionPolicy {
    /// The held pull is the ONLY input that may gate its own recovery.
    ///
    /// The pre-#1004 rule was `savingSummary || guidedSessionActive` on all
    /// four buttons while `hasUnsavedRecording` disabled Start, so a session
    /// (or an in-flight launch) re-established on top of a held pull disabled
    /// both sides and explained neither. A held pull must always be
    /// settleable.
    public static func controls(state: ForceRecoveryControlsState) -> ForceRecoveryControls {
        let canAct = state.hasUnsavedRecording && !state.saving
        return ForceRecoveryControls(
            showsRecoveryCard: state.hasUnsavedRecording,
            canSave: canAct,
            canDiscard: canAct,
            offersDiscardFallback: canAct && state.saveFailed
        )
    }

    /// The explicit fallback after a failed save. The pull is still held (a
    /// failed save leaves the summary with the device), so the honest next
    /// step is the user's: discard it, knowing it is not in the durable queue.
    public static let discardFallbackNotice =
        "This pull still isn\u{2019}t in the durable queue. Discard it below if you don\u{2019}t need it \u{2014} it can\u{2019}t be recovered after that."

    /// The retry affordance's title for the guided-launch failure row.
    public static let guidedLaunchRetryTitle = "Try Again"
}
