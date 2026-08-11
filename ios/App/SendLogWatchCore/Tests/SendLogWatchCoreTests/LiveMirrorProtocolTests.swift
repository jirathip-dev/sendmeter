import XCTest
@testable import SendLogWatchCore

final class LiveMirrorProtocolTests: XCTestCase {
    func testSequenceStartsAtOneAndAllowsTelemetryGaps() {
        let id = UUID()
        var allocator = LiveMirrorSequence(runId: id)
        let start = allocator.next(event: .start)
        let telemetry = allocator.next(event: .telemetry)
        _ = allocator.next(event: .telemetry)
        let phase = allocator.next(event: .phase)

        XCTAssertEqual(start.runId, id)
        XCTAssertEqual(start.sequence, 1)
        XCTAssertEqual(start.event, .start)
        XCTAssertEqual(telemetry.sequence, 2)
        XCTAssertEqual(phase.sequence, 4)
        XCTAssertTrue(LiveMirrorEvent.phase.isDiscrete)
        XCTAssertFalse(LiveMirrorEvent.telemetry.isDiscrete)
    }

    func testSequenceExhaustionNeverEmitsIntMaxTwice() {
        let id = UUID()
        var allocator = LiveMirrorSequence(runId: id, nextSequence: Int.max)

        let final = allocator.nextIfAvailable(event: .telemetry)
        XCTAssertEqual(final?.sequence, Int.max)
        XCTAssertTrue(allocator.isExhausted)
        XCTAssertNil(allocator.nextIfAvailable(event: .telemetry))

        // A receiver still rejects a replay of that one final beat, just as
        // it does for every other duplicate sequence.
        var cursor = LiveMirrorCursor()
        XCTAssertEqual(cursor.accept(final!), .accepted)
        XCTAssertEqual(cursor.accept(final!), .duplicate)
    }

    func testPendingIdentityDoesNotLetOlderInvocationEraseNewerRow() {
        var pending = LiveMirrorPendingIdentity()
        pending.replace(withSequence: 10)
        pending.replace(withSequence: 11)

        XCTAssertFalse(pending.clear(ifSequence: 10))
        XCTAssertTrue(pending.matches(sequence: 11))
        XCTAssertTrue(pending.clear(ifSequence: 11))
        XCTAssertNil(pending.sequence)
    }

    func testCursorRejectsDuplicatesAndOutOfOrderBeats() {
        let id = UUID()
        var cursor = LiveMirrorCursor()
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 1, event: .start)), .accepted)
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 1, event: .start)), .duplicate)
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 3, event: .telemetry)), .accepted)
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 2, event: .telemetry)), .outOfOrder)
        XCTAssertEqual(cursor.lastSequence, 3)
    }

    func testTerminalBeatDominatesLateLiveData() {
        let id = UUID()
        var cursor = LiveMirrorCursor()
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 4, event: .telemetry)), .accepted)
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 5, event: .end)), .accepted)
        XCTAssertTrue(cursor.terminal)
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 6, event: .telemetry)), .afterTerminal)
        // Even a lower sequence cannot re-open a terminal run.
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: id, sequence: 2, event: .phase)), .afterTerminal)
    }

    func testNewRunReplacesCursorAndOldRunCanBeRejectedByCaller() {
        let old = UUID()
        let fresh = UUID()
        var cursor = LiveMirrorCursor(runId: old, lastSequence: 99, terminal: true)
        XCTAssertEqual(
            cursor.accept(LiveMirrorBeat(runId: fresh, sequence: 1, event: .start), isNewerRun: false),
            .staleRun
        )
        XCTAssertEqual(cursor.runId, old)
        XCTAssertEqual(cursor.accept(LiveMirrorBeat(runId: fresh, sequence: 1, event: .start)), .accepted)
        XCTAssertEqual(cursor.runId, fresh)
        XCTAssertEqual(cursor.lastSequence, 1)
        XCTAssertFalse(cursor.terminal)
    }

    func testLegacyTerminalAlwaysWinsTimestampRace() {
        XCTAssertTrue(
            LiveMirrorLegacyFreshness.accepts(
                previousUpdatedAtMs: 200,
                incomingUpdatedAtMs: 100,
                previousTerminal: false,
                incomingTerminal: true
            )
        )
        XCTAssertFalse(
            LiveMirrorLegacyFreshness.accepts(
                previousUpdatedAtMs: 100,
                incomingUpdatedAtMs: 200,
                previousTerminal: true,
                incomingTerminal: false
            )
        )
    }

    func testWireFieldsKeepSnakeCaseAndTerminalEventConsistent() {
        let id = UUID()
        let beat = LiveMirrorBeat(runId: id, sequence: 7, event: .end)
        XCTAssertEqual(beat.wireFields["run_id"] as? String, id.uuidString)
        XCTAssertEqual(beat.wireFields["sequence"] as? Int, 7)
        XCTAssertEqual(beat.wireFields["event"] as? String, "end")
        XCTAssertEqual(beat.wireFields["terminal"] as? Bool, true)
    }

    // MARK: LiveMirrorOwnership (#530)

    func testStampedAddsTheRawUppercaseUUIDString() {
        let owner = UUID()
        let stamped = LiveMirrorOwnership.stamped(["kind": "liveWorkout"], ownerUserId: owner)
        XCTAssertEqual(stamped[LiveMirrorOwnership.accountUserIdKey] as? String, owner.uuidString)
        XCTAssertEqual(stamped["kind"] as? String, "liveWorkout")
    }

    func testStampedLeavesTheKeyOffEntirelyForANilOwner() {
        let stamped = LiveMirrorOwnership.stamped(["kind": "liveWorkout"], ownerUserId: nil)
        XCTAssertNil(stamped[LiveMirrorOwnership.accountUserIdKey])
        XCTAssertEqual(stamped.count, 1, "a nil owner must not add any key, not even a null")
    }

    func testStampedDoesNotDisturbOtherWireFields() {
        let owner = UUID()
        let beat = LiveMirrorBeat(runId: UUID(), sequence: 3, event: .telemetry)
        let message = LiveMirrorOwnership.stamped(beat.wireFields, ownerUserId: owner)
        XCTAssertEqual(message["sequence"] as? Int, 3)
        XCTAssertEqual(message["event"] as? String, "telemetry")
        XCTAssertEqual(message[LiveMirrorOwnership.accountUserIdKey] as? String, owner.uuidString)
    }
}
