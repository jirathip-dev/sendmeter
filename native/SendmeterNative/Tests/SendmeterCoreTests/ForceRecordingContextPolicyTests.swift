import XCTest
@testable import SendmeterCore

final class ForceRecordingContextPolicyTests: XCTestCase {
    /// #1038 G3/G4: Free hold is armed for the whole connected session, so
    /// an armed-but-idle loop must leave the context editable — movement,
    /// side and the protocol list (G4) stay reachable.
    func testAnArmedIdleFreeHoldLeavesTheContextEditable() {
        XCTAssertFalse(
            ForceContextLockPolicy.isLocked(
                ForceContextLockState(
                    liveRecording: false,
                    interruptedRecording: false,
                    handsFreeArmed: true,
                    handsFreeMeasuring: false,
                    guidedSessionActive: false
                )
            )
        )
    }

    /// The moment a rep is owned, the context locks: a measuring loop, a live
    /// pull, a salvaged rep, or a guided run.
    func testEveryOwnedRepLocksTheContext() {
        let owned = [
            ForceContextLockState(liveRecording: true, interruptedRecording: false, handsFreeArmed: false, handsFreeMeasuring: false, guidedSessionActive: false),
            ForceContextLockState(liveRecording: false, interruptedRecording: true, handsFreeArmed: false, handsFreeMeasuring: false, guidedSessionActive: false),
            ForceContextLockState(liveRecording: false, interruptedRecording: false, handsFreeArmed: true, handsFreeMeasuring: true, guidedSessionActive: false),
            ForceContextLockState(liveRecording: false, interruptedRecording: false, handsFreeArmed: false, handsFreeMeasuring: false, guidedSessionActive: true)
        ]
        for state in owned {
            XCTAssertTrue(ForceContextLockPolicy.isLocked(state), "\(state)")
        }
    }

    func testHandsFreePreferenceWithoutAnArmLeavesTheContextEditable() {
        XCTAssertFalse(
            ForceContextLockPolicy.isLocked(
                ForceContextLockState(
                    liveRecording: false,
                    interruptedRecording: false,
                    handsFreeArmed: false,
                    handsFreeMeasuring: false,
                    guidedSessionActive: false
                )
            )
        )
    }

    // #899: `.freePull` (direct-measure manual start) is removed — the
    // remaining stream claimants are the hands-free arm and guided protocols.
    func testSelectingAProtocolDoesNotBlockHandsFreeOrGuidedBeforeTheStreamStarts() {
        let state = ForceRecordingContextState(
            liveRecording: false,
            handsFreeArmed: false,
            protocolArmed: true
        )

        XCTAssertEqual(
            ForceRecordingContextPolicy.decision(for: .handsFree, state: state),
            .allowed
        )
        XCTAssertEqual(
            ForceRecordingContextPolicy.decision(for: .guidedProtocol, state: state),
            .allowed
        )
    }

    func testAnArmedButIdleHandsFreeStreamCanBeHandedToAProtocol() {
        let state = ForceRecordingContextState(
            liveRecording: false,
            handsFreeArmed: true,
            protocolArmed: true
        )

        XCTAssertEqual(
            ForceRecordingContextPolicy.decision(for: .guidedProtocol, state: state),
            .safeHandoffFromArmedStream
        )
        XCTAssertTrue(
            ForceRecordingContextPolicy.decision(for: .guidedProtocol, state: state).isAllowed
        )
    }

    func testAnActiveRecordingRefusesEveryCompetingStreamOwner() {
        let state = ForceRecordingContextState(
            liveRecording: true,
            handsFreeArmed: false,
            protocolArmed: true
        )

        for action in [ForceRecordingAction.handsFree, .guidedProtocol] {
            XCTAssertEqual(
                ForceRecordingContextPolicy.decision(for: action, state: state),
                .refusedActiveRecording
            )
        }
    }
}
