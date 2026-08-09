import Foundation

/// The small, transport-independent contract shared by the watch emitters and
/// their consumers (#521). WatchConnectivity is low latency but opportunistic;
/// the Supabase row is durable but can arrive after a newer Bluetooth beat.
/// Both transports therefore carry the same run identity and strictly
/// increasing sequence number.
public enum LiveMirrorEvent: String, Codable, Sendable, Equatable {
    /// The first snapshot for a run. It is never coalesced.
    case start
    /// A high-rate measurement snapshot. Consumers may skip sequence gaps.
    case telemetry
    /// A phase transition (including a phase transition that also changes the
    /// count). It is never coalesced.
    case phase
    /// A count-only transition. It is never coalesced.
    case count
    /// The terminal snapshot. Once accepted, all later live snapshots for the
    /// same run are rejected, even if their wall clock is newer.
    case end

    public var isDiscrete: Bool {
        switch self {
        case .start, .phase, .count, .end: return true
        case .telemetry: return false
        }
    }

    public var isTerminal: Bool { self == .end }
}

/// Identity and ordering metadata for one mirror snapshot.
public struct LiveMirrorBeat: Codable, Sendable, Equatable {
    public let runId: UUID
    public let sequence: Int
    public let event: LiveMirrorEvent
    public let terminal: Bool

    public init(
        runId: UUID,
        sequence: Int,
        event: LiveMirrorEvent,
        terminal: Bool = false
    ) {
        precondition(sequence > 0, "mirror sequences start at one")
        self.runId = runId
        self.sequence = sequence
        self.event = event
        self.terminal = terminal || event.isTerminal
    }

    /// The keys consumed by both the WC bridge and the web mirror. Keeping
    /// their spelling in one pure type makes a Swift/TypeScript drift visible
    /// in tests instead of at runtime.
    public var wireFields: [String: Any] {
        [
            "run_id": runId.uuidString,
            "sequence": sequence,
            "event": event.rawValue,
            "terminal": terminal,
        ]
    }
}

/// Allocates sequence numbers synchronously, before any transport await. A
/// dropped telemetry packet is allowed to leave a gap; a receiver only needs
/// the ordering relation, not contiguous numbering.
public struct LiveMirrorSequence: Sendable, Equatable {
    public let runId: UUID
    public private(set) var nextSequence: Int
    /// Once the final representable sequence has been allocated, no further
    /// beat can be produced. Keeping this separate from `nextSequence`
    /// matters because `Int.max` is a valid sequence exactly once.
    public private(set) var isExhausted: Bool

    public init(runId: UUID, nextSequence: Int = 1) {
        precondition(nextSequence > 0, "mirror sequences start at one")
        self.runId = runId
        self.nextSequence = nextSequence
        self.isExhausted = false
    }

    public mutating func next(
        event: LiveMirrorEvent,
        terminal: Bool = false
    ) -> LiveMirrorBeat {
        precondition(!isExhausted, "mirror sequence exhausted")
        return allocate(event: event, terminal: terminal)
    }

    /// Non-trapping form for emitters that can fail closed when a counter has
    /// reached its representable limit. In particular, it prevents the old
    /// saturating implementation from emitting `Int.max` twice.
    public mutating func nextIfAvailable(
        event: LiveMirrorEvent,
        terminal: Bool = false
    ) -> LiveMirrorBeat? {
        guard !isExhausted else { return nil }
        return allocate(event: event, terminal: terminal)
    }

    private mutating func allocate(
        event: LiveMirrorEvent,
        terminal: Bool
    ) -> LiveMirrorBeat {
        let beat = LiveMirrorBeat(
            runId: runId,
            sequence: nextSequence,
            event: event,
            terminal: terminal
        )
        if nextSequence == Int.max {
            isExhausted = true
        } else {
            nextSequence += 1
        }
        return beat
    }
}

/// Identity of the row currently being resolved or drained by the live
/// mirror. An actor can suspend between installing a pending row and
/// resolving its user id; a later sequence may replace that row in the
/// meantime. Mutations that belong to the older invocation must therefore be
/// conditional on this identity still matching.
public struct LiveMirrorPendingIdentity: Sendable, Equatable {
    public private(set) var sequence: Int?

    public init(sequence: Int? = nil) {
        if let sequence { precondition(sequence > 0, "mirror sequences start at one") }
        self.sequence = sequence
    }

    public mutating func replace(withSequence sequence: Int) {
        precondition(sequence > 0, "mirror sequences start at one")
        self.sequence = sequence
    }

    public func matches(sequence: Int) -> Bool {
        self.sequence == sequence
    }

    @discardableResult
    public mutating func clear(ifSequence sequence: Int) -> Bool {
        guard self.sequence == sequence else { return false }
        self.sequence = nil
        return true
    }
}

/// Outcome of applying an incoming beat to a receiver cursor.
public enum LiveMirrorFreshness: Sendable, Equatable {
    case accepted
    case duplicate
    case outOfOrder
    case staleRun
    case afterTerminal
}

/// Pure receiver-side freshness state. It deliberately treats a terminal
/// beat as dominant over sequence/timestamp comparisons: an old live packet
/// must never re-open a workout or gauge after End/Disconnect was observed.
public struct LiveMirrorCursor: Sendable, Equatable {
    public private(set) var runId: UUID?
    public private(set) var lastSequence: Int
    public private(set) var terminal: Bool

    public init(runId: UUID? = nil, lastSequence: Int = 0, terminal: Bool = false) {
        self.runId = runId
        self.lastSequence = max(0, lastSequence)
        self.terminal = terminal
    }

    /// Apply a typed beat. A new run replaces the cursor; an older run is
    /// rejected when the caller supplies `isNewerRun: false`, because UUIDs
    /// themselves have no ordering semantics. The default keeps the compact
    /// API useful for a cursor dedicated to one known run stream.
    public mutating func accept(
        _ beat: LiveMirrorBeat,
        isNewerRun: Bool = true
    ) -> LiveMirrorFreshness {
        if runId != beat.runId {
            guard isNewerRun else { return .staleRun }
            runId = beat.runId
            lastSequence = beat.sequence
            terminal = beat.terminal
            return .accepted
        }
        if terminal { return .afterTerminal }
        if beat.sequence < lastSequence { return .outOfOrder }
        if beat.sequence == lastSequence { return .duplicate }
        lastSequence = beat.sequence
        terminal = beat.terminal
        return .accepted
    }
}

/// Wall-clock fallback used while a mixed-version watch is still sending the
/// pre-#521 shape. A real run/sequence pair always wins over this fallback;
/// legacy packets remain readable during a staggered rollout.
public enum LiveMirrorLegacyFreshness {
    public static func accepts(
        previousUpdatedAtMs: Int64?,
        incomingUpdatedAtMs: Int64,
        previousTerminal: Bool,
        incomingTerminal: Bool
    ) -> Bool {
        if previousTerminal && !incomingTerminal { return false }
        if incomingTerminal && !previousTerminal { return true }
        guard let previousUpdatedAtMs else { return true }
        return incomingUpdatedAtMs > previousUpdatedAtMs
    }
}
