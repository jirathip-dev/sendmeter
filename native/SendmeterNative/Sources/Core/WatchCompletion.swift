import Foundation

/// The compact completion summary delivered by the watch after its workout
/// bundle has been durably queued. The payload is deliberately summary-only;
/// the watch's queued bundle and the server delta remain authoritative for the
/// full workout and its attempts.
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
        WatchCompletionIdentity(sessionID: sessionID, workoutID: workoutID)
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
/// delivered through another WCSession route.
public struct WatchCompletionIdentity: Codable, Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let workoutID: UUID

    public init(sessionID: UUID, workoutID: UUID) {
        self.sessionID = sessionID
        self.workoutID = workoutID
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
        if let stampedOwner, stampedOwner != currentUserID {
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
        self.values = Array(unique.suffix(resolvedLimit))
    }

    /// Returns true only when this is a new stable completion identity.
    @discardableResult
    public mutating func retain(_ completion: WatchWorkoutCompletion) -> Bool {
        guard !values.contains(where: { $0.identity == completion.identity }) else {
            return false
        }
        values.append(completion)
        if values.count > limit {
            values.removeFirst(values.count - limit)
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
}
