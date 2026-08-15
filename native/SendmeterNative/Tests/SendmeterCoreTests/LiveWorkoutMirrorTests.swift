import XCTest
@testable import SendmeterCore

final class LiveWorkoutMirrorTests: XCTestCase {
    private let runID = UUID()
    private let workoutID = UUID()
    private let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
    private let updatedAt = Date(timeIntervalSince1970: 1_750_000_010)

    private func row(
        status: String = "live",
        terminal: Any? = nil,
        runIDValue: Any? = nil,
        event: Any? = nil,
        sequence: Any? = nil
    ) -> [String: Any] {
        var record: [String: Any] = [
            "workout_id": workoutID.uuidString,
            "status": status,
            "started_at": LocalDateSupport.iso8601String(from: startedAt),
            "updated_at": LocalDateSupport.iso8601String(from: updatedAt),
            "hr": 118.0,
            "attempt_count": 3,
            "active_kcal": 42.5,
            "elevation_gain_m": 12.0,
            "climbing": true,
            "climbing_since": LocalDateSupport.iso8601String(from: startedAt.addingTimeInterval(-40)),
            "rest_started_at": LocalDateSupport.iso8601String(from: startedAt.addingTimeInterval(-35)),
            "rest_target_s": 180
        ]
        if let terminal { record["terminal"] = terminal }
        if let runIDValue { record["run_id"] = runIDValue }
        if let event { record["event"] = event }
        if let sequence { record["sequence"] = sequence }
        return record
    }

    private func liveWorkout(
        runID: UUID? = nil,
        sequence: Int? = nil,
        terminal: Bool = false,
        status: String = "live",
        startedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> LiveWorkout {
        LiveWorkout(
            workoutID: workoutID,
            runID: runID ?? self.runID,
            sequence: sequence,
            event: "telemetry",
            terminal: terminal,
            status: status,
            startedAt: startedAt ?? self.startedAt,
            heartRate: 118,
            attemptCount: 3,
            activeKilocalories: 42.5,
            elevationGainMeters: 12,
            climbing: true,
            climbingSince: nil,
            restStartedAt: nil,
            restTargetSeconds: 180,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    // MARK: Row decoding

    func testRowDecodesAllFields() throws {
        let workout = try XCTUnwrap(liveWorkoutFromRow(record: row(
            terminal: true,
            runIDValue: runID.uuidString,
            event: "end",
            sequence: 9
        )))
        XCTAssertEqual(workout.workoutID, workoutID)
        XCTAssertEqual(workout.runID, runID)
        XCTAssertEqual(workout.sequence, 9)
        XCTAssertEqual(workout.event, "end")
        XCTAssertTrue(workout.terminal)
        XCTAssertEqual(workout.status, "live")
        XCTAssertEqual(workout.heartRate, 118)
        XCTAssertEqual(workout.attemptCount, 3)
        XCTAssertEqual(workout.activeKilocalories, 42.5)
        XCTAssertEqual(workout.elevationGainMeters, 12)
        XCTAssertTrue(workout.climbing)
        XCTAssertNotNil(workout.climbingSince)
        XCTAssertNotNil(workout.restStartedAt)
        XCTAssertEqual(workout.restTargetSeconds, 180)
    }

    func testRowDecodeRequiresIdentityAndTimestamps() {
        var missingWorkoutID = row()
        missingWorkoutID.removeValue(forKey: "workout_id")
        XCTAssertNil(liveWorkoutFromRow(record: missingWorkoutID))

        var missingStartedAt = row()
        missingStartedAt.removeValue(forKey: "started_at")
        XCTAssertNil(liveWorkoutFromRow(record: missingStartedAt))

        var missingUpdatedAt = row()
        missingUpdatedAt.removeValue(forKey: "updated_at")
        XCTAssertNil(liveWorkoutFromRow(record: missingUpdatedAt))

        var badStatus = row()
        badStatus["status"] = 42
        XCTAssertNil(liveWorkoutFromRow(record: badStatus))
    }

    func testRowDecodeFallsBackToDurableDefaults() throws {
        var record = row(status: "ended")
        record.removeValue(forKey: "attempt_count")
        record.removeValue(forKey: "climbing")
        let workout = try XCTUnwrap(liveWorkoutFromRow(record: record))
        XCTAssertEqual(workout.runID, workoutID)
        XCTAssertTrue(workout.terminal)
        XCTAssertEqual(workout.event, "telemetry")
        XCTAssertEqual(workout.sequence, nil)
        XCTAssertEqual(workout.attemptCount, 0)
        XCTAssertFalse(workout.climbing)
    }

    func testRowDecodeAcceptsUppercaseAndLowercaseUUIDs() {
        XCTAssertNotNil(liveWorkoutFromRow(record: row(runIDValue: runID.uuidString.uppercased())))
        XCTAssertNotNil(liveWorkoutFromRow(record: row(runIDValue: runID.uuidString.lowercased())))
    }

    // MARK: WC message decoding

    func testWCMessageDecodesStampedBeat() throws {
        let message: [String: Any] = [
            "kind": "liveWorkout",
            "status": "live",
            "run_id": runID.uuidString,
            "sequence": 4,
            "event": "count",
            "terminal": false,
            "started_at": startedAt.timeIntervalSince1970,
            "hr": 121.0,
            "attempt_count": 5,
            "active_kcal": 20.0,
            "elevation_gain_m": 3.0,
            "climbing": true,
            "updated_at": updatedAt.timeIntervalSince1970
        ]
        let workout = try XCTUnwrap(liveWorkoutFromWCMessage(message: message, previous: nil))
        XCTAssertEqual(workout.runID, runID)
        XCTAssertEqual(workout.sequence, 4)
        XCTAssertEqual(workout.event, "count")
        XCTAssertFalse(workout.terminal)
        XCTAssertEqual(workout.startedAt, startedAt)
        XCTAssertEqual(workout.updatedAt, updatedAt)
        XCTAssertEqual(workout.heartRate, 121)
        XCTAssertEqual(workout.attemptCount, 5)
    }

    func testWCMessageLegacyRunIdentityIsStableAcrossBeats() throws {
        var legacy: [String: Any] = [
            "status": "live",
            "started_at": startedAt.timeIntervalSince1970,
            "updated_at": updatedAt.timeIntervalSince1970
        ]
        let first = try XCTUnwrap(liveWorkoutFromWCMessage(message: legacy, previous: nil))
        legacy["updated_at"] = updatedAt.timeIntervalSince1970 + 1
        let second = try XCTUnwrap(liveWorkoutFromWCMessage(message: legacy, previous: first))
        XCTAssertEqual(first.runID, second.runID)
        // A NEW run (new start time) must NOT inherit the old identity.
        legacy["started_at"] = startedAt.timeIntervalSince1970 + 3_600
        legacy["updated_at"] = updatedAt.timeIntervalSince1970 + 2
        let third = try XCTUnwrap(liveWorkoutFromWCMessage(message: legacy, previous: second))
        XCTAssertNotEqual(second.runID, third.runID)
    }

    func testWCMessageRequiresStatusAndUpdatedAt() {
        XCTAssertNil(liveWorkoutFromWCMessage(message: ["status": "live"], previous: nil))
        XCTAssertNil(liveWorkoutFromWCMessage(
            message: ["updated_at": updatedAt.timeIntervalSince1970],
            previous: nil
        ))
    }

    // MARK: Merge discipline (web parity)

    func testFirstPacketAlwaysAccepted() {
        XCTAssertTrue(liveWorkoutMirrorAccepts(previous: nil, incoming: liveWorkout()))
    }

    func testOlderRunRejected() {
        let older = liveWorkout(
            runID: UUID(),
            startedAt: startedAt.addingTimeInterval(-600),
            updatedAt: updatedAt
        )
        XCTAssertFalse(liveWorkoutMirrorAccepts(previous: liveWorkout(), incoming: older))
    }

    func testTerminalRowDominatesAndBlocksLaterLiveBeats() {
        let terminal = liveWorkout(terminal: true, status: "ended")
        XCTAssertTrue(liveWorkoutMirrorAccepts(previous: liveWorkout(), incoming: terminal))

        let lateLive = liveWorkout(sequence: 99, updatedAt: updatedAt.addingTimeInterval(60))
        XCTAssertFalse(liveWorkoutMirrorAccepts(previous: terminal, incoming: lateLive))
    }

    func testFreshnessIsJudgedBeforeTerminalDominance() {
        // A packet from an OLDER run arriving after a terminal row is stale —
        // it must not be accepted, then blocked by the terminal row (#614 F11).
        let terminal = liveWorkout(terminal: true, status: "ended")
        let olderRun = liveWorkout(
            runID: UUID(),
            startedAt: startedAt.addingTimeInterval(-3_600)
        )
        XCTAssertFalse(liveWorkoutMirrorAccepts(previous: terminal, incoming: olderRun))
    }

    func testNewerRunAcceptedEvenAfterTerminal() {
        let terminal = liveWorkout(terminal: true, status: "ended")
        let newerRun = liveWorkout(
            runID: UUID(),
            startedAt: startedAt.addingTimeInterval(3_600)
        )
        XCTAssertTrue(liveWorkoutMirrorAccepts(previous: terminal, incoming: newerRun))
    }

    func testSequenceCursorRejectsOutOfOrderAndDuplicates() {
        let seq5 = liveWorkout(sequence: 5)
        XCTAssertTrue(liveWorkoutMirrorAccepts(previous: liveWorkout(sequence: 4), incoming: seq5))
        XCTAssertFalse(liveWorkoutMirrorAccepts(previous: seq5, incoming: liveWorkout(sequence: 3)))
        XCTAssertFalse(liveWorkoutMirrorAccepts(previous: seq5, incoming: liveWorkout(sequence: 5)))
        XCTAssertTrue(liveWorkoutMirrorAccepts(previous: seq5, incoming: liveWorkout(sequence: 6)))
    }

    func testReduceUpdatesCursorAndReceiptTime() {
        let nowMs = Date().timeIntervalSince1970 * 1_000
        let result = reduceLiveWorkoutMirror(
            state: .empty,
            incoming: liveWorkout(sequence: 2),
            source: .watchDirect,
            nowMs: nowMs
        )
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.state.row?.sequence, 2)
        XCTAssertEqual(result.state.source, .watchDirect)
        XCTAssertEqual(result.state.lastAcceptedAtMs, nowMs)

        let stale = reduceLiveWorkoutMirror(
            state: result.state,
            incoming: liveWorkout(sequence: 1),
            source: .serverFallback,
            nowMs: nowMs
        )
        XCTAssertFalse(stale.accepted)
        XCTAssertEqual(stale.state, result.state)
    }

    func testServerRowCanReplaceWatchBeatIdentity() {
        // The WC beat predates the initial fetch: the durable row (same run,
        // later sequence) takes over as server-fallback.
        let beat = liveWorkoutFromWCMessage(
            message: ["status": "live", "run_id": runID.uuidString, "sequence": 1, "started_at": startedAt.timeIntervalSince1970, "updated_at": updatedAt.timeIntervalSince1970],
            previous: nil
        )!
        let mirror = reduceLiveWorkoutMirror(
            state: .empty,
            incoming: beat,
            source: .watchDirect,
            nowMs: 0
        ).state
        let row = liveWorkoutFromRow(record: row(runIDValue: runID.uuidString, sequence: 2))!
        XCTAssertEqual(row.runID, beat.runID)
        let reduced = reduceLiveWorkoutMirror(
            state: mirror,
            incoming: row,
            source: .serverFallback,
            nowMs: 1_000
        )
        XCTAssertTrue(reduced.accepted)
        XCTAssertEqual(reduced.state.source, .serverFallback)
    }

    // MARK: Visibility + sync state

    func testVisibleRowHidesEndedTerminalAndStale() {
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1_000
        let fresh = LiveWorkoutMirrorState(
            row: liveWorkout(
                startedAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-5)
            ),
            source: .watchDirect,
            lastAcceptedAtMs: nowMs - 1_000
        )
        XCTAssertNotNil(visibleLiveWorkoutRow(fresh, nowMs: nowMs))

        let ended = LiveWorkoutMirrorState(
            row: liveWorkout(status: "ended", updatedAt: now.addingTimeInterval(-5)),
            source: .watchDirect,
            lastAcceptedAtMs: nowMs - 1_000
        )
        XCTAssertNil(visibleLiveWorkoutRow(ended, nowMs: nowMs))

        let stale = LiveWorkoutMirrorState(
            row: liveWorkout(updatedAt: now.addingTimeInterval(-5)),
            source: .watchDirect,
            lastAcceptedAtMs: nowMs - 40_000
        )
        XCTAssertNil(visibleLiveWorkoutRow(stale, nowMs: nowMs))

        let oldData = LiveWorkoutMirrorState(
            row: liveWorkout(updatedAt: now.addingTimeInterval(-40)),
            source: .watchDirect,
            lastAcceptedAtMs: nowMs - 1_000
        )
        XCTAssertNil(visibleLiveWorkoutRow(oldData, nowMs: nowMs))
    }

    func testSyncStateReflectsSourceThenQuietThenStale() {
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1_000
        let watch = LiveWorkoutMirrorState(
            row: liveWorkout(
                startedAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-5)
            ),
            source: .watchDirect,
            lastAcceptedAtMs: nowMs - 2_000
        )
        XCTAssertEqual(liveWorkoutSyncState(for: watch, nowMs: nowMs), .watchDirect)

        let quiet = LiveWorkoutMirrorState(
            row: liveWorkout(
                startedAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-5)
            ),
            source: .watchDirect,
            lastAcceptedAtMs: nowMs - 12_000
        )
        XCTAssertEqual(liveWorkoutSyncState(for: quiet, nowMs: nowMs), .temporarilyUnreachable)

        let stale = LiveWorkoutMirrorState(
            row: liveWorkout(
                startedAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-5)
            ),
            source: .watchDirect,
            lastAcceptedAtMs: nowMs - 40_000
        )
        XCTAssertEqual(liveWorkoutSyncState(for: stale, nowMs: nowMs), .unknown)

        let server = LiveWorkoutMirrorState(
            row: liveWorkout(
                startedAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-5)
            ),
            source: .serverFallback,
            lastAcceptedAtMs: nowMs - 2_000
        )
        XCTAssertEqual(liveWorkoutSyncState(for: server, nowMs: nowMs), .serverFallback)

        XCTAssertEqual(liveWorkoutSyncState(for: .empty, nowMs: nowMs), .unknown)
    }
}
