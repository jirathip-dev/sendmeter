import XCTest
import SendLogWatchCore

final class WorkoutCompletedReportTests: XCTestCase {
    private func summary() -> WorkoutCompletedReport.Summary {
        WorkoutCompletedReport.Summary(
            sessionId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            workoutId: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            startedAt: Date(timeIntervalSince1970: 1_752_000_000),
            endedAt: Date(timeIntervalSince1970: 1_752_002_100),
            attemptCount: 4,
            durationMin: 35,
            rpe: 6.5,
            phase: "strength",
            type: "auto",
            typeLabel: "Auto-tracked",
            note: "4 boulders · avg HR 148",
            rpeConfirmed: false
        )
    }

    func testPayloadCarriesOnlyCanonicalSummaryAndStableIds() {
        let payload = WorkoutCompletedReport.payload(summary: summary())
        XCTAssertEqual(payload["kind"] as? String, "workoutCompleted")
        // Swift UUID.uuidString is UPPERCASE while Postgres canonicalizes
        // uuid text to lowercase — the phone lowercases session_id at the
        // pending-row source (pendingSessionFromWatchMessage) before any
        // reconcile comparison (#615 F1), so these ids compare equal there.
        XCTAssertEqual(payload["session_id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(payload["workout_id"] as? String, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(payload["started_at"] as? Double, 1_752_000_000)
        XCTAssertEqual(payload["ended_at"] as? Double, 1_752_002_100)
        XCTAssertEqual(payload["attempt_count"] as? Int, 4)
        XCTAssertEqual(payload["duration_min"] as? Int, 35)
        XCTAssertEqual(payload["rpe"] as? Double, 6.5)
        XCTAssertEqual(payload["rpe_confirmed"] as? Bool, false)
        // No heavy fields ride the wire.
        XCTAssertNil(payload["raw"])
        XCTAssertNil(payload["samples"])
        XCTAssertNil(payload["hr"])
    }

    func testPayloadRoundTripsThroughSummary() throws {
        let payload = WorkoutCompletedReport.payload(summary: summary())
        let parsed = try XCTUnwrap(WorkoutCompletedReport.summary(in: payload))
        XCTAssertEqual(parsed.sessionId, summary().sessionId)
        XCTAssertEqual(parsed.workoutId, summary().workoutId)
        XCTAssertEqual(parsed.startedAt, summary().startedAt)
        XCTAssertEqual(parsed.endedAt, summary().endedAt)
        XCTAssertEqual(parsed.attemptCount, 4)
        XCTAssertEqual(parsed.durationMin, 35)
        XCTAssertEqual(parsed.rpe, 6.5)
        XCTAssertEqual(parsed.phase, "strength")
        XCTAssertEqual(parsed.note, "4 boulders · avg HR 148")
        XCTAssertEqual(parsed.rpeConfirmed, false)
    }

    func testSummaryRefusesPayloadMissingRequiredFields() {
        XCTAssertNil(WorkoutCompletedReport.summary(in: [:]))
        var missing = WorkoutCompletedReport.payload(summary: summary())
        missing.removeValue(forKey: "session_id")
        XCTAssertNil(WorkoutCompletedReport.summary(in: missing))
        var malformed = WorkoutCompletedReport.payload(summary: summary())
        malformed["duration_min"] = "not-a-number"
        XCTAssertNil(WorkoutCompletedReport.summary(in: malformed))
    }

    func testStrippedRemovesOnlyKind() {
        var payload = WorkoutCompletedReport.payload(summary: summary())
        payload["account_user_id"] = "some-account"
        let stripped = WorkoutCompletedReport.stripped(payload)
        XCTAssertNil(stripped["kind"])
        XCTAssertEqual(stripped["account_user_id"] as? String, "some-account")
        XCTAssertEqual(stripped["session_id"] as? String, "11111111-2222-3333-4444-555555555555")
    }
}

final class WorkoutCompletedNotifyTests: XCTestCase {
    func testNotifiesOnlyAfterADurableOutcome() {
        XCTAssertTrue(WorkoutCompletedNotify.shouldNotify(after: .queued))
        XCTAssertTrue(WorkoutCompletedNotify.shouldNotify(after: .uploadedDirect))
        XCTAssertFalse(WorkoutCompletedNotify.shouldNotify(after: .lost))
    }
}
