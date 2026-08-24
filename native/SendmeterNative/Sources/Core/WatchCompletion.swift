import Foundation

/// The compact completion summary delivered by the watch after its workout
/// bundle has been durably queued. The payload is deliberately summary-only;
/// the watch's queued bundle and the server delta remain authoritative for the
/// full workout and its attempts. The optional owner is retained for decoding
/// legacy payloads, but nil is quarantine-only: it never authorizes adoption
/// into the currently signed-in account.
public struct WatchWorkoutCompletion: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let workoutID: UUID
    public let runID: UUID?
    public let sequence: Int?
    public let accountUserID: UUID?
    public let startedAt: Date?
    public let endedAt: Date?
    public let attemptCount: Int
    public let durationMinutes: Int
    public let rpe: Double
    public let phase: PhaseID
    public let type: String
    public let typeLabel: String
    public let note: String
    public let rpeConfirmed: Bool
    public let receivedAt: Date

    public init(
        sessionID: UUID,
        workoutID: UUID,
        runID: UUID? = nil,
        sequence: Int? = nil,
        accountUserID: UUID? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        attemptCount: Int = 0,
        durationMinutes: Int = 1,
        rpe: Double = 6,
        phase: PhaseID = .capacity,
        type: String = "auto",
        typeLabel: String = "Apple Watch",
        note: String = "",
        rpeConfirmed: Bool = false,
        receivedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.workoutID = workoutID
        self.runID = runID
        self.sequence = sequence
        self.accountUserID = accountUserID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attemptCount = attemptCount
        self.durationMinutes = durationMinutes
        self.rpe = rpe
        self.phase = phase
        self.type = type
        self.typeLabel = typeLabel
        self.note = note
        self.rpeConfirmed = rpeConfirmed
        self.receivedAt = receivedAt
    }

    public var identity: WatchCompletionIdentity {
        WatchCompletionIdentity(
            sessionID: sessionID,
            workoutID: workoutID,
            accountUserID: accountUserID
        )
    }

    /// Builds the phone-side History placeholder. The account is supplied by
    /// the live phone auth boundary rather than trusted from the optional wire
    /// stamp, so pre-stamp watch builds cannot create an unscoped row.
    public func pendingSession(accountUserID: UUID) -> Session {
        let date = LocalDateSupport.string(from: endedAt ?? receivedAt)
        return Session(
            id: sessionID,
            date: date,
            type: type,
            typeLabel: typeLabel,
            durationMinutes: max(1, durationMinutes),
            rpe: min(10, max(1, rpe)),
            rpeConfirmed: rpeConfirmed,
            note: note,
            phase: phase,
            workoutSource: .watch,
            pending: true,
            accountUserID: accountUserID
        )
    }
}

/// Stable identity for one watch completion. The session id is the History
/// row key; the workout id is retained in the identity so a transport replay
/// cannot be mistaken for a different workout merely because the summary was
/// delivered through another WCSession route. The optional owner is part of
/// the key so legacy nil-owner quarantine and a later stamped replay remain
/// independently recoverable.
public struct WatchCompletionIdentity: Codable, Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let workoutID: UUID
    /// Ownership is part of the durable identity. A legacy completion with no
    /// owner and the upgraded, stamped replay of that same workout are
    /// different transport records; collapsing them would strand the replay
    /// behind the legacy quarantine forever. It also prevents an identical
    /// client id from making one account's completion acknowledge another's.
    public let accountUserID: UUID?

    public init(sessionID: UUID, workoutID: UUID, accountUserID: UUID? = nil) {
        self.sessionID = sessionID
        self.workoutID = workoutID
        self.accountUserID = accountUserID
    }
}

/// Pure ownership/dedupe decision used before a completion touches the cache.
/// `alreadyAdopted` is read from the account-scoped cache; `inFlightDuplicate`
/// closes the direct-message + transferUserInfo overlap before the first
/// adoption has finished.
public enum WatchCompletionAdoptionDecision: Equatable, Sendable {
    case adopt
    case alreadyAdopted
    case inFlightDuplicate
    case wrongAccount
    /// The completion came from a pre-account-stamp watch build. It may stay
    /// in the separately bounded transport quarantine for diagnostics; a
    /// stamped replay from an upgraded watch is a distinct identity,
    /// but it is never safe to turn it into a row for whichever account is
    /// currently signed in.
    case unscopedLegacy
    case signedOut
}

public struct WatchCompletionAdoptionGate: Sendable {
    private var inFlight: Set<WatchCompletionIdentity> = []

    public init() {}

    public mutating func claim(
        _ identity: WatchCompletionIdentity,
        stampedOwner: UUID?,
        currentUserID: UUID?,
        alreadyAdopted: Bool
    ) -> WatchCompletionAdoptionDecision {
        guard let currentUserID else { return .signedOut }
        guard let stampedOwner else { return .unscopedLegacy }
        if stampedOwner != currentUserID {
            return .wrongAccount
        }
        if alreadyAdopted {
            return .alreadyAdopted
        }
        guard inFlight.insert(identity).inserted else {
            return .inFlightDuplicate
        }
        return .adopt
    }

    public mutating func finish(_ identity: WatchCompletionIdentity) {
        inFlight.remove(identity)
    }

    public mutating func reset() {
        inFlight.removeAll()
    }
}

/// Pure durable-inbox model for the phone-side persisted WC payloads. The
/// transport owns the actual UserDefaults encoding; this type owns bounded
/// retention, stable-identity dedupe, and acknowledge-by-identity semantics.
/// Stamped entries have their own bound; ownerless legacy entries are a
/// separately bounded quarantine so a mixed-version watch cannot evict a
/// valid account's parked completion.
public struct WatchCompletionInbox: Equatable, Sendable {
    public let limit: Int
    public private(set) var values: [WatchWorkoutCompletion]

    public init(limit: Int = 8, values: [WatchWorkoutCompletion] = []) {
        let resolvedLimit = max(1, limit)
        self.limit = resolvedLimit
        var unique: [WatchWorkoutCompletion] = []
        for completion in values {
            guard !unique.contains(where: { $0.identity == completion.identity }) else {
                continue
            }
            unique.append(completion)
        }
        let scoped = unique.filter { $0.accountUserID != nil }
        let legacy = unique.filter { $0.accountUserID == nil }
        self.values = Array(scoped.suffix(resolvedLimit)) + Array(legacy.suffix(resolvedLimit))
    }

    /// Only an explicit wire owner can be presented to an account. Legacy
    /// summaries without an owner remain bounded in `values`, but are never
    /// returned to an account-specific adoption pass.
    public func values(for accountUserID: UUID?) -> [WatchWorkoutCompletion] {
        guard let accountUserID else { return [] }
        return values.filter { $0.accountUserID == accountUserID }
    }

    /// Returns true only when this is a new stable completion identity.
    @discardableResult
    public mutating func retain(_ completion: WatchWorkoutCompletion) -> Bool {
        guard !values.contains(where: { $0.identity == completion.identity }) else {
            return false
        }
        values.append(completion)
        let matchingIndexes = values.indices.filter { values[$0].accountUserID == completion.accountUserID }
        if matchingIndexes.count > limit {
            let removeCount = matchingIndexes.count - limit
            for index in matchingIndexes.prefix(removeCount).reversed() {
                values.remove(at: index)
            }
        }
        return true
    }

    /// Removes one completion only after the caller has durably adopted it.
    @discardableResult
    public mutating func acknowledge(_ completion: WatchWorkoutCompletion) -> Bool {
        guard let index = values.firstIndex(where: { $0.identity == completion.identity }) else {
            return false
        }
        values.remove(at: index)
        return true
    }

    /// Account-scoped acknowledge. Stable ids alone are not an ownership
    /// proof: the same id must not let one account remove another account's
    /// retained completion from the shared transport inbox.
    @discardableResult
    public mutating func acknowledge(
        _ completion: WatchWorkoutCompletion,
        accountUserID: UUID
    ) -> Bool {
        guard completion.accountUserID == accountUserID,
              let index = values.firstIndex(where: { $0.identity == completion.identity }),
              values[index].accountUserID == accountUserID else { return false }
        values.remove(at: index)
        return true
    }

    /// Destructive account deletion only. Normal sign-out never calls this;
    /// valid stamped completions remain parked for that account's next sign-in.
    @discardableResult
    public mutating func discard(accountUserID: UUID) -> Int {
        let before = values.count
        values.removeAll { $0.accountUserID == accountUserID }
        return before - values.count
    }
}
