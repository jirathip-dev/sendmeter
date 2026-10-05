import Foundation

/// #1004 (session-lock layer): who holds the Force surface's guided lock —
/// and what the surface owes the user when nobody does.
///
/// The lock the owner hit is `ForceContextLockState.guidedSessionActive`,
/// fed from the Force surface as `guidedSession != nil`
/// (`ForceView.guidedSessionIsActive`). Every affordance that could clear
/// that lock — the resume/end card and the guided cover — is conditioned on
/// the session NOT having ended, so a session that reaches its terminal
/// claim while the cover is minimized keeps `guidedSession != nil` and the
/// whole surface locked with nothing left to resume or end.
///
/// No owner identifier is persisted or decoded anywhere on this path (the
/// session is a live `@State` object), so an owner that cannot be READ as
/// live reduces to the same state: a lock with no live owner, i.e. an
/// orphan. The policy therefore decides by attribution alone — "present but
/// not live" is an orphan, never a reason to keep the surface locked.
public enum ForceGuidedLockOwner: Equatable, Sendable {
    /// No guided owner on the surface.
    case none
    /// A live guided session: its resume/end affordances are on screen.
    case resumableSession
    /// A guided-launch attempt is in flight. Bounded and self-settling
    /// (`GuidedLaunchLifecycle`), so it releases the surface by itself and
    /// is never user-releasable — not an orphan.
    case launchInFlight
    /// The lock is held by a session that has already ended: it can neither
    /// resume nor end again, and no other affordance can clear it. ORPHANED.
    case endedSession
}

/// What the Force surface can read about the guided lock's owner.
///
/// Deliberately only these three facts: the surface has them synchronously
/// (`guidedSession != nil`, `guidedSession.isEnded`,
/// `guidedLaunch.inFlight`), and none requires decoding stored state. There
/// is no owner-id input because the lock has never had one — an owner the
/// surface cannot attribute reads as "present but not live" and lands on
/// the orphan branch below.
public struct ForceGuidedLockReadState: Equatable, Sendable {
    public let sessionPresent: Bool
    public let sessionEnded: Bool
    public let launchInFlight: Bool

    public init(
        sessionPresent: Bool,
        sessionEnded: Bool,
        launchInFlight: Bool
    ) {
        self.sessionPresent = sessionPresent
        self.sessionEnded = sessionEnded
        self.launchInFlight = launchInFlight
    }
}

public enum ForceLockOrphanPolicy {
    /// Attributes the guided lock from what the surface can read.
    ///
    /// The ended-session branch is checked FIRST and is the only orphan: a
    /// lock whose owner cannot be read as live must be releasable, not held.
    public static func owner(_ state: ForceGuidedLockReadState) -> ForceGuidedLockOwner {
        if state.sessionPresent {
            return state.sessionEnded ? .endedSession : .resumableSession
        }
        return state.launchInFlight ? .launchInFlight : .none
    }

    /// Render the release affordance exactly when the lock has no live
    /// owner — the same invariant shape #1004's first half established for
    /// the held pull ("exactly one working recovery action").
    public static func requiresRelease(_ owner: ForceGuidedLockOwner) -> Bool {
        owner == .endedSession
    }

    /// The release affordance's copy, in one place so the card, its hint and
    /// the device-row lock label cannot drift apart.
    public static let releaseTitle = "Clear Finished Session"
    public static let releaseHeading = "A finished guided protocol is holding this screen"
    public static let releaseNotice = "The protocol has already ended, so there is nothing left to resume or end \u{2014} but its session still holds the screen. Clearing it releases this screen; nothing you recorded, queued, or left unsaved is deleted."
    public static let releaseHint = "Releases this screen; nothing you recorded is deleted"
    /// The device-row lock label while a LIVE session holds the surface.
    public static let activeLockLabel = "Guided protocol active \u{2014} resume or end it above"
    /// The device-row lock label while an ENDED session still holds the
    /// surface: "resume or end it above" would be a lie (there is nothing to
    /// resume or end), so the row names the release it can see instead.
    public static let orphanedLockLabel = "A finished guided protocol is still holding this screen \u{2014} clear it above"
}
