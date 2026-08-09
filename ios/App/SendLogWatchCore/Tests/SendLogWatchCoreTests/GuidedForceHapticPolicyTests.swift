import XCTest
import SendLogWatchCore

final class GuidedForceHapticPolicyTests: XCTestCase {
    func testLaunchPrepareBatchHasExactlyOneCueBoundary() {
        XCTAssertEqual(
            GuidedForceHapticPolicy.latestCueIndex(in: [.prepare]),
            0
        )
    }

    func testDelayedMovementAdvanceReplaysManyBoundariesButCuesLatestSetStart() {
        var state = GuidedForceRunState(
            protocolValue: .movementStarter,
            runId: UUID(uuidString: "4B9D7B42-9D8E-4F17-9B6D-DA4E7B2BDCE4")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        _ = state.advance(elapsedS: 12.9)
        let events = state.advance(elapsedS: 105.1)
        let directionCount = events.reduce(into: 0) { count, event in
            if case .direction = event { count += 1 }
        }
        XCTAssertGreaterThanOrEqual(directionCount, 16)

        guard let cueIndex = GuidedForceHapticPolicy.latestCueIndex(in: events) else {
            return XCTFail("A delayed movement advance should have a current boundary cue")
        }
        XCTAssertEqual(events[cueIndex], .startMovement(set: 2))
        XCTAssertEqual(state.advance(elapsedS: 105.1), [])
    }

    func testCatchUpBatchCuesOnlyItsLatestBoundary() {
        let events: [GuidedForceRunEvent] = [
            .startMovement(set: 1),
            .direction(.eccentric),
            .finishMovement(set: 1),
            .rest(set: 1, rep: nil),
            .startMovement(set: 2),
            .direction(.concentric)
        ]

        XCTAssertEqual(GuidedForceHapticPolicy.latestCueIndex(in: events), 5)
    }

    func testPersistenceOnlyBoundariesDoNotCue() {
        let events: [GuidedForceRunEvent] = [
            .finishMovement(set: 1),
            .finishStaticHold(set: 1, rep: 1)
        ]

        XCTAssertNil(GuidedForceHapticPolicy.latestCueIndex(in: events))
    }

    func testCompletionWinsOverHistoricalDirectionCues() {
        let events: [GuidedForceRunEvent] = [
            .direction(.eccentric),
            .finishMovement(set: 1),
            .completed
        ]

        XCTAssertEqual(GuidedForceHapticPolicy.latestCueIndex(in: events), 2)
    }
}
