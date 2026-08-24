import Foundation

/// The two queue payloads that create a session row. They share one durable
/// delete barrier even though their network calls are different: a pending
/// delete must wait behind either an ordinary session insert or a phone
/// workout insert.
public enum PendingSessionInsert: Equatable, Sendable {
    case loggedSession(sessionID: UUID)
    case manualWorkout(sessionID: UUID)

    public var sessionID: UUID {
        switch self {
        case let .loggedSession(sessionID), let .manualWorkout(sessionID):
            return sessionID
        }
    }
}

public enum PendingSessionDeleteKind: Equatable, Sendable {
    case session
    case manualWorkout
}

public enum PendingSessionDeletePolicy {
    /// A delete is blocked by either insert flavor for the same session id.
    public static func matches(
        insert: PendingSessionInsert,
        deleteSessionID: UUID
    ) -> Bool {
        insert.sessionID == deleteSessionID
    }

    /// Rebuilding optimistic rows after relaunch must skip a matching insert
    /// while its delete claim is active, regardless of payload flavor.
    public static func shouldRestore(
        insert: PendingSessionInsert,
        remoteSessionIDs: Set<UUID>,
        deleteIsClaimed: Bool
    ) -> Bool {
        !remoteSessionIDs.contains(insert.sessionID) && !deleteIsClaimed
    }

    /// Both insert flavors need the same post-insert delete drain. Keeping the
    /// decision here prevents the AppModel switch from silently becoming
    /// `.session`-only again.
    public static func shouldDrainDeleteAfterInsert(
        _ insert: PendingSessionInsert
    ) -> Bool {
        switch insert {
        case .loggedSession, .manualWorkout:
            return true
        }
    }

    public static func successMessage(for kind: PendingSessionDeleteKind) -> String {
        switch kind {
        case .session:
            return "Session deleted."
        case .manualWorkout:
            return "Workout deleted."
        }
    }
}
