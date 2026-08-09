import XCTest
import SendLogWatchCore

final class GuidedForcePersistenceTests: XCTestCase {
    private let runId = UUID()

    private func movement(set: Int = 1) -> GuidedForceRecordingContext {
        GuidedForceRecordingContext.movementSet(
            protocolValue: .movementStarter,
            runId: runId,
            set: set,
            tag: "FDP",
            side: "left",
            zone: nil,
            targetBand: MovementTargetBand(kg: 20, lowKg: 18, highKg: 22)
        )!
    }

    private func staticHold(set: Int = 1, rep: Int = 1) -> GuidedForceRecordingContext {
        GuidedForceRecordingContext.staticHold(
            protocolValue: WatchForceProtocol(
                id: "static", name: "Repeaters", holdS: 7,
                reps: 3, sets: 2, restRepsS: 3, restSetsS: 60
            ),
            runId: runId,
            set: set,
            rep: rep,
            tag: "Half crimp",
            side: "right",
            zone: "max_strength",
            targetBand: nil
        )!
    }

    func testMovementAndStaticContextsCaptureExactRowIdentity() {
        let movement = movement(set: 2)
        XCTAssertEqual(movement.key, GuidedForceRecordingKey(runId: runId, set: 2, rep: nil))
        XCTAssertEqual(movement.kind, .movementSet)
        XCTAssertEqual(movement.plannedDurationMs, 40_000)
        XCTAssertEqual(movement.cadenceMarkers?.count, 20)

        let hold = staticHold(set: 2, rep: 3)
        XCTAssertEqual(hold.key, GuidedForceRecordingKey(runId: runId, set: 2, rep: 3))
        XCTAssertEqual(hold.kind, .staticHold)
        XCTAssertEqual(hold.plannedDurationMs, 7_000)
        XCTAssertNil(hold.cadenceMarkers)
    }

    func testDuplicateFinishAndCadenceOnlyClaimsAreRejected() {
        var claims = GuidedForceSaveClaims()
        let context = movement()
        XCTAssertNotNil(claims.begin(context: context, id: UUID()))
        let first = claims.claimFinish()
        XCTAssertNotNil(first)
        XCTAssertNil(claims.claimFinish())
        XCTAssertNil(claims.begin(context: context, id: UUID()))
        XCTAssertNil(claims.claimCadenceOnly(context: context, id: UUID()))

        let nextSet = movement(set: 2)
        XCTAssertNotNil(claims.claimCadenceOnly(context: nextSet, id: UUID()))
        XCTAssertNil(claims.claimCadenceOnly(context: nextSet, id: UUID()))
    }

    func testConcurrentFinishClaimsExactlyOneSave() async {
        let harness = await MainActor.run { GuidedClaimHarness(context: movement()) }
        let first = Task { @MainActor in await harness.finish() }
        let second = Task { @MainActor in await harness.finish() }
        await first.value
        await second.value
        let savedCount = await MainActor.run { harness.savedCount }
        XCTAssertEqual(savedCount, 1)
    }

    func testMovementCompletionFiltersMarkersAndCountsWholeReps() throws {
        let context = movement()
        let partial = try XCTUnwrap(guidedForceCompletion(context: context, actualDurationMs: 9_500))
        XCTAssertEqual(partial.actualDurationMs, 9_500)
        XCTAssertEqual(partial.completedReps, 2)
        XCTAssertEqual(partial.status, .partial)
        XCTAssertEqual(partial.cadenceMarkers?.map(\.tMs), [0, 3_000, 4_000, 7_000, 8_000])

        let complete = try XCTUnwrap(guidedForceCompletion(context: context, actualDurationMs: 50_000))
        XCTAssertEqual(complete.actualDurationMs, 40_000)
        XCTAssertEqual(complete.completedReps, 10)
        XCTAssertEqual(complete.status, .complete)
        XCTAssertEqual(complete.cadenceMarkers?.count, 20)
    }

    func testStaticCompletionHasNoInventedMovementFields() throws {
        let completion = try XCTUnwrap(guidedForceCompletion(
            context: staticHold(), actualDurationMs: 4_000
        ))
        XCTAssertEqual(completion.actualDurationMs, 4_000)
        XCTAssertNil(completion.completedReps)
        XCTAssertNil(completion.status)
        XCTAssertNil(completion.cadenceMarkers)
    }

    func testDatabaseFieldsEncodeExactPostgRESTKeys() throws {
        let context = movement()
        let completion = try XCTUnwrap(guidedForceCompletion(
            context: context, actualDurationMs: 9_500
        ))
        let metrics = MovementSetMetrics(
            meanKg: 19.2,
            coefficientVariationPct: 3.1,
            inTargetPct: 91,
            timeUnderTensionMs: 8_000,
            driftPct: -2,
            cadenceAdherencePct: 23.8
        )
        let fields = GuidedForceDatabaseFields(
            context: context,
            completion: completion,
            source: "dynamometer",
            outcome: "completed",
            metrics: metrics
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fields)
        ) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set([
            "protocol_run_id", "set_no", "source", "outcome",
            "planned_duration_ms", "actual_duration_ms", "protocol_mode",
            "target_kg", "target_low_kg", "target_high_kg", "cadence_out_s",
            "cadence_return_s", "cadence_markers", "set_metrics", "setup_note",
            "capacity_evidence", "completed_reps", "completion_status",
        ]))
        XCTAssertEqual(object["protocol_run_id"] as? String, runId.uuidString)
        XCTAssertEqual(object["protocol_mode"] as? String, "reverse_action")
        XCTAssertEqual(object["source"] as? String, "dynamometer")
        XCTAssertEqual(object["completed_reps"] as? Int, 2)
        XCTAssertNotNil(object["cadence_markers"])
        XCTAssertNotNil(object["set_metrics"])
    }

    func testStaticDatabaseEncodingSafelyOmitsOptionalMovementFields() throws {
        let context = staticHold()
        let completion = try XCTUnwrap(guidedForceCompletion(
            context: context, actualDurationMs: 4_000
        ))
        let fields = GuidedForceDatabaseFields(
            context: context,
            completion: completion,
            source: "dynamometer",
            outcome: nil,
            metrics: nil
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fields)
        ) as? [String: Any])

        XCTAssertEqual(object["protocol_mode"] as? String, "hold")
        XCTAssertEqual(object["rep_no"] as? Int, 1)
        XCTAssertNil(object["cadence_out_s"])
        XCTAssertNil(object["cadence_markers"])
        XCTAssertNil(object["set_metrics"])
        XCTAssertNil(object["target_kg"])
        XCTAssertNil(object["completion_status"])
    }

    func testGuidedSalvageBoundary() {
        XCTAssertTrue(shouldSalvageGuidedForce(
            wasIntentional: false, hasActiveClaim: true, wasMeasuring: true, sampleCount: 2
        ))
        XCTAssertFalse(shouldSalvageGuidedForce(
            wasIntentional: true, hasActiveClaim: true, wasMeasuring: true, sampleCount: 2
        ))
        XCTAssertFalse(shouldSalvageGuidedForce(
            wasIntentional: false, hasActiveClaim: false, wasMeasuring: true, sampleCount: 2
        ))
        XCTAssertFalse(shouldSalvageGuidedForce(
            wasIntentional: false, hasActiveClaim: true, wasMeasuring: true, sampleCount: 1
        ))
    }
}

@MainActor
private final class GuidedClaimHarness {
    private var claims: GuidedForceSaveClaims
    private(set) var savedCount = 0

    init(context: GuidedForceRecordingContext) {
        claims = GuidedForceSaveClaims()
        XCTAssertNotNil(claims.begin(context: context))
    }

    func finish() async {
        guard claims.claimFinish() != nil else { return }
        await Task.yield()
        savedCount += 1
    }
}
