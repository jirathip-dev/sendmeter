import XCTest
import SendLogWatchCore

final class ForceProtocolTests: XCTestCase {
    func testMovementStarterIsExact() {
        let starter = WatchForceProtocol.movementStarter

        XCTAssertEqual(starter.id, "suggested:movement-starter")
        XCTAssertEqual(starter.name, "Movement Starter")
        XCTAssertEqual(starter.holdS, 40)
        XCTAssertNil(starter.holdsS)
        XCTAssertEqual(starter.reps, 10)
        XCTAssertEqual(starter.sets, 3)
        XCTAssertEqual(starter.restRepsS, 0)
        XCTAssertEqual(starter.restSetsS, 60)
        XCTAssertNil(starter.targetKg)
        XCTAssertNil(starter.targetPct)
        XCTAssertEqual(starter.percentBasis, .pr)
        XCTAssertEqual(starter.percentStep, 0)
        XCTAssertFalse(starter.targetCurve)
        XCTAssertFalse(starter.alternateSides)
        XCTAssertEqual(starter.mode, .reverseAction)
        XCTAssertEqual(starter.cadenceOutS, 3)
        XCTAssertEqual(starter.cadenceReturnS, 1)
        XCTAssertEqual(starter.toleranceMode, .percent)
        XCTAssertEqual(starter.toleranceValue, 10)
        XCTAssertEqual(starter.prepareS, 5)
        XCTAssertEqual(starter.setupNote, "Resisted movement")
        XCTAssertFalse(starter.capacityEvidence)
        XCTAssertEqual(starter.summary, "3s concentric · 1s eccentric · 10 reps × 3 sets · 60s rest")
    }

    func testMovementStarterDurationIncludesPrepare() {
        XCTAssertEqual(WatchForceProtocol.movementStarter.durationS, 245)
    }

    func testLegacyOverCapMovementPresetIsNormalizedBeforeRuntime() throws {
        let json = Data("""
        {
          "id": "legacy-movement",
          "name": "Long movement",
          "hold_s": 40,
          "reps": 50,
          "sets": 1,
          "rest_reps_s": 0,
          "rest_sets_s": 0,
          "target_kg": null,
          "target_pct": null,
          "protocol_mode": "reverse_action",
          "cadence_out_s": 30,
          "cadence_return_s": 30,
          "prepare_s": 5
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(WatchForceProtocol.self, from: json)

        // #682: the recording cap is now 10 min (maxMovementSetS = 599), so a
        // 30/30 cadence preset normalizes to floor(599 / 60) = 9 reps.
        XCTAssertEqual(decoded.reps, 9)
        XCTAssertEqual(decoded.cadenceOutS, 30)
        XCTAssertEqual(decoded.cadenceReturnS, 30)
        XCTAssertEqual(decoded.movementSetDurationS, 540)
        XCTAssertTrue(decoded.movementSetWithinTindeqCap)
        XCTAssertLessThan(decoded.movementSetDurationS, 600)
    }

    func testMovementTimelineHasExactDirectionsAndCounts() {
        let timeline = WatchForceProtocol.movementStarter.timeline

        XCTAssertEqual(timeline.count, 63)
        XCTAssertEqual(timeline.filter { $0.phase == .prepare }.count, 1)
        XCTAssertEqual(timeline.filter { $0.direction == .concentric }.count, 30)
        XCTAssertEqual(timeline.filter { $0.direction == .eccentric }.count, 30)
        XCTAssertEqual(timeline.filter { $0.phase == .setRest }.count, 2)
        XCTAssertEqual(timeline[1].direction, .concentric)
        XCTAssertEqual(timeline[1].rep, 1)
        XCTAssertEqual(timeline[1].set, 1)
        XCTAssertEqual(timeline[2].direction, .eccentric)
        let setRests = timeline.filter { $0.phase == .setRest }
        XCTAssertEqual(setRests.map(\.startS), [45, 145])
        XCTAssertEqual(setRests.map(\.durationS), [60, 60])
        XCTAssertEqual(timeline.last?.startS, 244)
        XCTAssertEqual(timeline.last?.durationS, 1)
    }

    func testLegacyRowDefaultsMissingOptionalFields() throws {
        let json = Data("""
        {
          "id": "legacy-static",
          "name": "Repeaters",
          "hold_s": 7,
          "reps": 6,
          "sets": 3,
          "rest_reps_s": 3,
          "rest_sets_s": 120,
          "target_kg": null,
          "target_pct": null
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(WatchForceProtocol.self, from: json)

        XCTAssertNil(decoded.holdsS)
        XCTAssertEqual(decoded.percentBasis, .pr)
        XCTAssertEqual(decoded.percentStep, 0)
        XCTAssertFalse(decoded.targetCurve)
        XCTAssertFalse(decoded.alternateSides)
        XCTAssertEqual(decoded.mode, .hold)
        XCTAssertEqual(decoded.cadenceOutS, 3)
        XCTAssertEqual(decoded.cadenceReturnS, 3)
        XCTAssertEqual(decoded.toleranceMode, .percent)
        XCTAssertEqual(decoded.toleranceValue, 10)
        XCTAssertEqual(decoded.prepareS, 5)
        XCTAssertEqual(decoded.setupNote, "")
        XCTAssertFalse(decoded.capacityEvidence)
    }

    func testStaticSummaryAndTimeline() {
        let preset = WatchForceProtocol(
            id: "static",
            name: "Max hangs",
            holdS: 7,
            reps: 5,
            sets: 1,
            restRepsS: 3,
            restSetsS: 120,
            prepareS: 5
        )

        XCTAssertEqual(preset.summary, "7s hold · 5 reps × 1 set")
        XCTAssertEqual(preset.timeline.filter { $0.phase == .hold }.count, 5)
        XCTAssertEqual(preset.timeline.filter { $0.phase == .rest }.count, 4)
        XCTAssertTrue(preset.timeline.allSatisfy { $0.direction == nil })
        XCTAssertEqual(preset.durationS, 52)
    }

    func testUserFacingLabelsAreExact() {
        XCTAssertEqual(WatchForceProtocol.Labels.resistedMovement, "Resisted movement")
        XCTAssertEqual(WatchForceProtocol.Labels.movement, "MOVEMENT")
        XCTAssertEqual(WatchForceProtocol.Labels.concentric, "Concentric")
        XCTAssertEqual(WatchForceProtocol.Labels.eccentric, "Eccentric")
    }

    func testSnapshotIsWallClockDerivedAndClamped() {
        let starter = WatchForceProtocol.movementStarter

        let beforeStart = starter.snapshot(at: -10)
        XCTAssertEqual(beforeStart.elapsedS, 0)
        XCTAssertEqual(beforeStart.segment?.phase, .prepare)
        XCTAssertEqual(beforeStart.segmentRemainingS, 5)

        let concentric = starter.snapshot(at: 6)
        XCTAssertEqual(concentric.segment?.phase, .concentric)
        XCTAssertEqual(concentric.segment?.rep, 1)
        XCTAssertEqual(concentric.segmentRemainingS, 2)

        let finished = starter.snapshot(at: 1_000)
        XCTAssertEqual(finished.elapsedS, 245)
        XCTAssertEqual(finished.progress, 1)
        XCTAssertEqual(finished.remainingS, 0)
        XCTAssertNil(finished.segment)
        XCTAssertTrue(finished.isComplete)
    }

    func testLateTickReturnsEveryCrossedCadenceSegmentInOrder() {
        let starter = WatchForceProtocol.movementStarter
        let crossed = starter.crossedSegments(from: 4.9, to: 12.9)

        XCTAssertEqual(crossed.map(\.phase), [.concentric, .eccentric, .concentric, .eccentric])
        XCTAssertEqual(crossed.map(\.startS), [5, 8, 9, 12])
        XCTAssertEqual(crossed.map(\.rep), [1, 1, 2, 2])
    }
}
