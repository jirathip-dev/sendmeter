import XCTest
@testable import SendLogWatchCore

final class GuidedForcePolicyTests: XCTestCase {
    func testMovementSalvageLeavesSessionOpenForCadenceContinuation() {
        XCTAssertFalse(
            GuidedForceDisconnectPolicy.shouldFinishSessionAfterSalvage(kind: .movementSet)
        )
    }

    func testStaticSalvageFinishesSession() {
        XCTAssertTrue(
            GuidedForceDisconnectPolicy.shouldFinishSessionAfterSalvage(kind: .staticHold)
        )
    }

    func testMissingSalvageKindUsesSafeTerminalFallback() {
        XCTAssertTrue(
            GuidedForceDisconnectPolicy.shouldFinishSessionAfterSalvage(kind: nil)
        )
    }

    func testMovementStarterCanRunCadenceOnlyWithoutProgressor() {
        XCTAssertEqual(
            guidedForceStartEligibility(
                for: .movementStarter,
                sensorConnected: false
            ),
            .allowed
        )
    }

    func testStaticProtocolNeedsProgressor() {
        let protocolValue = WatchForceProtocol(
            id: "static",
            name: "Static",
            holdS: 10,
            reps: 2,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0
        )
        XCTAssertEqual(
            guidedForceStartEligibility(for: protocolValue, sensorConnected: false),
            .requiresProgressor
        )
    }

    func testAlternatingStaticProtocolIsUnsupportedEvenWhenConnected() {
        let protocolValue = WatchForceProtocol(
            id: "alternating-static",
            name: "Alternating",
            holdS: 10,
            reps: 2,
            sets: 2,
            restRepsS: 2,
            restSetsS: 10,
            alternateSides: true
        )
        XCTAssertEqual(
            guidedForceStartEligibility(for: protocolValue, sensorConnected: true),
            .alternatingSidesUnsupported
        )
        XCTAssertEqual(
            guidedForceStartEligibility(for: protocolValue, sensorConnected: false),
            .alternatingSidesUnsupported
        )
    }
}
