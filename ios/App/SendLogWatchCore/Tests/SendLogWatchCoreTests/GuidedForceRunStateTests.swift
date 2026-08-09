import XCTest
import SendLogWatchCore

final class GuidedForceRunStateTests: XCTestCase {
    private let runID = UUID(uuidString: "4B9D7B42-9D8E-4F17-9B6D-DA4E7B2BDCE4")!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testLateTickProcessesAllMovementBoundariesInOrderWithoutDuplicates() {
        var state = GuidedForceRunState(
            protocolValue: .movementStarter,
            runId: runID,
            startedAt: start
        )

        let first = state.advance(elapsedS: 12.9)
        XCTAssertEqual(first, [
            .prepare,
            .startMovement(set: 1),
            .direction(.eccentric),
            .direction(.concentric),
            .direction(.eccentric),
        ])

        // The runner does not start a new persistence row for each cadence
        // direction.  The state machine still crosses those boundaries, but
        // only the set boundary emits finish/start events.
        let second = state.advance(elapsedS: 105.1)
        let secondDirections = second.compactMap { event -> WatchForceProtocol.TimelineSegment.Direction? in
            guard case let .direction(direction) = event else { return nil }
            return direction
        }
        XCTAssertEqual(secondDirections.count, 16)
        XCTAssertEqual(Array(secondDirections.prefix(2)), [.concentric, .eccentric])
        XCTAssertEqual(Array(second.suffix(3)), [
            .finishMovement(set: 1),
            .rest(set: 1, rep: nil),
            .startMovement(set: 2),
        ])
        XCTAssertEqual(state.advance(elapsedS: 105.1), [])
    }

    func testNormalMovementRunHasOneStartAndFinishPerSetAndCompletes() {
        var state = GuidedForceRunState(
            protocolValue: .movementStarter,
            runId: runID,
            startedAt: start
        )

        let events = state.advance(elapsedS: .infinity)

        XCTAssertEqual(events.filter {
            if case .startMovement = $0 { return true }
            return false
        }.count, 3)
        XCTAssertEqual(events.filter {
            if case .finishMovement = $0 { return true }
            return false
        }.count, 3)
        XCTAssertEqual(events.last, .completed)
        XCTAssertTrue(state.isTerminal)
        XCTAssertFalse(state.isStopped)
        XCTAssertEqual(state.advance(elapsedS: 245), [])
    }

    func testEarlyStopFinishesOnlyTheActivePartialSet() {
        var state = GuidedForceRunState(
            protocolValue: .movementStarter,
            runId: runID,
            startedAt: start
        )

        _ = state.advance(elapsedS: 12)
        let events = state.stop(elapsedS: 12.25)

        XCTAssertEqual(events, [.finishMovement(set: 1), .stopped])
        XCTAssertTrue(state.isTerminal)
        XCTAssertTrue(state.isStopped)
        XCTAssertEqual(state.advance(elapsedS: 100), [])
    }

    func testCadenceOnlyRunStillHasOnePersistenceBoundaryPerSet() {
        var state = GuidedForceRunState(
            protocolValue: .movementStarter,
            runId: runID,
            startedAt: start
        )

        let events = state.advance(elapsedS: 245)
        let starts = events.compactMap { event -> Int? in
            guard case let .startMovement(set) = event else { return nil }
            return set
        }
        let finishes = events.compactMap { event -> Int? in
            guard case let .finishMovement(set) = event else { return nil }
            return set
        }

        XCTAssertEqual(starts, [1, 2, 3])
        XCTAssertEqual(finishes, [1, 2, 3])
    }

    func testStaticHoldsStartAndFinishPerHoldAcrossLateTick() {
        let protocolValue = WatchForceProtocol(
            id: "static",
            name: "Static",
            holdS: 5,
            reps: 2,
            sets: 1,
            restRepsS: 2,
            restSetsS: 0,
            prepareS: 3
        )
        var state = GuidedForceRunState(
            protocolValue: protocolValue,
            runId: runID,
            startedAt: start
        )

        let events = state.advance(elapsedS: protocolValue.durationS)

        XCTAssertEqual(events, [
            .prepare,
            .startStaticHold(set: 1, rep: 1),
            .finishStaticHold(set: 1, rep: 1),
            .rest(set: 1, rep: 1),
            .startStaticHold(set: 1, rep: 2),
            .finishStaticHold(set: 1, rep: 2),
            .completed,
        ])
    }
}
