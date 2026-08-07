import XCTest
import SendLogWatchCore

final class HandsFreeForceTests: XCTestCase {
    private let config = HandsFreeForceConfig(
        startKg: 2,
        stopKg: 1,
        startStableMs: 600,
        stopGraceMs: 1_500
    )

    private func step(_ state: HandsFreeForceState, _ atMs: Double, _ kg: Double) -> HandsFreeForceStep {
        stepHandsFreeForce(state, atMs: atMs, kg: kg, config: config)
    }

    func testStableLoadStartsButBriefSpikeDoesNot() {
        var state = armedHandsFreeForce()
        state = step(state, 0, 2.1).state
        state = step(state, 500, 2.3).state
        XCTAssertNil(step(state, 599, 3).action)

        // A single dip resets the complete stable window.
        state = step(state, 599, 1.9).state
        state = step(state, 700, 2.2).state
        XCTAssertNil(step(state, 1_299, 2.2).action)
        XCTAssertEqual(
            step(state, 1_300, 2.2),
            HandsFreeForceStep(state: .recording(belowSinceMs: nil), action: .start)
        )
    }

    func testReleaseGraceAndHysteresisBandDoNotStopEarly() {
        var state = HandsFreeForceState.recording(belowSinceMs: nil)
        state = step(state, 0, 0.8).state
        state = step(state, 1_000, 0.7).state
        XCTAssertNil(step(state, 1_499, 0).action)

        // The 1...2 kg hysteresis band is above stopKg, so it cancels a
        // pending stop without being high enough to start a fresh rep.
        state = step(state, 1_200, 1.1).state
        XCTAssertEqual(state, .recording(belowSinceMs: nil))
        state = step(state, 2_000, 0.5).state
        XCTAssertNil(step(state, 3_499, 0).action)
        XCTAssertEqual(
            step(state, 3_500, 0),
            HandsFreeForceStep(state: .stopping, action: .stop)
        )
    }

    func testEachTransitionActionIsClaimedExactlyOnce() {
        var result = step(.armed(aboveSinceMs: 0), 600, 5)
        XCTAssertEqual(result.action, .start)
        XCTAssertNil(step(result.state, 601, 5).action)

        result = step(.recording(belowSinceMs: 0), 1_500, 0)
        XCTAssertEqual(result.action, .stop)
        XCTAssertNil(step(result.state, 1_501, 0).action)
    }

    func testRearmCycleCanStartASecondRep() {
        let firstStart = step(.armed(aboveSinceMs: 0), 600, 5)
        let firstStop = step(.recording(belowSinceMs: 700), 2_200, 0)
        XCTAssertEqual(firstStart.action, .start)
        XCTAssertEqual(firstStop.action, .stop)

        var state = armedHandsFreeForce()
        state = step(state, 5_000, 3).state
        let secondStart = step(state, 5_600, 3)
        XCTAssertEqual(secondStart.action, .start)
        XCTAssertEqual(secondStart.state, .recording(belowSinceMs: nil))
    }

    func testInactiveTransportDisarmsExceptForClaimedConnectedArm() {
        let armed = armedHandsFreeForce()
        XCTAssertEqual(handsFreeForceAtInactiveStatus(armed, status: .connected), armed)
        XCTAssertEqual(handsFreeForceAtInactiveStatus(armed, status: .idle), .idle)
        XCTAssertEqual(
            handsFreeForceAtInactiveStatus(.recording(belowSinceMs: nil), status: .connected),
            .idle
        )
    }

    func testBackwardDeviceTimestampRestartsThresholdWindow() {
        XCTAssertEqual(
            step(.armed(aboveSinceMs: 500), 100, 3).state,
            .armed(aboveSinceMs: 100)
        )
        XCTAssertEqual(
            step(.recording(belowSinceMs: 500), 100, 0).state,
            .recording(belowSinceMs: 100)
        )
    }

    func testTwoNearSimultaneousStopClaimsSaveExactlyOnce() async {
        let harness = await MainActor.run { ClaimBeforeAwaitHarness() }
        await MainActor.run { harness.begin() }

        let first = Task { @MainActor in await harness.stopAndSave() }
        let second = Task { @MainActor in await harness.stopAndSave() }
        await first.value
        await second.value

        let savedCount = await MainActor.run { harness.savedCount }
        XCTAssertEqual(savedCount, 1)
    }
}

@MainActor
private final class ClaimBeforeAwaitHarness {
    private var claims = HandsFreeForceRepClaims()
    private(set) var savedCount = 0

    func begin() {
        XCTAssertNotNil(claims.begin(tag: "Half crimp", side: "left"))
    }

    func stopAndSave() async {
        // This is the production ordering: consume synchronously, then await.
        guard claims.claimStop() != nil else { return }
        await Task.yield()
        savedCount += 1
    }
}
