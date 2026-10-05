import Foundation
import XCTest
@testable import SendmeterCore

/// #1004 (session-lock layer): the guided lock's owner, and the release the
/// surface owes the user when that owner has already ended.
///
/// The shipped defect this pins: the resume/end card renders only while the
/// session has NOT ended, while `ForceContextLockPolicy` keeps the whole
/// Force surface locked on `guidedSession != nil`. A session that claims its
/// terminal outcome while the guided cover is minimized therefore leaves the
/// surface locked with nothing on it that could resume or end — the lock's
/// owner cannot be read as live, so it must be treated as orphaned and be
/// releasable, not held.
final class ForceLockOrphanPolicyTests: XCTestCase {
    private func read(
        sessionPresent: Bool,
        sessionEnded: Bool,
        launchInFlight: Bool = false
    ) -> ForceGuidedLockReadState {
        ForceGuidedLockReadState(
            sessionPresent: sessionPresent,
            sessionEnded: sessionEnded,
            launchInFlight: launchInFlight
        )
    }

    /// The load-bearing case: a present session that has ended is the orphan,
    /// and the orphan is exactly what requires the release affordance.
    func testAnEndedSessionIsTheOrphanThatRequiresTheRelease() {
        let owner = ForceLockOrphanPolicy.owner(
            read(sessionPresent: true, sessionEnded: true)
        )

        XCTAssertEqual(owner, .endedSession)
        XCTAssertTrue(
            ForceLockOrphanPolicy.requiresRelease(owner),
            "a lock whose owner can no longer be read as live must be releasable"
        )
    }

    /// A live session is NOT an orphan: it keeps its own resume/end card, and
    /// the release must never be reachable for it (releasing a live run would
    /// end it behind the user's back).
    func testALiveSessionIsNeverAnOrphan() {
        let owner = ForceLockOrphanPolicy.owner(
            read(sessionPresent: true, sessionEnded: false)
        )

        XCTAssertEqual(owner, .resumableSession)
        XCTAssertFalse(ForceLockOrphanPolicy.requiresRelease(owner))
    }

    /// The launch attempt is bounded and self-settling (`GuidedLaunchLifecycle`),
    /// so it is a live owner — never user-releasable.
    func testAnInFlightLaunchIsBoundedAndNotAnOrphan() {
        let owner = ForceLockOrphanPolicy.owner(
            read(sessionPresent: false, sessionEnded: false, launchInFlight: true)
        )

        XCTAssertEqual(owner, .launchInFlight)
        XCTAssertFalse(ForceLockOrphanPolicy.requiresRelease(owner))
    }

    func testNoOwnerMeansNoRelease() {
        let owner = ForceLockOrphanPolicy.owner(
            read(sessionPresent: false, sessionEnded: false)
        )

        XCTAssertEqual(owner, .none)
        XCTAssertFalse(ForceLockOrphanPolicy.requiresRelease(owner))
    }

    /// The ended branch is checked FIRST on purpose: whenever a session is
    /// present, a lock that cannot be resumed/ended is the orphan — a stale
    /// extra flag must not mask it back into a locked surface.
    func testTheOrphanBranchWinsWheneverTheSessionIsPresent() {
        let owner = ForceLockOrphanPolicy.owner(
            read(sessionPresent: true, sessionEnded: true, launchInFlight: true)
        )

        XCTAssertEqual(owner, .endedSession)
        XCTAssertTrue(ForceLockOrphanPolicy.requiresRelease(owner))
    }

    /// The invariant, stated at the layer that owns the lock: the orphaned
    /// read is a LOCKED surface (guidedSessionActive is one of the lock
    /// inputs) AND it is a surface whose one working action is the release.
    /// "Locked with no live owner" can never be a dead end.
    func testALockedSurfaceWhoseOnlyOwnerEndedRequiresTheRelease() {
        let locked = ForceContextLockPolicy.isLocked(
            ForceContextLockState(
                liveRecording: false,
                interruptedRecording: false,
                handsFreeArmed: false,
                handsFreeMeasuring: false,
                guidedSessionActive: true
            )
        )
        XCTAssertTrue(locked, "the ended session still holds the surface")

        let owner = ForceLockOrphanPolicy.owner(
            read(sessionPresent: true, sessionEnded: true)
        )
        XCTAssertTrue(
            ForceLockOrphanPolicy.requiresRelease(owner),
            "locked with no live owner must offer exactly the release"
        )
    }

    /// The copy the user reads must name the release and must NOT claim a
    /// resume/end that does not exist — the lie that made the state
    /// unexplainable in the first place.
    func testTheOrphanedLockCopyNamesTheReleaseAndNeverAResume() {
        XCTAssertFalse(ForceLockOrphanPolicy.releaseTitle.isEmpty)
        XCTAssertFalse(ForceLockOrphanPolicy.releaseHeading.isEmpty)
        XCTAssertFalse(ForceLockOrphanPolicy.releaseNotice.isEmpty)
        XCTAssertFalse(ForceLockOrphanPolicy.releaseHint.isEmpty)

        XCTAssertTrue(
            ForceLockOrphanPolicy.activeLockLabel.contains("resume or end"),
            "a live session's row keeps pointing at its resume/end card"
        )
        XCTAssertFalse(
            ForceLockOrphanPolicy.orphanedLockLabel.contains("resume or end"),
            "the orphaned row must not point at affordances that no longer exist"
        )
        XCTAssertNotEqual(
            ForceLockOrphanPolicy.orphanedLockLabel,
            ForceLockOrphanPolicy.activeLockLabel,
            "the two lock states must not share one label"
        )
    }
}
