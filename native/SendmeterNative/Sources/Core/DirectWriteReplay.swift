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
