import Foundation

// MARK: - Manual-workout lifecycle ownership (#936)

/// #936: what one lifecycle command decided.
public enum ManualWorkoutLifecycleDecision: Equatable, Sendable {
    /// The owner's workout state moved: start, resume, minimize, an attempt
    /// transition, an RPE change, a lock-screen replay, a rest-target change or
    /// an account teardown.
    case changed
    /// End accepted. The caller must persist this draft **exactly once** and
    /// report the matching `ticket` back through `saveDidComplete(ticket:)`.
    case persist(draft: WorkoutDraft, ticket: UUID)
    /// End refused: the workout is untouched and still armed, and `message` is
    /// the explanation the presentation shows (#926).
    case refused(message: String)
    /// A duplicate, stale or out-of-lifecycle command. Nothing changed.
    case ignored
}

/// #936: the effects the lifecycle owner asks the app to perform, in the order
/// it must perform them.
///
/// The owner performs none of them itself. The live card (ActivityKit) and the
/// rest deadline (UserNotifications) are app-target adapters, so this list is a
/// value: a deterministic test records it, and the app applies it. The one
/// durable effect — the finish's save — is a decision, not an effect, because
/// it must run through the caller's existing save path (the #935 recovery owner
/// and the app's ONE pending-writes queue) rather than a second one.
public enum ManualWorkoutLifecycleEffect: Equatable, Sendable {
    /// Keep the lock-screen card on this workout (`nil` ends the card).
    case syncActivity(workout: PhoneWorkoutEngine?, restTarget: Int)
    /// Keep the rest deadline — and its local notification — on this workout
    /// (`nil` stops it).
    case syncRest(workout: PhoneWorkoutEngine?, restTarget: Int)
    /// Discard the queued lock-screen actions that belong to the workout being
    /// torn down. Their identity is that workout's `startedAt`, which is what
    /// keeps a stale action from replaying into the next one.
    case discardActivityEvents
    /// The one user-initiated start asks for notification authorization once.
    /// Resume and minimize never ask again.
    case requestRestNotificationPermission
}

public struct ManualWorkoutLifecycleOutcome: Equatable, Sendable {
    public let decision: ManualWorkoutLifecycleDecision
    public let effects: [ManualWorkoutLifecycleEffect]

    public init(
        decision: ManualWorkoutLifecycleDecision,
        effects: [ManualWorkoutLifecycleEffect]
    ) {
        self.decision = decision
        self.effects = effects
    }

    /// Nothing changed and nothing must be done.
    public static let ignored = ManualWorkoutLifecycleOutcome(decision: .ignored, effects: [])
}

/// #936: the ONE owner of the manual-workout lifecycle — start, minimize,
/// resume, the attempt transitions, End and the save it triggers, plus the
/// rest/live-card effects that follow it and the account boundary that tears it
/// down.
///
/// It holds the in-progress workout itself. That is what makes view recreation
/// safe: the workout lives on the app-level owner, so a recreated `WorkoutView`
/// reads the workout that is already running instead of recreating one or
/// dropping it, and a start while one is in progress (or while the previous
/// finish is still saving) is `ignored`.
///
/// It performs no I/O and reads no ambient clock: every entry point takes its
/// instant (`at date:`), the rest target is an injected value, the effects are
/// returned for the app to apply, and the finish's save is handed to the caller
/// with a ticket. Nothing here imports HealthKit, Bluetooth or SwiftUI.
public struct ManualWorkoutLifecycleCoordinator: Sendable {
    /// The in-progress workout. `nil` means none is in progress.
    public private(set) var workout: PhoneWorkoutEngine?
    /// #926: the refused-End explanation the owner currently holds. It is
    /// cleared whenever the workout moves on, is minimized/resumed, or ends, so
    /// an obsolete explanation can never outlive the state that produced it.
    public private(set) var refusalMessage: String?
    /// The resolved rest target every rest/live-card effect follows.
    public private(set) var restTarget: Int

    private var inFlightSave: InFlightSave?

    /// The finish whose save the caller is still running. Its account is kept
    /// so an account boundary can tell whose save it is about to release.
    private struct InFlightSave: Equatable, Sendable {
        let ticket: UUID
        let accountUserID: UUID
    }

    public init(restTarget: Int = ManualWorkoutRest.defaultRestTarget) {
        self.restTarget = ManualWorkoutRest.validatedTarget(restTarget)
    }

    /// The workout's identity for the lock-screen action queue and the live
    /// card: a recreated view resumes THIS workout and never a new one.
    public var workoutStartedAt: Date? { workout?.draft.startedAt }

    /// A finish is being persisted. The End control is disabled while this is
    /// true, and a repeated End is ignored rather than saved twice.
    public var isSaving: Bool { inFlightSave != nil }

    // MARK: Start / minimize / resume

    /// Start a fresh manual workout for `accountUserID`.
    ///
    /// Ignored while a workout is already in progress or while the previous
    /// finish is still saving — recreation must never replace a running workout.
    /// The notification-permission ask is part of the user-initiated start; a
    /// harness that cannot show a system prompt passes `false`.
    public mutating func start(
        accountUserID: UUID,
        phase: PhaseID,
        at date: Date,
        asksForRestNotificationPermission: Bool = true
    ) -> ManualWorkoutLifecycleOutcome {
        guard workout == nil, !isSaving else { return .ignored }
        let engine = PhoneWorkoutEngine(
            accountUserID: accountUserID,
            phase: phase,
            startedAt: date
        )
        workout = engine
        refusalMessage = nil
        var effects = syncEffects(engine)
        if asksForRestNotificationPermission {
            effects.append(.requestRestNotificationPermission)
        }
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: effects)
    }

    /// The workout surface (re)appeared — the tab, or the full-screen cover.
    /// It resumes whatever workout the owner holds: it never creates one and
    /// never terminates one.
    public mutating func resume() -> ManualWorkoutLifecycleOutcome {
        guard let workout else { return .ignored }
        refusalMessage = nil
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: syncEffects(workout))
    }

    /// The presentation goes away. The workout — and the rest/live-card effects
    /// already following it — stay exactly as they are; only the explanation
    /// that belonged to the presentation is dropped.
    public mutating func minimize() -> ManualWorkoutLifecycleOutcome {
        guard workout != nil else { return .ignored }
        refusalMessage = nil
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: [])
    }

    // MARK: Attempts and draft edits

    /// The boulder control. The engine's own guards refuse an invalid
    /// transition (no attempt running, already running, an end before the
    /// start) and the workout is left exactly as it was when they do.
    @discardableResult
    public mutating func toggleAttempt(at date: Date) throws -> ManualWorkoutLifecycleOutcome {
        guard var engine = workout else { return .ignored }
        if engine.attemptStartedAt == nil {
            try engine.startAttempt(at: date)
        } else {
            _ = try engine.endAttempt(at: date)
        }
        workout = engine
        refusalMessage = nil
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: syncEffects(engine))
    }

    /// Session RPE is part of the draft the finish persists. It is not part of
    /// the live card's or the rest deadline's contract, so it carries no
    /// effects.
    public mutating func setRPE(_ rpe: Double) -> ManualWorkoutLifecycleOutcome {
        guard var engine = workout else { return .ignored }
        engine.setRPE(rpe)
        workout = engine
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: [])
    }

    /// The user's rest-target preference moved. The rest deadline and the live
    /// card follow the new target from here on.
    public mutating func setRestTarget(_ target: Int) -> ManualWorkoutLifecycleOutcome {
        let validated = ManualWorkoutRest.validatedTarget(target)
        guard validated != restTarget else { return .ignored }
        restTarget = validated
        guard let workout else {
            return ManualWorkoutLifecycleOutcome(decision: .changed, effects: [])
        }
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: syncEffects(workout))
    }

    /// Replay the lock-screen intents the app drained for this workout.
    /// Delivery is at-least-once, so an already-applied or stale event is a
    /// no-op; the identity check keeps an event from a previous workout out of
    /// this one even if the adapter ever handed one over.
    public mutating func applyActivityEvents(
        _ events: [ManualWorkoutActivityEvent]
    ) -> ManualWorkoutLifecycleOutcome {
        guard let engine = workout, !events.isEmpty else { return .ignored }
        let current = ManualWorkoutActivityReplay.applying(
            ManualWorkoutActivityDrain.matching(
                events,
                workoutStartedAt: engine.draft.startedAt
            ),
            to: engine
        )
        guard current != engine else { return .ignored }
        workout = current
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: syncEffects(current))
    }

    // MARK: End and the save it triggers

    /// The End control.
    ///
    /// An End with no completed attempt is refused: the workout stays armed and
    /// the outcome carries the #926 explanation. An accepted End clears the
    /// workout and hands over **one** draft with a fresh ticket; every later End
    /// — a repeat tap, a re-created view, a second presentation — finds nothing
    /// left to finish and is ignored, so the workout can be persisted only once.
    public mutating func end(at date: Date) -> ManualWorkoutLifecycleOutcome {
        guard var engine = workout, !isSaving else { return .ignored }
        do {
            let draft = try engine.finish(at: date)
            workout = nil
            refusalMessage = nil
            let ticket = UUID()
            inFlightSave = InFlightSave(
                ticket: ticket,
                accountUserID: draft.accountUserID
            )
            return ManualWorkoutLifecycleOutcome(
                decision: .persist(draft: draft, ticket: ticket),
                effects: teardownEffects()
            )
        } catch {
            let message = UserFacingError.message(for: error)
            refusalMessage = message
            return ManualWorkoutLifecycleOutcome(
                decision: .refused(message: message),
                effects: []
            )
        }
    }

    /// The caller's save for `ticket` finished, either way. Only the ticket that
    /// is actually in flight releases the latch: a late or stale completion can
    /// never release a newer finish's save.
    public mutating func saveDidComplete(ticket: UUID) -> ManualWorkoutLifecycleOutcome {
        guard inFlightSave?.ticket == ticket else { return .ignored }
        inFlightSave = nil
        return ManualWorkoutLifecycleOutcome(decision: .changed, effects: [])
    }

    // MARK: Account boundary

    /// The account boundary (#933/#934/#935 era): the workout this owner holds
    /// is torn down **under the account that owned it**, together with the live
    /// card and the queued lock-screen actions that carry its identity.
    ///
    /// `previousAccountUserID` is the account that is going away, or `nil` when
    /// the model has already cleared its session and no account is left to
    /// protect. A boundary that names a DIFFERENT account leaves this workout
    /// alone — a stale boundary must never take out a workout that already
    /// belongs to the incoming account. A completion that arrives after the
    /// teardown is a no-op because its ticket is no longer in flight.
    public mutating func accountChanged(
        previousAccountUserID: UUID?
    ) -> ManualWorkoutLifecycleOutcome {
        guard workout != nil || inFlightSave != nil else { return .ignored }
        if let previousAccountUserID {
            let owner = workout?.draft.accountUserID ?? inFlightSave?.accountUserID
            guard owner == previousAccountUserID else { return .ignored }
        }
        workout = nil
        refusalMessage = nil
        inFlightSave = nil
        return ManualWorkoutLifecycleOutcome(
            decision: .changed,
            effects: teardownEffects()
        )
    }

    // MARK: Effect construction

    /// Every transition that follows (or stops following) a workout emits the
    /// same pair, in the same order: the card first, then the rest deadline.
    private func syncEffects(
        _ workout: PhoneWorkoutEngine?
    ) -> [ManualWorkoutLifecycleEffect] {
        [
            .syncActivity(workout: workout, restTarget: restTarget),
            .syncRest(workout: workout, restTarget: restTarget),
        ]
    }

    /// The terminal effects: the card goes away, the queued lock-screen actions
    /// for that workout go with it, and the rest deadline stops. A `nil`-workout
    /// sync is the adapters' own end/stop path.
    private func teardownEffects() -> [ManualWorkoutLifecycleEffect] {
        [
            .syncActivity(workout: nil, restTarget: restTarget),
            .discardActivityEvents,
            .syncRest(workout: nil, restTarget: restTarget),
        ]
    }
}
