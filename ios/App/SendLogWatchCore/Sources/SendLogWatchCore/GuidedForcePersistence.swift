import Foundation

public enum GuidedForceRecordingKind: String, Sendable, Equatable {
    case movementSet
    case staticHold
}

public enum GuidedForceCompletionStatus: String, Sendable, Codable, Equatable {
    case complete
    case partial
}

/// Stable identity for one database row in a guided run. A movement set has
/// no rep component because the complete cadence set is one continuous trace;
/// every static hold is its own row and therefore includes its rep number.
public struct GuidedForceRecordingKey: Hashable, Sendable {
    public let runId: UUID
    public let set: Int
    public let rep: Int?

    public init(runId: UUID, set: Int, rep: Int?) {
        self.runId = runId
        self.set = set
        self.rep = rep
    }
}

/// Immutable execution metadata captured when work starts, before any BLE or
/// persistence callback can race a changed picker/protocol selection.
public struct GuidedForceRecordingContext: Sendable, Equatable {
    public let key: GuidedForceRecordingKey
    public let kind: GuidedForceRecordingKind
    public let protocolId: String
    public let tag: String
    public let side: String
    public let zone: String?
    public let plannedDurationMs: Int
    public let targetBand: MovementTargetBand?
    public let cadenceOutS: Double?
    public let cadenceReturnS: Double?
    public let cadenceMarkers: [WatchCadenceMarker]?
    public let setupNote: String
    public let capacityEvidence: Bool

    public init(
        key: GuidedForceRecordingKey,
        kind: GuidedForceRecordingKind,
        protocolId: String,
        tag: String,
        side: String,
        zone: String?,
        plannedDurationMs: Int,
        targetBand: MovementTargetBand?,
        cadenceOutS: Double?,
        cadenceReturnS: Double?,
        cadenceMarkers: [WatchCadenceMarker]?,
        setupNote: String,
        capacityEvidence: Bool
    ) {
        self.key = key
        self.kind = kind
        self.protocolId = protocolId
        self.tag = tag
        self.side = side
        self.zone = zone
        self.plannedDurationMs = max(1, plannedDurationMs)
        self.targetBand = targetBand
        self.cadenceOutS = cadenceOutS
        self.cadenceReturnS = cadenceReturnS
        self.cadenceMarkers = cadenceMarkers
        self.setupNote = setupNote
        self.capacityEvidence = capacityEvidence
    }
}

public extension GuidedForceRecordingContext {
    static func movementSet(
        protocolValue: WatchForceProtocol,
        runId: UUID,
        set: Int,
        tag: String,
        side: String,
        zone: String?,
        targetBand: MovementTargetBand?
    ) -> GuidedForceRecordingContext? {
        guard protocolValue.mode == .reverseAction, set >= 1, set <= protocolValue.sets else {
            return nil
        }
        let work = protocolValue.timeline.filter {
            $0.set == set && ($0.phase == .concentric || $0.phase == .eccentric)
        }
        guard let first = work.first, let last = work.last else { return nil }
        let durationMs = Int(((last.startS + last.durationS - first.startS) * 1_000).rounded())
        return GuidedForceRecordingContext(
            key: GuidedForceRecordingKey(runId: runId, set: set, rep: nil),
            kind: .movementSet,
            protocolId: protocolValue.id,
            tag: tag,
            side: side,
            zone: zone,
            plannedDurationMs: durationMs,
            targetBand: targetBand,
            cadenceOutS: protocolValue.cadenceOutS,
            cadenceReturnS: protocolValue.cadenceReturnS,
            cadenceMarkers: protocolValue.cadenceMarkers(forSet: set),
            setupNote: protocolValue.setupNote,
            capacityEvidence: protocolValue.capacityEvidence
        )
    }

    static func staticHold(
        protocolValue: WatchForceProtocol,
        runId: UUID,
        set: Int,
        rep: Int,
        tag: String,
        side: String,
        zone: String?,
        targetBand: MovementTargetBand?
    ) -> GuidedForceRecordingContext? {
        guard protocolValue.mode == .hold,
              set >= 1, set <= protocolValue.sets,
              rep >= 1, rep <= protocolValue.reps,
              let hold = protocolValue.timeline.first(where: {
                  $0.phase == .hold && $0.set == set && $0.rep == rep
              })
        else { return nil }
        return GuidedForceRecordingContext(
            key: GuidedForceRecordingKey(runId: runId, set: set, rep: rep),
            kind: .staticHold,
            protocolId: protocolValue.id,
            tag: tag,
            side: side,
            zone: zone,
            plannedDurationMs: Int((hold.durationS * 1_000).rounded()),
            targetBand: targetBand,
            cadenceOutS: nil,
            cadenceReturnS: nil,
            cadenceMarkers: nil,
            setupNote: protocolValue.setupNote,
            capacityEvidence: protocolValue.capacityEvidence
        )
    }
}

public struct GuidedForceRecordingClaim: Sendable, Equatable {
    public let id: UUID
    public let context: GuidedForceRecordingContext

    public init(id: UUID, context: GuidedForceRecordingContext) {
        self.id = id
        self.context = context
    }
}

/// Synchronous exactly-once ledger. `claimFinish` removes the active value and
/// records its stable run/set/rep key in one operation, before callers create
/// a Task or reach an await. Cadence-only rows use the same claimed-key set.
public struct GuidedForceSaveClaims: Sendable, Equatable {
    public private(set) var active: GuidedForceRecordingClaim?
    public private(set) var claimedKeys: Set<GuidedForceRecordingKey>

    public init(active: GuidedForceRecordingClaim? = nil, claimedKeys: Set<GuidedForceRecordingKey> = []) {
        self.active = active
        self.claimedKeys = claimedKeys
    }

    @discardableResult
    public mutating func begin(
        context: GuidedForceRecordingContext,
        id: UUID = UUID()
    ) -> GuidedForceRecordingClaim? {
        guard active == nil, !claimedKeys.contains(context.key) else { return nil }
        let claim = GuidedForceRecordingClaim(id: id, context: context)
        active = claim
        return claim
    }

    public mutating func claimFinish() -> GuidedForceRecordingClaim? {
        guard let claim = active else { return nil }
        active = nil
        claimedKeys.insert(claim.context.key)
        return claim
    }

    public mutating func claimCadenceOnly(
        context: GuidedForceRecordingContext,
        id: UUID = UUID()
    ) -> GuidedForceRecordingClaim? {
        guard context.kind == .movementSet,
              active == nil,
              !claimedKeys.contains(context.key)
        else { return nil }
        claimedKeys.insert(context.key)
        return GuidedForceRecordingClaim(id: id, context: context)
    }

    public mutating func discardActive() {
        active = nil
    }

    public mutating func reset() {
        active = nil
        claimedKeys.removeAll()
    }
}

public struct GuidedForceCompletion: Sendable, Equatable {
    public let actualDurationMs: Int
    public let completedReps: Int?
    public let status: GuidedForceCompletionStatus?
    public let cadenceMarkers: [WatchCadenceMarker]?

    public init(
        actualDurationMs: Int,
        completedReps: Int?,
        status: GuidedForceCompletionStatus?,
        cadenceMarkers: [WatchCadenceMarker]?
    ) {
        self.actualDurationMs = actualDurationMs
        self.completedReps = completedReps
        self.status = status
        self.cadenceMarkers = cadenceMarkers
    }
}

/// Codable contract for the guided columns flattened into a
/// `tindeq_recordings` PostgREST insert. Keeping this in Core pins the exact
/// snake_case database keys without importing Supabase or watch frameworks.
public struct GuidedForceDatabaseFields: Sendable, Codable, Equatable {
    public let protocolRunId: UUID
    public let setNo: Int
    public let repNo: Int?
    public let zone: String?
    public let source: String
    public let outcome: String?
    public let plannedDurationMs: Int
    public let actualDurationMs: Int
    public let protocolMode: String
    public let targetKg: Double?
    public let targetLowKg: Double?
    public let targetHighKg: Double?
    public let cadenceOutS: Double?
    public let cadenceReturnS: Double?
    public let cadenceMarkers: [WatchCadenceMarker]?
    public let setMetrics: MovementSetMetrics?
    public let setupNote: String?
    public let capacityEvidence: Bool
    public let completedReps: Int?
    public let completionStatus: String?

    public init(
        context: GuidedForceRecordingContext,
        completion: GuidedForceCompletion,
        source: String,
        outcome: String?,
        metrics: MovementSetMetrics?,
        capacityEvidence: Bool? = nil
    ) {
        protocolRunId = context.key.runId
        setNo = context.key.set
        repNo = context.key.rep
        zone = context.zone
        self.source = source
        self.outcome = outcome
        plannedDurationMs = context.plannedDurationMs
        actualDurationMs = completion.actualDurationMs
        protocolMode = context.kind == .movementSet ? "reverse_action" : "hold"
        targetKg = context.targetBand?.kg
        targetLowKg = context.targetBand?.lowKg
        targetHighKg = context.targetBand?.highKg
        cadenceOutS = context.cadenceOutS
        cadenceReturnS = context.cadenceReturnS
        cadenceMarkers = completion.cadenceMarkers
        setMetrics = metrics
        setupNote = context.setupNote.isEmpty ? nil : context.setupNote
        self.capacityEvidence = capacityEvidence ?? context.capacityEvidence
        completedReps = completion.completedReps
        completionStatus = completion.status?.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case zone, source, outcome
        case protocolRunId = "protocol_run_id"
        case setNo = "set_no"
        case repNo = "rep_no"
        case plannedDurationMs = "planned_duration_ms"
        case actualDurationMs = "actual_duration_ms"
        case protocolMode = "protocol_mode"
        case targetKg = "target_kg"
        case targetLowKg = "target_low_kg"
        case targetHighKg = "target_high_kg"
        case cadenceOutS = "cadence_out_s"
        case cadenceReturnS = "cadence_return_s"
        case cadenceMarkers = "cadence_markers"
        case setMetrics = "set_metrics"
        case setupNote = "setup_note"
        case capacityEvidence = "capacity_evidence"
        case completedReps = "completed_reps"
        case completionStatus = "completion_status"
    }
}

/// Honest completion derived only from captured context and elapsed work.
/// Partial movement markers stop at the last boundary actually reached, and
/// completed reps count whole out+return cadence cycles only.
public func guidedForceCompletion(
    context: GuidedForceRecordingContext,
    actualDurationMs: Int
) -> GuidedForceCompletion? {
    guard actualDurationMs > 0 else { return nil }
    let actual = min(actualDurationMs, context.plannedDurationMs)
    guard context.kind == .movementSet else {
        return GuidedForceCompletion(
            actualDurationMs: actual,
            completedReps: nil,
            status: nil,
            cadenceMarkers: nil
        )
    }
    let cadenceMs = Int((((context.cadenceOutS ?? 0) + (context.cadenceReturnS ?? 0)) * 1_000).rounded())
    let prescribedReps = context.cadenceMarkers?.map(\.rep).max() ?? 0
    let completed = cadenceMs > 0 ? min(prescribedReps, actual / cadenceMs) : 0
    return GuidedForceCompletion(
        actualDurationMs: actual,
        completedReps: completed,
        status: actual >= context.plannedDurationMs ? .complete : .partial,
        cadenceMarkers: context.cadenceMarkers?.filter { $0.tMs <= actual }
    )
}

/// Guided disconnect salvage must be an unplanned active measured recording
/// with enough trace points to build an honest row. The claim ledger supplies
/// the exactly-once guarantee; this helper pins only the boundary decision.
public func shouldSalvageGuidedForce(
    wasIntentional: Bool,
    hasActiveClaim: Bool,
    wasMeasuring: Bool,
    sampleCount: Int
) -> Bool {
    !wasIntentional && hasActiveClaim && wasMeasuring && sampleCount >= 2
}
