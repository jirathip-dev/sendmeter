import XCTest
@testable import SendmeterCore

final class TindeqConsistencyTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    private var referenceDate: Date {
        LocalDateSupport.date(from: "2026-08-20", timeZone: timeZone)!
            .addingTimeInterval(12 * 60 * 60)
    }

    private func recording(
        _ day: String,
        tag: String,
        hour: Int = 12
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(),
            recordedAt: LocalDateSupport.date(from: day, timeZone: timeZone)!
                .addingTimeInterval(Double(hour) * 60 * 60),
            durationMilliseconds: 5_000,
            peakKilograms: 30,
            averageKilograms: 24,
            sampleCount: 50,
            note: "",
            tag: tag,
            side: .unspecified,
            groupID: nil
        )
    }

    private func compute(
        _ recordings: [TindeqRecording],
        hiddenTags: Set<String> = []
    ) -> TindeqConsistency.Snapshot {
        TindeqConsistency.compute(
            recordings: recordings,
            hiddenTags: hiddenTags,
            now: referenceDate,
            timeZone: timeZone
        )
    }

    func testEmptyInputReturnsEightLabeledZeroWindows() {
        let snapshot = compute([])

        XCTAssertEqual(
            snapshot.weeks.map(\.label),
            ["7w", "6w", "5w", "4w", "3w", "2w", "1w", "Now"]
        )
        XCTAssertEqual(snapshot.weeks.count, 8)
        XCTAssertTrue(snapshot.weeks.allSatisfy { $0.days == 0 && $0.byTag.isEmpty })
        XCTAssertEqual(snapshot.tags, [])
        XCTAssertFalse(snapshot.hasRecordings)
    }

    func testMultipleRecordingsOnOneDayCountOnceAndTagsCountIndependently() {
        let snapshot = compute([
            recording("2026-08-20", tag: "FDP", hour: 9),
            recording("2026-08-20", tag: "FDP", hour: 10),
            recording("2026-08-20", tag: "Pinch", hour: 11)
        ])

        let now = try! XCTUnwrap(snapshot.weeks.last)
        XCTAssertEqual(now.days, 1)
        XCTAssertEqual(now.byTag, ["FDP": 1, "Pinch": 1])
        XCTAssertEqual(snapshot.tags, ["FDP", "Pinch"])
    }

    func testSevenDaysAgoStartsThePriorWindow() {
        let snapshot = compute([
            recording("2026-08-14", tag: "FDP"), // six days ago: Now
            recording("2026-08-13", tag: "FDP")  // seven days ago: 1w
        ])

        XCTAssertEqual(snapshot.weeks.first { $0.label == "Now" }?.days, 1)
        XCTAssertEqual(snapshot.weeks.first { $0.label == "1w" }?.days, 1)
        XCTAssertEqual(snapshot.weeks.first { $0.label == "2w" }?.days, 0)
    }

    func testOldAndFutureRecordingsDoNotEnterTheEightWeekWindow() {
        let snapshot = compute([
            recording("2026-06-21", tag: "Old"), // sixty days ago
            recording("2026-08-21", tag: "Future")
        ])

        XCTAssertFalse(snapshot.hasRecordings)
        XCTAssertEqual(snapshot.tags, [])
    }

    func testRecordingUsesItsLocalGregorianDay() {
        let bangkok = TimeZone(identifier: "Asia/Bangkok")!
        let now = LocalDateSupport.iso8601Date(from: "2026-08-20T12:00:00Z")!
        let lateUtc = LocalDateSupport.iso8601Date(from: "2026-08-19T17:30:00Z")!
        let recording = TindeqRecording(
            id: UUID(),
            recordedAt: lateUtc,
            durationMilliseconds: 1_000,
            peakKilograms: nil,
            averageKilograms: nil,
            sampleCount: 1,
            note: "",
            tag: "FDP",
            side: .unspecified,
            groupID: nil
        )

        let snapshot = TindeqConsistency.compute(
            recordings: [recording],
            hiddenTags: [],
            now: now,
            timeZone: bangkok
        )

        XCTAssertEqual(snapshot.weeks.last?.label, "Now")
        XCTAssertEqual(snapshot.weeks.last?.days, 1)
    }

    func testHiddenTagsAreExcludedFromDaysByTagAndChips() {
        let snapshot = compute([
            recording("2026-08-20", tag: "FDP"),
            recording("2026-08-20", tag: "Hidden")
        ], hiddenTags: ["Hidden"])

        XCTAssertEqual(snapshot.weeks.last?.days, 1)
        XCTAssertEqual(snapshot.weeks.last?.byTag, ["FDP": 1])
        XCTAssertEqual(snapshot.tags, ["FDP"])
    }

    func testTagsOnlyUseTheWindowAndSortAlphabetically() {
        let snapshot = compute([
            recording("2026-06-21", tag: "Old"),
            recording("2026-08-20", tag: "zeta"),
            recording("2026-08-19", tag: "Alpha"),
            recording("2026-08-18", tag: "beta")
        ])

        XCTAssertEqual(snapshot.tags, ["Alpha", "beta", "zeta"])
    }

    func testSelectedTagNarrowsTheSameBarsInsteadOfStacking() {
        let week = TindeqConsistency.Week(
            label: "Now",
            days: 3,
            byTag: ["FDP": 1, "Pinch": 2]
        )

        XCTAssertEqual(TindeqConsistency.selectedTagDays(for: week, selectedTag: nil), 3)
        XCTAssertEqual(TindeqConsistency.selectedTagDays(for: week, selectedTag: "FDP"), 1)
        XCTAssertEqual(TindeqConsistency.selectedTagDays(for: week, selectedTag: "Missing"), 0)
    }

    func testAgedOutSelectionFallsBackToAll() {
        XCTAssertEqual(
            TindeqConsistency.effectiveSelectedTag("FDP", availableTags: ["Pinch"]),
            nil
        )
        XCTAssertEqual(
            TindeqConsistency.effectiveSelectedTag("FDP", availableTags: ["FDP", "Pinch"]),
            "FDP"
        )
    }
}
