import XCTest
@testable import SendmeterCore

final class HistoryTimelineTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func session(
        id: String,
        date: String,
        type: String = "gym",
        groupID: UUID? = nil
    ) -> Session {
        Session(
            id: UUID(uuidString: id)!,
            date: date,
            type: type,
            typeLabel: type == "tindeq" ? "Tindeq" : "Gym Session",
            durationMinutes: 60,
            rpe: 6,
            note: "",
            phase: .capacity,
            groupID: groupID
        )
    }

    private func recording(
        id: String,
        at timeInterval: TimeInterval,
        durationMs: Int = 10_000,
        tag: String = "",
        side: TindeqSide = .unspecified,
        groupID: UUID? = nil
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: Date(timeIntervalSince1970: timeInterval),
            durationMilliseconds: durationMs,
            peakKilograms: 20,
            averageKilograms: 18,
            sampleCount: 10,
            note: "",
            tag: tag,
            side: side,
            groupID: groupID
        )
    }

    private func recordingDay(_ timeInterval: TimeInterval) -> String {
        LocalDateSupport.string(from: Date(timeIntervalSince1970: timeInterval), timeZone: utc)
    }

    // MARK: Ordering

    func testSameDaySessionsSortBeforeLooseRecordings() {
        // One recording and one session on the same day: the session must
        // come first, exactly like the web's `sortKey` (`~1` vs `~0`).
        let day = recordingDay(0)
        let items = HistoryTimeline.combinedItems(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", date: day)],
            recordings: [recording(id: "00000000-0000-0000-0000-00000000000B", at: 3_600)],
            timeZone: utc
        )
        XCTAssertEqual(items.map(\.id), [
            "s-00000000-0000-0000-0000-00000000000A",
            "r-00000000-0000-0000-0000-00000000000B",
        ])
    }

    func testDaysSortDescendingRegardlessOfKind() {
        let older = recordingDay(0)
        let items = HistoryTimeline.combinedItems(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", date: older)],
            recordings: [recording(id: "00000000-0000-0000-0000-00000000000B", at: 2 * 86_400 + 3_600)],
            timeZone: utc
        )
        // The recording is a day newer than the session, so it goes first.
        XCTAssertEqual(items.map(\.id), [
            "r-00000000-0000-0000-0000-00000000000B",
            "s-00000000-0000-0000-0000-00000000000A",
        ])
    }

    func testRecordingsKeepInputOrderWithinDay() {
        let day = recordingDay(0)
        let items = HistoryTimeline.combinedItems(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", date: day)],
            recordings: [
                recording(id: "00000000-0000-0000-0000-00000000000B", at: 1_000),
                recording(id: "00000000-0000-0000-0000-00000000000C", at: 2_000),
            ],
            timeZone: utc
        )
        XCTAssertEqual(items.map(\.id), [
            "s-00000000-0000-0000-0000-00000000000A",
            "r-00000000-0000-0000-0000-00000000000B",
            "r-00000000-0000-0000-0000-00000000000C",
        ])
    }

    func testSessionsKeepInputOrderWithinDay() {
        let day = recordingDay(0)
        let items = HistoryTimeline.combinedItems(
            sessions: [
                session(id: "00000000-0000-0000-0000-00000000000A", date: day),
                session(id: "00000000-0000-0000-0000-00000000000C", date: day),
            ],
            recordings: [],
            timeZone: utc
        )
        XCTAssertEqual(items.map(\.id), [
            "s-00000000-0000-0000-0000-00000000000A",
            "s-00000000-0000-0000-0000-00000000000C",
        ])
    }

    // MARK: Loose / grouped classification

    func testGroupedRecordingsAreExcludedFromCombined() {
        let day = recordingDay(0)
        let group = UUID()
        let items = HistoryTimeline.combinedItems(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", date: day, type: "tindeq", groupID: group)],
            recordings: [
                recording(id: "00000000-0000-0000-0000-00000000000B", at: 1_000, groupID: group),
                recording(id: "00000000-0000-0000-0000-00000000000C", at: 2_000),
            ],
            timeZone: utc
        )
        // Only the session + the loose recording; the grouped one is hidden.
        XCTAssertEqual(items.map(\.id), [
            "s-00000000-0000-0000-0000-00000000000A",
            "r-00000000-0000-0000-0000-00000000000C",
        ])
    }

    func testOrphanGroupedRecordingIsTreatedAsLoose() {
        // The "PR missing from History" bug: a recording stamped with a group
        // no session references (gauge run never finished) must surface as a
        // loose row, not vanish.
        let day = recordingDay(0)
        let orphanGroup = UUID()
        let items = HistoryTimeline.combinedItems(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", date: day)],
            recordings: [recording(id: "00000000-0000-0000-0000-00000000000B", at: 1_000, groupID: orphanGroup)],
            timeZone: utc
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1].id, "r-00000000-0000-0000-0000-00000000000B")
    }

    func testLooseRecordingsIncludesUngrouped() {
        let group = UUID()
        let recordings = [
            recording(id: "00000000-0000-0000-0000-00000000000B", at: 1_000, groupID: nil),
            recording(id: "00000000-0000-0000-0000-00000000000C", at: 2_000, groupID: group),
        ]
        let sessions = [session(id: "00000000-0000-0000-0000-00000000000A", date: recordingDay(0), groupID: group)]
        let loose = HistoryTimeline.looseRecordings(recordings, in: sessions)
        XCTAssertEqual(loose.map(\.id), [recordings[0].id])
    }

    // MARK: Item date bucketing

    func testRecordingBucketsByRecordedDay() {
        let item = HistoryTimelineItem.recording(
            recording(id: "00000000-0000-0000-0000-00000000000B", at: 86_400 + 3_600)
        )
        XCTAssertEqual(item.date, recordingDay(86_400 + 3_600))
    }
}
