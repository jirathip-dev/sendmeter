import Foundation

/// #916: how one "direct write" entity is mutated on the server.
///
/// The direct-write entities are the ones whose optimistic writes were never
/// replayed after process death (`CachedWorkspace.directWriteEntityTypes`).
/// Presets and routines are the first slice; the envelope below is the shared
/// shape the later slices adopt, so the operation vocabulary lives here rather
/// than in `AppModel`.
public enum DirectWriteOperation: String, Codable, CaseIterable, Sendable, Equatable {
    case create
    case update
    case delete
}

/// The parts of a direct-write entity value a replay needs.
///
/// The row identity and the mutation content are compared separately on
/// purpose: `tindeq_presets` and `routine_presets` mint their own `id`
/// (`default gen_random_uuid()`) and the insert payload does not carry one, so
/// a replayed create can never be matched to the row it may already have
/// created by identity — only by content.
public protocol DirectWriteEntityValue {
    /// The row identity the server can be asked about.
    var directWriteID: UUID { get }

    /// Whether this value carries the same mutation as `other`: every field
    /// the server round-trips, excluding the row identity.
    func hasSameMutationContent(as other: Self) -> Bool
}

/// One immutable intended mutation for one entity, as persisted by
/// `DurableQueue`.
///
/// The account scope and the queue identity belong to the owning
/// `DurableQueueItem` (`accountUserID`, and — for these entities — an item id
/// derived from `entityID`), so an envelope can never be replayed under
/// another account. The envelope itself is append-only: `mutation` is captured
/// before the first server attempt and is never re-derived from later state,
/// which is what makes a replay provably the user's intended operation.
public struct DirectWriteIntent<Mutation: Codable & Sendable>: Codable, Sendable, Equatable
where Mutation: Equatable {
    /// The local cache entity id (`CacheEntityID.preset(_:)` /
    /// `CacheEntityID.routine(_:)`) this intent targets.
    public let entityID: String
    public let operation: DirectWriteOperation
    /// The intended row for `create`/`update`; for `delete` the pre-delete row
    /// when it was known (recovery evidence — a delete never re-sends it, but
    /// a landed create with a server-minted id is found through it).
    public let mutation: Mutation?
    /// Stable identity of THIS operation, independent of the queue item's
    /// replacement revision. A completed delete's terminal marker records it so
    /// a stale write can be told apart from a later re-creation.
    public let operationID: UUID
    public let intendedAt: Date

    public init(
        entityID: String,
        operation: DirectWriteOperation,
        mutation: Mutation?,
        operationID: UUID = UUID(),
        intendedAt: Date = Date()
    ) {
        self.entityID = entityID
        self.operation = operation
        self.mutation = mutation
        self.operationID = operationID
        self.intendedAt = intendedAt
    }

    /// The same operation identity and content, re-labelled with a coalesced
    /// operation. Used when a newer mutation for the same entity replaces a
    /// still-pending intent (see `DirectWriteReplayPolicy.coalesce`).
    public func replacingOperation(_ operation: DirectWriteOperation) -> DirectWriteIntent {
        DirectWriteIntent(
            entityID: entityID,
            operation: operation,
            mutation: mutation,
            operationID: operationID,
            intendedAt: intendedAt
        )
    }
}

/// The replay decisions for a durable direct-write intent (#916). Pure: every
/// input is passed in, so the rules are unit-testable without a server.
public enum DirectWriteReplayPolicy {
    /// The active server row that already carries this intended mutation.
    ///
    /// A `create` is the only operation neither table can make idempotent by
    /// identity (see `DirectWriteEntityValue`), so a request whose
    /// acknowledgement was lost must be recognised from the authoritative list
    /// before it is re-sent. An active row with the same mutation content IS
    /// that lost acknowledgement: adopting it both avoids the duplicate row and
    /// removes the guesswork about which id the server minted.
    public static func alreadyApplied<Value: DirectWriteEntityValue>(
        intended: Value,
        serverValues: [Value]
    ) -> Value? {
        serverValues.first { $0.hasSameMutationContent(as: intended) }
    }

    /// The operation one entity's single durable intent must carry after a
    /// newer mutation arrives while an older one is still pending.
    ///
    /// Returning `nil` means the incoming mutation must not be persisted at
    /// all: the entity's removal is already the latest word, and replaying the
    /// write would resurrect an entity the user deleted.
    public static func coalesce(
        pending: DirectWriteOperation,
        incoming: DirectWriteOperation
    ) -> DirectWriteOperation? {
        switch (pending, incoming) {
        case (_, .delete):
            // The delete always wins: it is the user's newest word for this
            // entity, and the replay resolves it against the server (adopting
            // a row a landed create minted) before removing anything.
            return .delete
        case (.delete, _):
            // A write arriving after that entity's delete must never
            // re-create it. (The UI removes a pending delete from its list, so
            // this is a race, not a product path.)
            return nil
        case (.create, .update):
            // The row has not reached the server yet: an `update` would PATCH
            // nothing, so the intent stays a create — with the newer content.
            return .create
        case (.update, .create):
            // A create for an entity that already has a pending update cannot
            // insert a second row under the same identity; the newest content
            // stays an update.
            return .update
        case (.create, .create), (.update, .update):
            return incoming
        }
    }

    /// The provable operation for a pending cache-only direct-write row that
    /// predates the replay envelope (#916 AC4).
    ///
    /// The row itself is the evidence, and neither branch guesses: a tombstone
    /// is a local delete the server never confirmed; a live row the server still
    /// has under the same id is an update; anything else is a create whose
    /// content is checked against the authoritative list before it is sent (so
    /// a create that did land with a server-minted id is adopted, not repeated).
    public static func legacyOperation(
        isTombstoned: Bool,
        serverHasEntity: Bool
    ) -> DirectWriteOperation {
        if isTombstoned { return .delete }
        return serverHasEntity ? .update : .create
    }
}

/// A direct-write intent that cannot be replayed at all.
///
/// Only reachable from a queue file whose envelope lost its intended mutation
/// (the write paths always persist one). It is classified `permanent` so the
/// existing quarantine keeps it recoverable instead of retrying a payload that
/// can never succeed.
public enum DirectWriteReplayError: Error, Equatable, Sendable {
    case missingIntendedMutation
}

extension DirectWriteReplayError: ServerRejectionClassifying {
    /// A payload problem, never an environment one: the intent's own content is
    /// what is missing, so retrying cannot fix it and the bounded
    /// permanent-attempt budget applies.
    public var rejectionClass: RejectionClass { .permanent }
}

// MARK: - Phase transitions and settings (#917)

/// #917: the durable intent of one training-block (phase) transition.
///
/// A phase transition is not one row: the planner's mutations touch several
/// `phase_periods` rows AND the `user_settings` row that has to keep pointing
/// at the canonical open period. Persisting the pieces as independent intents
/// would make process death *between* them observable, so the whole transition
/// is ONE account-scoped intent whose replay converges the server state to the
/// intended end state.
///
/// The intent is accounted for exactly like the preset/routine envelope: the
/// entity identity (the queue item id), the immutable target/date, the state
/// the plan was authored against, and the settings row the transition has to
/// end in — all captured before the first server attempt and never re-derived
/// from later local state.
public struct PhaseTransitionIntent: Codable, Sendable, Equatable {
    /// The queue identity of the account's single pending transition.
    ///
    /// A phase transition is a singleton in the same sense the settings row
    /// is: an account can only have one open block, so the queue keeps ONE
    /// intent per account and a newer switch replaces the pending one. That is
    /// also the only reconcilable shape — a superseded transition's local
    /// preview period id is never visible on the server, so a plan authored
    /// against it can only be re-anchored, not replayed as a second item.
    public static let queueItemID = UUID(uuidString: "91700000-0000-4000-8000-000000000917")!

    /// The block the user selected.
    public let targetPhase: PhaseID
    /// The date the transition was intended on, captured once. A replay weeks
    /// later must reproduce the SAME transition: re-planning against a new
    /// "today" would create a second, differently-dated period instead of
    /// completing the user's own switch.
    public let intendedToday: String
    /// The periods the plan was authored against (the authoritative local view
    /// at intent time). The replay re-plans from this state only while it still
    /// matches the server's rows (see `planInput`): a same-day switch-back's
    /// `delete` + `reopen` is exactly the case where the server's post-partial
    /// state no longer shows what was intended.
    public let previousPeriods: [PhasePeriod]
    /// The settings row the transition intends: the phase and start date of its
    /// open period. This is the completeness the transition's two halves have
    /// to agree on — a replay that lands the periods but leaves the settings
    /// row stale (or the reverse) has not finished the transition.
    public let settings: UserSettings
    /// Stable identity of THIS operation, independent of the queue item's
    /// replacement revision.
    public let operationID: UUID
    public let intendedAt: Date

    public init(
        targetPhase: PhaseID,
        intendedToday: String,
        previousPeriods: [PhasePeriod],
        settings: UserSettings,
        operationID: UUID = UUID(),
        intendedAt: Date = Date()
    ) {
        self.targetPhase = targetPhase
        self.intendedToday = intendedToday
        self.previousPeriods = previousPeriods
        self.settings = settings
        self.operationID = operationID
        self.intendedAt = intendedAt
    }

    /// The open period a completed transition leaves behind: the block the user
    /// selected, started on the date the settings row records.
    public var intendedOpenPeriod: (phase: PhaseID, startedOn: String) {
        (settings.currentPhase, settings.phaseStartDate)
    }
}

/// The pure replay decisions for a phase transition (#917).
///
/// Every input is passed in, so the rules are unit-testable without a server —
/// and the tests that matter run them against a REAL `AppModel` (see
/// `PhaseTransitionReplayAppTests`).
public enum PhaseTransitionReplayPolicy {
    /// The open periods in an authoritative list.
    public static func openPeriods(_ periods: [PhasePeriod]) -> [PhasePeriod] {
        periods.filter { $0.endedOn == nil }
    }

    /// The transition's plan as authored against `periods`.
    public static func plan(
        for intent: PhaseTransitionIntent,
        periods: [PhasePeriod]
    ) -> PhaseTransitionPlan {
        PhaseTransitionPlanner.plan(
            periods: periods,
            newPhase: intent.targetPhase,
            today: intent.intendedToday
        )
    }

    /// Whether the server's own state already IS the intended end state:
    /// exactly one open period, with the intended phase and start date.
    ///
    /// This is the guard that keeps a replay from inserting a SECOND period
    /// after a create that landed — the insert mints its own row id, so the
    /// server's answer (not the local row) is the only proof that the request
    /// already succeeded. It is deliberately strict about "exactly one": a
    /// server state with two open periods is not the intended one, and the
    /// replay must report the transition as incomplete rather than confirm it.
    public static func isApplied(
        intent: PhaseTransitionIntent,
        serverPeriods: [PhasePeriod]
    ) -> Bool {
        let open = openPeriods(serverPeriods)
        guard open.count == 1, let period = open.first else { return false }
        return period.phase == intent.settings.currentPhase
            && period.startedOn == intent.settings.phaseStartDate
    }

    /// Whether the intent's own view of the world still describes the server's
    /// rows, so the plan can be re-derived from it.
    ///
    /// The mutations that PATCH an existing period must still find that period
    /// on the server — otherwise the intent was authored against a local
    /// preview the server never minted (a superseded transition), and its plan
    /// would silently no-op while its settings write went through. A `delete`
    /// is allowed to find nothing (an already-applied soft delete is exactly
    /// that), and the server must not carry an open period the plan does not
    /// know about: that is another writer's block, not ours to close.
    public static func isServerAnchored(
        intent: PhaseTransitionIntent,
        serverPeriods: [PhasePeriod]
    ) -> Bool {
        let serverIDs = Set(serverPeriods.map(\.id))
        for mutation in plan(for: intent, periods: intent.previousPeriods).mutations {
            switch mutation {
            case .create, .updateSettings:
                continue
            case let .delete(periodID):
                _ = periodID
                continue
            case let .updatePhase(periodID, _), let .close(periodID, _), let .reopen(periodID):
                guard serverIDs.contains(periodID) else { return false }
            }
        }
        let plannedOpen = openPeriods(intent.previousPeriods).first
        let serverOpen = openPeriods(serverPeriods)
        // More than one open period is not a state a plan can be authored
        // against: the replay must re-anchor on the server's own rows.
        guard serverOpen.count <= 1 else { return false }
        if let serverOpen = serverOpen.first, serverOpen.id != plannedOpen?.id { return false }
        return true
    }

    /// The period list a replay must plan from.
    ///
    /// The intent's own pre-state is preferred (it is the only input that
    /// reproduces a same-day switch-back's `delete` + `reopen` once the delete
    /// has landed), and the server's authoritative rows are used when the
    /// intent's view is no longer server-anchored.
    public static func planInput(
        intent: PhaseTransitionIntent,
        serverPeriods: [PhasePeriod]
    ) -> [PhasePeriod] {
        isServerAnchored(intent: intent, serverPeriods: serverPeriods)
            ? intent.previousPeriods
            : serverPeriods
    }

    /// Whether a replayed transition ended where the intent said: exactly one
    /// open period, the intended block, started on the intended date.
    ///
    /// A partially-applied transition that this check rejects keeps its durable
    /// intent and stays retryable (and is surfaced as unsynced when the bounded
    /// attempts run out) — it is never confirmed as if it had completed.
    public static func isComplete(
        intent: PhaseTransitionIntent,
        resultPeriods: [PhasePeriod]
    ) -> Bool {
        isApplied(intent: intent, serverPeriods: resultPeriods)
    }
}

/// A phase transition whose replay could not reach the intended end state.
///
/// Only thrown after the transition's own writes ran and the authoritative
/// answer still does not show the intended open block. Classified `retryable`:
/// the next attempt re-reads the server state, and a state that can never
/// converge (a block another writer moved on) reaches the bounded quarantine —
/// visible, retryable, never silently cleared.
public enum PhaseTransitionReplayError: Error, Equatable, Sendable {
    case incompleteTransition
}

extension PhaseTransitionReplayError: ServerRejectionClassifying {
    public var rejectionClass: RejectionClass { .retryable }
}

// MARK: - Presets

extension TindeqPreset: DirectWriteEntityValue {
    public var directWriteID: UUID { id }

    /// Compares the fields `PresetPayload` sends and `PresetRow` round-trips.
    /// `zoneQuality`/`zoneIntensityPercent` are transient (never persisted, see
    /// `TindeqPreset`), and `id` is excluded because the server mints its own.
    public func hasSameMutationContent(as other: TindeqPreset) -> Bool {
        name == other.name
            && holdSeconds == other.holdSeconds
            && holdSecondsBySet == other.holdSecondsBySet
            && repetitions == other.repetitions
            && sets == other.sets
            && restBetweenRepetitionsSeconds == other.restBetweenRepetitionsSeconds
            && restBetweenSetsSeconds == other.restBetweenSetsSeconds
            && targetKilograms == other.targetKilograms
            && targetPercentage == other.targetPercentage
            && percentageBasis == other.percentageBasis
            && percentageStep == other.percentageStep
            && targetFromCurve == other.targetFromCurve
            && alternateSides == other.alternateSides
            && protocolMode == other.protocolMode
            && cadenceOutSeconds == other.cadenceOutSeconds
            && cadenceReturnSeconds == other.cadenceReturnSeconds
            && toleranceMode == other.toleranceMode
            && toleranceValue == other.toleranceValue
            && prepareSeconds == other.prepareSeconds
            && setupNote == other.setupNote
            && capacityEvidence == other.capacityEvidence
    }
}

// MARK: - Routines

extension RoutineStep {
    /// The shared routine JSON schema deliberately does not persist a step id
    /// (`RoutineStep.id` is local SwiftUI identity only), so two steps are the
    /// same mutation when their stored fields match.
    public func hasSameMutationContent(as other: RoutineStep) -> Bool {
        label == other.label
            && detail == other.detail
            && seconds == other.seconds
            && repetitions == other.repetitions
            && restSeconds == other.restSeconds
    }
}

extension RoutinePreset: DirectWriteEntityValue {
    public var directWriteID: UUID { id }

    /// Mirrors `RoutinePayload`: the insert caps the name at 80 characters —
    /// the comparison does too, otherwise a longer local name would never match
    /// its own round-tripped row — and a step is compared by its stored fields,
    /// never by its local-only `id`.
    public func hasSameMutationContent(as other: RoutinePreset) -> Bool {
        String(name.prefix(80)) == String(other.name.prefix(80))
            && steps.count == other.steps.count
            && zip(steps, other.steps).allSatisfy { $0.hasSameMutationContent(as: $1) }
    }
}
