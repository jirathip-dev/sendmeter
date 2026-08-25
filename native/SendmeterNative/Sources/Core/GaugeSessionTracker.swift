import Foundation

/// The phone's gauge-session lifecycle, mirroring the web's
/// `TindeqProvider`/`useTindeqSession` (`src/hooks/TindeqProvider.tsx`): the
/// group every recording taken during a session shares is minted lazily on
/// the FIRST save — there is no manual "Start Session" — and the session ends
/// (auto-logged) on Finish or disconnect.
///
/// The end CLAIM is the load-bearing part: `endActive()` clears the active
/// session synchronously and returns it exactly once, so two concurrent end
/// paths (a Finish tap racing a disconnect's effect) can each call it and
/// only the first proceeds to log — the same race the web closes with its
/// `endedGroupsRef` claim set in `endGaugeSession`, without needing a second
/// structure.
public struct GaugeSessionTracker: Equatable, Sendable {
    public struct ActiveSession: Equatable, Sendable {
        public let groupID: UUID
        public let startedAt: Date

        public init(groupID: UUID, startedAt: Date) {
            self.groupID = groupID
            self.startedAt = startedAt
        }
    }

    public private(set) var active: ActiveSession?

    public init() {}

    public var isActive: Bool { active != nil }

    /// Return the active session's group, minting it on first call. Written
    /// as one synchronous mutation, so two near-simultaneous saves (a first
    /// rep racing its own recovery) get the SAME group id.
    @discardableResult
    public mutating func ensureSession(now: Date = Date()) -> ActiveSession {
        if let active { return active }
        let session = ActiveSession(groupID: UUID(), startedAt: now)
        active = session
        return session
    }

    /// End the active session: clears it synchronously and returns it. A
    /// second concurrent call sees no active session and returns nil, so the
    /// end can be claimed before any async logging work.
    public mutating func endActive() -> ActiveSession? {
        defer { active = nil }
        return active
    }

    /// Reset without logging (sign-out, account switch).
    public mutating func reset() {
        active = nil
    }
}
