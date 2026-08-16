import XCTest
@testable import SendmeterCore

final class HistorySelectionTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func recording(
        id: String,
        at timeInterval: TimeInterval,
        durationMs: Int = 60_000,
        tag: String = "",
        groupID: UUID? = nil
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: Date(timeIntervalSince1970: timeInterval),
            durationMilliseconds: durationMs,
            peakKilograms: 25,
            averageKilograms: 20,
            sampleCount: 60,
            note: "",
            tag: tag,
            side: .unspecified,
            groupID: groupID
        )
    }

    // MARK: Session fields

    func testPlanDefaultsToRpe5TindeqTypeAndFirstRecordingDay() {
        let first = recording(
            id: "00000000-0000-0000-0000-00000000000A",
            at: 2 * 86_400 + 10_000
        )
        let last = recording(
            id: "00000000-0000-0000-0000-00000000000B",
            at: 2 * 86_400 + 600_000
        )
        let plan = SelectionSessionPlanner.plan(recordings: [first, last], phase: .strength, timeZone: utc)
        XCTAssertEqual(plan?.rpe, 5)
        XCTAssertEqual(plan?.type, "tindeq")
        XCTAssertEqual(plan?.typeLabel, "Tindeq")
        XCTAssertEqual(plan?.phase, .strength)
        XCTAssertEqual(plan?.date, "1970-01-03")
    }

    func testPlanDurationSpansFirstStartToLastEndRoundedToMinutes() {
        // First starts at t=100s (10s hold), last starts at t=200s (20s hold):
        // span = (200 - 100) + 20 = 120s → 2 minutes.
        let first = recording(
            id: "00000000-0000-0000-0000-00000000000A",
            at: 100,
            durationMs: 10_000
        )
        let last = recording(
            id: "00000000-0000-0000-0000-00000000000B",
            at: 200,
            durationMs: 20_000
        )
        let plan = SelectionSessionPlanner.plan(recordings: [first, last], phase: .capacity, timeZone: utc)
        XCTAssertEqual(plan?.durationMinutes, 2)
    }

    func testPlanDurationRoundsHalfUpLikeTheWeb() {
        // span = 90s → Math.round(90/60) = 2 minutes (first at t=0s with a
        // 30s hold, last at t=60s with a 30s hold).
        let first = recording(
            id: "00000000-0000-0000-0000-00000000000A",
            at: 0,
            durationMs: 30_000
        )
        let last = recording(
            id: "00000000-0000-0000-0000-00000000000B",
            at: 60,
            durationMs: 30_000
        )
        let plan = SelectionSessionPlanner.plan(recordings: [first, last], phase: .capacity, timeZone: utc)
        XCTAssertEqual(plan?.durationMinutes, 2)
    }

    func testPlanDurationFloorsAtOneMinute() {
        // span = 10s → max(1, round(10/60)) = 1 minute.
        let single = recording(id: "00000000-0000-0000-0000-00000000000A", at: 0, durationMs: 10_000)
        let plan = SelectionSessionPlanner.plan(recordings: [single], phase: .capacity, timeZone: utc)
        XCTAssertEqual(plan?.durationMinutes, 1)
    }

    func testPlanNoteCountsRecordingsAndJoinsDistinctTags() {
        let recordings = [
            recording(id: "00000000-0000-0000-0000-00000000000A", at: 0, tag: "Crimps"),
            recording(id: "00000000-0000-0000-0000-00000000000B", at: 100, tag: "Hangboard"),
            recording(id: "00000000-0000-0000-0000-00000000000C", at: 200, tag: "Crimps"),
            recording(id: "00000000-0000-0000-0000-00000000000D", at: 300, tag: ""),
        ]
        let plan = SelectionSessionPlanner.plan(recordings: recordings, phase: .capacity, timeZone: utc)
        // Tags deduped, first-seen order, empty tags dropped.
        XCTAssertEqual(plan?.note, "4 recordings · Crimps, Hangboard")
    }

    func testPlanNoteForSingleTaglessRecording() {
        let single = recording(id: "00000000-0000-0000-0000-00000000000A", at: 0, tag: "")
        let plan = SelectionSessionPlanner.plan(recordings: [single], phase: .capacity, timeZone: utc)
        XCTAssertEqual(plan?.note, "1 recording")
    }

    // MARK: The grouping (which recordings move under the new session)

    func testPlanRecordsAllSelectedIdsChronologically() {
        let first = recording(id: "00000000-0000-0000-0000-00000000000B", at: 300)
        let second = recording(id: "00000000-0000-0000-0000-00000000000A", at: 100)
        let plan = SelectionSessionPlanner.plan(recordings: [first, second], phase: .capacity, timeZone: utc)
        XCTAssertEqual(
            plan?.recordingIDs,
            [UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!]
        )
    }

    func testPlanIsNilForEmptySelection() {
        XCTAssertNil(SelectionSessionPlanner.plan(recordings: [], phase: .capacity, timeZone: utc))
    }

    func testPlanIgnoresExistingGroupIDs() {
        // An orphan recording (stale group id, no session) is still selected
        // and must move under the new session — the web overwrites group_id
        // for exactly this shape.
        let orphanGroup = UUID()
        let recording = recording(
            id: "00000000-0000-0000-0000-00000000000A",
            at: 0,
            groupID: orphanGroup
        )
        let plan = SelectionSessionPlanner.plan(recordings: [recording], phase: .capacity, timeZone: utc)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.recordingIDs, [recording.id])
    }
}
