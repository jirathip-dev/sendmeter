import XCTest
@testable import SendmeterCore

final class ForceRecordingContextPolicyTests: XCTestCase {
    func testSelectingAProtocolDoesNotBlockAFreeActionBeforeTheStreamStarts() {
        let state = ForceRecordingContextState(
            liveRecording: false,
            handsFreeArmed: false,
            protocolArmed: true
        )

        XCTAssertEqual(
            ForceRecordingContextPolicy.decision(for: .freePull, state: state),
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

        for action in [ForceRecordingAction.freePull, .handsFree, .guidedProtocol] {
            XCTAssertEqual(
                ForceRecordingContextPolicy.decision(for: action, state: state),
                .refusedActiveRecording
            )
        }
    }
}
