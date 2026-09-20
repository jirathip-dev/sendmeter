import CryptoKit
import Foundation
import SendLogHealthCore
import SendLogWatchCore

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

// MARK: - Tag registry (#918)

/// #918: the queue identity of one tag name.
///
/// The tag registry's identity is the tag NAME — denormalized into
/// `tindeq_recordings.tag` and used as `CacheEntityID.tagMetadata` — while the
/// durable queue keys its items by `UUID`. The two have to map deterministically
/// for the queue to hold ONE intent per tag: a relaunch (or a second mutation
/// for the same tag) recovers the pending item from the name alone, and a rename
/// that is still pending is replaced under the identity it continues instead of
/// racing it.
///
/// The mapping is RFC 4122 §4.3 UUIDv5 over the trimmed name under this
/// namespace, so it is stable for every process and every future build.
public enum TagMutationIdentity {
    // SAFETY: fixed canonical 32-hex UUID string; UUID(uuidString:) always
    // parses it.
    public static let namespace = UUID(uuidString: "91800000-0000-4000-8000-000000000918")!

    private static let namespaceBytes: [UInt8] = {
        var uuid = namespace.uuid
        return withUnsafeBytes(of: &uuid) { Array($0) }
    }()

    public static func queueItemID(for tagName: String) -> UUID {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = namespaceBytes
        bytes.append(contentsOf: Array(trimmed.utf8))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// #918: the durable intent of one tag-registry mutation (rename / hide /
/// unhide).
///
/// The registry row's identity is the tag NAME (`CacheEntityID.tagMetadata`),
/// and a rename MOVES that identity: `rename_tindeq_tag` repoints every
/// recording carrying the old name and drops the old row, and it only carries a
/// registry row across when the old name had one. An intent that is still
/// pending has to keep both halves of that move:
///
/// * every name its recordings may still be served under, so a replay repoints
///   from the name the server actually has (a rename whose acknowledgement was
///   lost leaves the recordings under the older name), and
/// * the rename itself, so a later mutation authored against the moved name
///   still repoints the recordings the user renamed in the first place.
public struct TagMutationIntent: Codable, Sendable, Equatable {
    /// The names this tag has been known by while this intent was pending,
    /// oldest first. The last one is the name the user sees (and authors a
    /// later mutation against).
    public let knownNames: [String]
    /// The name the tag must end up carrying, or `nil` for a visibility-only
    /// mutation.
    public let renamedTo: String?
    /// The visibility the mutation intends. `false` is a real value (unhide);
    /// `nil` means the mutation does not touch it.
    public let hidden: Bool?
    /// The recordings that carried the tag when the mutation was authored. The
    /// replay proves the end state against them: a rename that would leave one
    /// of the user's references behind is never confirmed — the intent stays
    /// durable and retryable instead.
    public let recordingIDs: [UUID]
    /// Stable identity of THIS operation, independent of the queue item's
    /// replacement revision. A replacement keeps the identity of the operation
    /// that first persisted it, so a completed replay can never be confused
    /// with a newer one.
    public let operationID: UUID
    public let intendedAt: Date

    public init(
        knownNames: [String],
        renamedTo: String? = nil,
        hidden: Bool? = nil,
        recordingIDs: [UUID] = [],
        operationID: UUID = UUID(),
        intendedAt: Date = Date()
    ) {
        self.knownNames = knownNames
        self.renamedTo = renamedTo
        self.hidden = hidden
        self.recordingIDs = recordingIDs
        self.operationID = operationID
        self.intendedAt = intendedAt
    }

    /// The name the tag currently carries — the one a user-facing mutation is
    /// authored against, and the one the queue item is looked up by.
    public var tagName: String { knownNames.last ?? "" }

    /// The name the intent must leave the tag under.
    public var finalName: String { renamedTo ?? tagName }

    /// The name the tag started this intent's chain under. The queue identity is
    /// derived from this name, so a chained rename replaces the still-pending
    /// intent it continues rather than filing a second one.
    public var originName: String { knownNames.first ?? "" }

    /// The queue item identity this intent must be filed under.
    public var queueIdentity: UUID { TagMutationIdentity.queueItemID(for: originName) }

    /// The names this intent's rename retires (everything but the final name).
    public var retiredNames: Set<String> {
        guard renamedTo != nil else { return [] }
        return Set(knownNames).subtracting([finalName])
    }
}

/// The replay decisions for a tag mutation (#918). Pure: every input is passed
/// in, so the rules are unit-testable without a server.
public enum TagMutationReplayPolicy {
    /// Whether the server's own state already IS the intended end state.
    ///
    /// This is the single guard that keeps a retry from either duplicating work
    /// or claiming a mutation it did not perform. Every clause is read off the
    /// server's answer, never off local state:
    ///
    /// * every recording the user saw under an older name carries the intended
    ///   name (or is gone from the server — a removal is a later word than this
    ///   rename), so no reference is left behind;
    /// * a rename has retired every other name it knows about, because the DB
    ///   function drops the old registry row and a still-present row means the
    ///   rename did not run;
    /// * a visibility mutation has a row carrying exactly the intended flag.
    public static func isComplete(
        intent: TagMutationIntent,
        serverTags: [TagMetadata],
        serverRecordings: [TindeqRecording]
    ) -> Bool {
        let finalName = intent.finalName
        for id in intent.recordingIDs {
            guard let recording = serverRecordings.first(where: { $0.id == id }) else {
                continue
            }
            guard recording.tag.trimmingCharacters(in: .whitespacesAndNewlines) == finalName
            else { return false }
        }
        guard !intent.retiredNames.contains(where: { name in
            serverTags.contains { $0.name == name }
        }) else { return false }
        if let hidden = intent.hidden {
            guard let row = serverTags.first(where: { $0.name == finalName }) else {
                return false
            }
            guard row.hidden == hidden else { return false }
        }
        return true
    }

    /// The same question as `isComplete`: a replayed intent is only allowed to
    /// confirm what the authoritative state already shows.
    public static func isApplied(
        intent: TagMutationIntent,
        serverTags: [TagMetadata],
        serverRecordings: [TindeqRecording]
    ) -> Bool {
        isComplete(
            intent: intent,
            serverTags: serverTags,
            serverRecordings: serverRecordings
        )
    }

    /// The name a replayed rename has to repoint FROM, or `nil` when there is
    /// nothing left to repoint.
    ///
    /// A rename that landed leaves the recordings under the newer name and a
    /// lost acknowledgement leaves them under the older one, so the source is
    /// read off the server's recordings first (the references are what must not
    /// be lost) and off its registry rows second (a tag can keep a row after its
    /// last recording is gone). The intended name itself is never a source: a
    /// rename away from the name the records already carry is nothing to send
    /// (`rename_tindeq_tag` returns early for `new_name = old_name`).
    public static func repointSource(
        intent: TagMutationIntent,
        serverTags: [TagMetadata],
        serverRecordings: [TindeqRecording]
    ) -> String? {
        guard let finalName = intent.renamedTo else { return nil }
        let sources = intent.knownNames.filter { $0 != finalName }
        for name in sources where serverRecordings.contains(where: { recording in
            intent.recordingIDs.contains(recording.id)
                && recording.tag.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }) {
            return name
        }
        for name in sources where serverTags.contains(where: { $0.name == name }) {
            return name
        }
        return nil
    }

    /// The intent a newer mutation for the same tag must persist in place of the
    /// still-pending one.
    ///
    /// The pending intent's identity is preserved: its name chain (so the replay
    /// can repoint from whichever name the server still serves) and the rename
    /// it already carries (a rename moves the identity, and every later mutation
    /// is authored against the moved name — dropping it would leave the
    /// recordings under the old name for ever). The NEWEST mutation contributes
    /// what it is about: its own name (appended to the chain when it differs),
    /// its rename target, and its visibility. A rename clears the visibility
    /// intent because that is what the repository's own rule does — a renamed
    /// tag is visible unless it merges into a row that already existed.
    ///
    /// The operation identity stays that of the operation that first persisted
    /// the intent, so an acknowledgement of the replaced revision can never be
    /// mistaken for the replacement's.
    public static func replacing(
        pending: TagMutationIntent,
        incoming: TagMutationIntent
    ) -> TagMutationIntent {
        var knownNames = pending.knownNames
        if let incomingName = incoming.knownNames.last, knownNames.last != incomingName {
            knownNames.append(incomingName)
        }
        var recordingIDs = pending.recordingIDs
        for id in incoming.recordingIDs where !recordingIDs.contains(id) {
            recordingIDs.append(id)
        }
        return TagMutationIntent(
            knownNames: knownNames,
            renamedTo: incoming.renamedTo ?? pending.renamedTo,
            hidden: incoming.hidden,
            recordingIDs: recordingIDs,
            operationID: pending.operationID,
            intendedAt: pending.intendedAt
        )
    }
}

/// A tag mutation whose replay could not reach the intended end state.
///
/// Only thrown after the mutation's own writes ran and the authoritative answer
/// still does not show the intended name/visibility. Classified `retryable`: the
/// next attempt re-reads the server state and repoints from the name the server
/// actually serves, and a state that can never converge reaches the bounded
/// quarantine — visible, retryable, never silently cleared.
public enum TagMutationReplayError: Error, Equatable, Sendable {
    case incompleteTagMutation
}

extension TagMutationReplayError: ServerRejectionClassifying {
    public var rejectionClass: RejectionClass { .retryable }
}

// MARK: - Health metrics (#919)

/// #919: the queue identity of one health row's write intent.
///
/// A health row's identity is its `(user_id, date)` key — `CacheEntityID
/// .healthMetric` IS the date string — while the durable queue keys its items
/// by `UUID`. The two have to map deterministically for the same reason the tag
/// registry's does (#918): a relaunch resolves the pending intent from the row
/// key alone, and a newer pass for the same date replaces the pending one
/// instead of racing it.
///
/// The account is part of the KEY, not just of the queue item: the scheduled
/// date is the same for every account on the device, and the queue is one
/// shared file whose item ids must be unique ACROSS accounts (an id already
/// held by another account's item can never be replaced or re-enqueued). The
/// queue item's own `accountUserID` remains the only scope authority for
/// replay; the account here only makes the identity collision-free.
///
/// The mapping is RFC 4122 §4.3 UUIDv5 over the account and the trimmed date
/// under this namespace, so it is stable for every process and every future
/// build.
public enum HealthWriteIdentity {
    // SAFETY: fixed canonical 32-hex UUID string; UUID(uuidString:) always
    // parses it.
    public static let namespace = UUID(uuidString: "91900000-0000-4000-8000-000000000919")!

    private static let namespaceBytes: [UInt8] = {
        var uuid = namespace.uuid
        return withUnsafeBytes(of: &uuid) { Array($0) }
    }()

    public static func queueItemID(for date: String, accountUserID: UUID) -> UUID {
        let trimmed = date.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = namespaceBytes
        bytes.append(contentsOf: Array(
            "\(accountUserID.uuidString.lowercased()):\(trimmed)".utf8
        ))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// #919: the trigger a health pass was authored under, as a durable value.
///
/// The trigger is part of the intent because it is an INPUT to the write
/// policy the recovery must re-check: a manual sync is authoritative (#109),
/// while an automatic pass after noon keeps an existing score. Re-deciding at
/// recovery time with the wrong trigger would either lose an authoritative
/// write or overwrite a frozen one.
public enum HealthWriteTrigger: String, Codable, Sendable, Equatable, CaseIterable {
    case automatic
    case manual

    public init(_ trigger: SyncTrigger) {
        self = trigger == .manual ? .manual : .automatic
    }

    public var syncTrigger: SyncTrigger {
        self == .manual ? .manual : .automatic
    }
}

/// #919: the durable intent of one interrupted health-metric write.
///
/// Health is the one direct-write family where blind replay is *worse* than
/// dropping the write: a queued readiness score re-sent after the server (or
/// the watch) already moved that day on would overwrite fresher data, and
/// re-running the biometric read to "re-create" evidence is forbidden. So the
/// intent records the exact payload the pass intended — the biometric columns
/// plus, when the pass was allowed to score, the readiness/zone/computedAt the
/// write would have sent — and the recovery REVALIDATES it against the server's
/// current row instead of replaying it (see `HealthWriteReplayPolicy`).
///
/// The mutation is captured before the first server attempt and is never
/// re-derived from later local state: a fresh `HealthKit` read is not part of
/// recovery, so the replayed write is provably the user's own interrupted write
/// and not newly invented evidence.
public struct HealthWriteIntent: Codable, Sendable, Equatable {
    /// The row's date key (`CacheEntityID.healthMetric`), YYYY-MM-DD.
    public let date: String
    /// The exact payload the pass intended to upsert.
    public let payload: HealthMetric
    /// The trigger the pass was authored under (#109/#802 re-check input).
    public let trigger: HealthWriteTrigger
    /// Stable identity of THIS operation, independent of the queue item's
    /// replacement revision: a later pass for the same date replaces the
    /// pending intent with the newer content and a newer operation id.
    public let operationID: UUID
    public let intendedAt: Date

    public init(
        date: String,
        payload: HealthMetric,
        trigger: HealthWriteTrigger,
        operationID: UUID = UUID(),
        intendedAt: Date = Date()
    ) {
        self.date = date
        self.payload = payload
        self.trigger = trigger
        self.operationID = operationID
        self.intendedAt = intendedAt
    }

    /// The queue item identity this intent must be filed under for one
    /// account. The account is a parameter (not a stored field) because the
    /// owning `DurableQueueItem` is the single account authority — the intent
    /// itself must never carry a scope it could be replayed under.
    public func queueIdentity(accountUserID: UUID) -> UUID {
        HealthWriteIdentity.queueItemID(
            for: date,
            accountUserID: accountUserID
        )
    }

    /// Whether `serverRow` already carries everything this intent's payload
    /// intends to write.
    ///
    /// Only the fields the payload actually carries are compared — a nil
    /// readiness/zone means the pass deliberately left the existing score alone
    /// (#109 keep-score branch), and a nil biometric column is one the payload
    /// does not write. `computed_at` is deliberately NOT compared: the DB
    /// stamps `now()` for a fresh insert that carried none, so a lost
    /// acknowledgement can legitimately come back with a different timestamp
    /// while the score and biometrics are exactly the ones that were sent.
    ///
    /// The biometric columns are `real` (float4) in Postgres, so a
    /// round-tripped row differs from a Double payload in the low bits: the
    /// comparison is made at the server's own precision.
    public func isSatisfied(by serverRow: HealthMetric) -> Bool {
        Self.isPayload(payload, satisfiedBy: serverRow)
    }

    /// Whether `serverRow` already carries everything `payload` intends to
    /// write.
    ///
    /// Only the fields the payload actually carries are compared — a nil
    /// readiness/zone means the pass deliberately left the existing score alone
    /// (#109 keep-score branch), and a nil biometric column is one the payload
    /// does not write. `computed_at` is deliberately NOT compared: the DB
    /// stamps `now()` for a fresh insert that carried none, so a lost
    /// acknowledgement can legitimately come back with a different timestamp
    /// while the score and biometrics are exactly the ones that were sent.
    ///
    /// Asked of the RE-DERIVED payload too (see `HealthWriteReplayPolicy`):
    /// "does the row the server already serves make this write a no-op?" is the
    /// same question whether the payload came off the wire or out of the write
    /// policy.
    ///
    /// The biometric columns are `real` (float4) in Postgres, so a
    /// round-tripped row differs from a Double payload in the low bits: the
    /// comparison is made at the server's own precision.
    public static func isPayload(
        _ payload: HealthMetric,
        satisfiedBy serverRow: HealthMetric
    ) -> Bool {
        guard serverRow.date == payload.date else { return false }
        guard matches(payload.readiness, serverRow.readiness) else { return false }
        guard matches(payload.zone, serverRow.zone) else { return false }
        return matches(payload.hrvSDNNMilliseconds, serverRow.hrvSDNNMilliseconds)
            && matches(payload.restingHeartRate, serverRow.restingHeartRate)
            && matches(payload.sleepHours, serverRow.sleepHours)
            && matches(payload.sleepDeepHours, serverRow.sleepDeepHours)
            && matches(payload.sleepREMHours, serverRow.sleepREMHours)
            && matches(payload.bodyMassKilograms, serverRow.bodyMassKilograms)
            && matches(payload.respiratoryRate, serverRow.respiratoryRate)
    }

    /// Whether the payload would overwrite a NEWER score: the server's own row
    /// for this date carries a timestamp later than the payload's own, so the
    /// queued score is stale data. Never true for a payload that carries no
    /// score at all (a keep-score biometric refresh cannot clobber one), and
    /// true for a score with no timestamp of its own that faces a row the
    /// server CAN date — an undatable queued score is never allowed to
    /// overwrite a dated one.
    public func isSupersededByNewerScore(of serverRow: HealthMetric) -> Bool {
        guard payload.readiness != nil else { return false }
        guard let serverComputedAt = serverRow.computedAt else { return false }
        guard let payloadComputedAt = payload.computedAt else { return true }
        return payloadComputedAt < serverComputedAt
    }

    /// One payload field against the server's row at the server's precision.
    /// A nil payload value is a column this write does not touch.
    private static func matches(_ payloadValue: Double?, _ serverValue: Double?) -> Bool {
        guard let payloadValue else { return true }
        guard let serverValue else { return false }
        return Float(payloadValue) == Float(serverValue)
    }

    private static func matches(_ payloadValue: Int?, _ serverValue: Int?) -> Bool {
        guard let payloadValue else { return true }
        return payloadValue == serverValue
    }

    private static func matches(_ payloadValue: String?, _ serverValue: String?) -> Bool {
        guard let payloadValue else { return true }
        return payloadValue == serverValue
    }
}

/// The recovery decision for one durable health write intent.
public enum HealthWriteReplayDecision: Equatable, Sendable {
    /// The server's row already IS this write (a lost acknowledgement), so the
    /// recovery must send nothing and confirm the local row from the server's.
    case alreadyApplied(serverRow: HealthMetric)
    /// The queued payload must NOT be sent: the server's row for the date is
    /// newer (or the date is historical and already immutable). The local row
    /// is confirmed from the server's row — the user's fresher data wins and
    /// the stale queued score is never written.
    case superseded(serverRow: HealthMetric)
    /// The re-derived write the recovery must send, under the CURRENT write
    /// policy (today's date, the server's live row, the intent's own trigger).
    case send(payload: HealthMetric, operation: HealthMetricWriteOperation)
}

/// The replay decisions for a health-metric write (#919). Pure: every input is
/// passed in, so the rules are unit-testable without a server — and the tests
/// that matter run them against a REAL `AppModel` (see
/// `HealthWriteRecoveryAppTests`).
public enum HealthWriteReplayPolicy {
    /// Resolves one interrupted health write against the server's CURRENT row.
    ///
    /// Every clause reads the server's own answer:
    ///
    /// * no row for the date — the write never landed, so it is sent (today
    ///   through the #802 precedence RPC, a past date through the atomic
    ///   insert-if-missing that cannot rewrite an existing immutable row);
    /// * a row that already carries the payload's own fields — the
    ///   acknowledgement was lost, so nothing is sent;
    /// * a PAST date that already has a row — historical rows are immutable,
    ///   so the queued payload can never land and must not rewrite it;
    /// * a row whose score is newer than the queued payload's — the queued
    ///   score is stale and must never overwrite fresh data;
    /// * otherwise the write is re-derived exactly as a live pass would: the
    ///   #109 readiness-freeze decision is re-run against the server's LIVE row
    ///   with the intent's own trigger, and the #802 precedence/`ReadinessSync`
    ///   split decides what (if anything) is still missing.
    ///
    /// `timeZone` is the caller's local calendar: "today" — the one date whose
    /// row may still be merged — is derived from it, never from the queued
    /// date, so an intent authored yesterday becomes a historical
    /// insert-if-missing after midnight instead of a blind merge.
    public static func decide(
        intent: HealthWriteIntent,
        serverRow: HealthMetric?,
        now: Date,
        timeZone: TimeZone = .current
    ) -> HealthWriteReplayDecision {
        let calendar = LocalDateSupport.calendar(timeZone: timeZone)
        let today = LocalDateSupport.string(from: now, timeZone: timeZone)
        let operation = HealthMetricWritePolicy.operation(
            for: intent.date,
            today: today
        )
        guard let serverRow else {
            return .send(payload: intent.payload, operation: operation)
        }
        if intent.isSatisfied(by: serverRow) {
            return .alreadyApplied(serverRow: serverRow)
        }
        // Historical rows are immutable after they exist: an interrupted past
        // write can only ever be an insert, and one is already there.
        if operation == .historicalInsert {
            return .superseded(serverRow: serverRow)
        }
        if intent.isSupersededByNewerScore(of: serverRow) {
            return .superseded(serverRow: serverRow)
        }
        let allowReadinessOverwrite = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: serverRow.readiness,
            existingRowDate: serverRow.date,
            now: now,
            trigger: intent.trigger.syncTrigger,
            calendar: calendar
        )
        let plan = ReadinessSyncPolicy.plan(
            existingToday: serverRow,
            freshlyComputed: intent.payload,
            allowReadinessOverwrite: allowReadinessOverwrite
        )
        if HealthWriteIntent.isPayload(plan.upsertMetric, satisfiedBy: serverRow) {
            return .alreadyApplied(serverRow: serverRow)
        }
        return .send(payload: plan.upsertMetric, operation: operation)
    }
}

/// A health write whose replay could not be confirmed by the server's own
/// answer.
///
/// Only thrown after the write ran and the authoritative read-back still does
/// not serve a row for the date. Classified `retryable`: the next attempt
/// re-reads the server state, and a state that can never converge reaches the
/// bounded quarantine — visible, retryable, never silently cleared.
public enum HealthWriteReplayError: Error, Equatable, Sendable {
    case unconfirmedWrite
}

extension HealthWriteReplayError: ServerRejectionClassifying {
    public var rejectionClass: RejectionClass { .retryable }
}
