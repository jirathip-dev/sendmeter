import XCTest
@testable import SendmeterCore

final class HistoryFiltersTests: XCTestCase {
    private func session(
        id: String,
        date: String = "2026-08-10",
        type: String = "gym",
        typeLabel: String = "Gym Session",
        groupID: UUID? = nil
    ) -> Session {
        Session(
            id: UUID(uuidString: id)!,
            date: date,
            type: type,
            typeLabel: typeLabel,
            durationMinutes: 60,
            rpe: 6,
            note: "",
            phase: .capacity,
            groupID: groupID
        )
    }

    private func recording(
        id: String,
        tag: String = "",
        groupID: UUID? = nil
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 10_000,
            peakKilograms: 20,
            averageKilograms: 18,
            sampleCount: 10,
            note: "",
            tag: tag,
            side: .unspecified,
            groupID: groupID
        )
    }

    // MARK: Options

    func testOptionsTypesComeFromSessionsDeduplicated() {
        let group = UUID()
        let options = HistoryFilters.options(
            sessions: [
                session(id: "00000000-0000-0000-0000-00000000000A", type: "gym", typeLabel: "Gym Session"),
                session(id: "00000000-0000-0000-0000-00000000000B", type: "gym", typeLabel: "Gym Session"),
                session(id: "00000000-0000-0000-0000-00000000000C", type: "tindeq", typeLabel: "Tindeq", groupID: group),
            ],
            looseRecordings: [],
            groupedRecordings: [],
            selectedType: nil,
            selectedTag: nil
        )
        XCTAssertEqual(options.types.map(\.id), ["gym", "tindeq"])
    }

    func testOptionsAddTindeqTypeWhenOnlyLooseRecordingsExist() {
        let options = HistoryFilters.options(
            sessions: [],
            looseRecordings: [recording(id: "00000000-0000-0000-0000-00000000000A", tag: "Crimps")],
            groupedRecordings: [],
            selectedType: nil,
            selectedTag: nil
        )
        XCTAssertEqual(options.types.map(\.id), ["tindeq"])
        XCTAssertEqual(options.types.first?.label, "Tindeq")
    }

    func testOptionsDoNotDuplicateTindeqTypeWhenTindeqSessionExists() {
        let group = UUID()
        let options = HistoryFilters.options(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", type: "tindeq", typeLabel: "Tindeq", groupID: group)],
            looseRecordings: [recording(id: "00000000-0000-0000-0000-00000000000B")],
            groupedRecordings: [],
            selectedType: nil,
            selectedTag: nil
        )
        XCTAssertEqual(options.types.map(\.id), ["tindeq"])
    }

    func testOptionsTagsComeFromLooseAndGroupedRecordingsSorted() {
        let group = UUID()
        let options = HistoryFilters.options(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", groupID: group)],
            looseRecordings: [
                recording(id: "00000000-0000-0000-0000-00000000000B", tag: "Hangboard"),
                recording(id: "00000000-0000-0000-0000-00000000000C", tag: ""),
            ],
            groupedRecordings: [recording(id: "00000000-0000-0000-0000-00000000000D", tag: "Crimps", groupID: group)],
            selectedType: nil,
            selectedTag: nil
        )
        XCTAssertEqual(options.tags, ["Crimps", "Hangboard"])
    }

    func testOptionsExcludeHiddenTagsFromLooseAndGroupedRecordings() {
        let group = UUID()
        let options = HistoryFilters.options(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", type: "tindeq", typeLabel: "Tindeq", groupID: group)],
            looseRecordings: [
                recording(id: "00000000-0000-0000-0000-00000000000B", tag: "Crimps"),
                recording(id: "00000000-0000-0000-0000-00000000000C", tag: "Pinch"),
            ],
            groupedRecordings: [
                recording(id: "00000000-0000-0000-0000-00000000000D", tag: "Hangboard", groupID: group),
                recording(id: "00000000-0000-0000-0000-00000000000E", tag: "Slopers", groupID: group),
            ],
            selectedType: nil,
            selectedTag: "Pinch",
            hiddenTagNames: ["Pinch", "Slopers"]
        )

        XCTAssertEqual(options.tags, ["Crimps", "Hangboard"])
        XCTAssertNil(options.activeTag)
    }

    func testRecordingQueryKeepsHiddenTaggedLooseAndGroupedRecordingsVisible() {
        let group = UUID()
        let loose = recording(
            id: "00000000-0000-0000-0000-00000000000A",
            tag: "Pinch"
        )
        let grouped = recording(
            id: "00000000-0000-0000-0000-00000000000B",
            tag: "Pinch",
            groupID: group
        )

        XCTAssertEqual(
            HistoryFilters.recordingsMatchingQuery([loose, grouped], query: "").map(\.id),
            [loose.id, grouped.id]
        )
        XCTAssertEqual(
            HistoryFilters.recordingsMatchingQuery([loose, grouped], query: "pinch").map(\.id),
            [loose.id, grouped.id]
        )
    }

    func testOptionsCoerceStaleSelectionsToNil() {
        let options = HistoryFilters.options(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A")],
            looseRecordings: [],
            groupedRecordings: [],
            selectedType: "board",
            selectedTag: "Crimps"
        )
        XCTAssertNil(options.activeType)
        XCTAssertNil(options.activeTag)
    }

    func testOptionsKeepValidSelections() {
        let group = UUID()
        let options = HistoryFilters.options(
            sessions: [session(id: "00000000-0000-0000-0000-00000000000A", type: "board", typeLabel: "Board Climbing")],
            looseRecordings: [recording(id: "00000000-0000-0000-0000-00000000000B", tag: "Crimps")],
            groupedRecordings: [recording(id: "00000000-0000-0000-0000-00000000000C", tag: "Crimps", groupID: group)],
            selectedType: "board",
            selectedTag: "Crimps"
        )
        XCTAssertEqual(options.activeType, "board")
        XCTAssertEqual(options.activeTag, "Crimps")
    }

    // MARK: Matching

    func testSessionMatchesTypeFilter() {
        let group = UUID()
        let session = session(id: "00000000-0000-0000-0000-00000000000A", type: "board", groupID: group)
        let recordings = [recording(id: "00000000-0000-0000-0000-00000000000B", tag: "Crimps", groupID: group)]

        XCTAssertTrue(HistoryFilters.sessionMatches(session, groupRecordings: recordings, type: "board", tag: nil))
        XCTAssertFalse(HistoryFilters.sessionMatches(session, groupRecordings: recordings, type: "gym", tag: nil))
        XCTAssertTrue(HistoryFilters.sessionMatches(session, groupRecordings: recordings, type: nil, tag: nil))
    }

    func testSessionMatchesTagFilterViaItsGroupRecordings() {
        let group = UUID()
        let session = session(id: "00000000-0000-0000-0000-00000000000A", type: "tindeq", groupID: group)
        let recordings = [
            recording(id: "00000000-0000-0000-0000-00000000000B", tag: "Crimps", groupID: group),
            recording(id: "00000000-0000-0000-0000-00000000000C", tag: "Hangboard", groupID: group),
        ]

        XCTAssertTrue(HistoryFilters.sessionMatches(session, groupRecordings: recordings, type: nil, tag: "Crimps"))
        XCTAssertFalse(HistoryFilters.sessionMatches(session, groupRecordings: recordings, type: nil, tag: "Slopers"))
    }

    func testSessionWithoutGroupNeverMatchesTagFilter() {
        let session = session(id: "00000000-0000-0000-0000-00000000000A")
        XCTAssertFalse(HistoryFilters.sessionMatches(session, groupRecordings: [], type: nil, tag: "Crimps"))
        XCTAssertTrue(HistoryFilters.sessionMatches(session, groupRecordings: [], type: nil, tag: nil))
    }

    func testLooseRecordingMatchesTindeqTypeOnly() {
        let recording = recording(id: "00000000-0000-0000-0000-00000000000A", tag: "Crimps")
        XCTAssertTrue(HistoryFilters.looseRecordingMatches(recording, type: nil, tag: nil))
        XCTAssertTrue(HistoryFilters.looseRecordingMatches(recording, type: "tindeq", tag: nil))
        XCTAssertFalse(HistoryFilters.looseRecordingMatches(recording, type: "board", tag: nil))
        XCTAssertTrue(HistoryFilters.looseRecordingMatches(recording, type: nil, tag: "Crimps"))
        XCTAssertFalse(HistoryFilters.looseRecordingMatches(recording, type: nil, tag: "Hangboard"))
    }

    // MARK: Selection pruning

    func testPruneSelectionKeepsOnlyStillVisibleRecordings() {
        let visible = [
            recording(id: "00000000-0000-0000-0000-00000000000A", tag: "Crimps"),
            recording(id: "00000000-0000-0000-0000-00000000000B", tag: "Hangboard"),
        ]
        let hidden = recording(id: "00000000-0000-0000-0000-00000000000C", tag: "Slopers")
        let selected: Set<UUID> = [visible[0].id, visible[1].id, hidden.id]

        let pruned = HistoryFilters.pruneSelection(selected, toVisible: visible + [hidden], type: nil, tag: "Crimps")
        XCTAssertEqual(pruned, [visible[0].id])
    }

    func testPruneSelectionIsIdentityForEmptySelection() {
        let recordings = [recording(id: "00000000-0000-0000-0000-00000000000A", tag: "Crimps")]
        let pruned = HistoryFilters.pruneSelection([], toVisible: recordings, type: nil, tag: nil)
        XCTAssertTrue(pruned.isEmpty)
    }
}
