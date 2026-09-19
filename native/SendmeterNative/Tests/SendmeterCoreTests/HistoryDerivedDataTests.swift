import XCTest
@testable import SendmeterCore

/// #924: the History derived-data snapshot must compute the whole-history
/// scans (group map, filter options, timeline) once per input revision and
/// reuse them — never inside a per-item loop. These are pure Core tests; the
/// view that consumes the snapshot is covered by
/// `HistoryDerivedDataWiringTests` (source invariant) and the app build.
final class HistoryDerivedDataTests: XCTestCase {
    // MARK: Fixtures

    private func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    private func session(
        _ n: Int,
        date: String = "2026-08-10",
        type: String = "gym",
        typeLabel: String = "Gym Session",
        note: String = "",
        groupID: UUID? = nil,
        pending: Bool = false
    ) -> Session {
        Session(
            id: uuid(n),
            date: date,
            type: type,
            typeLabel: typeLabel,
            durationMinutes: 60,
            rpe: 6,
            note: note,
            phase: .capacity,
            groupID: groupID,
            pending: pending
        )
    }

    private func recording(
        _ n: Int,
        at timeInterval: TimeInterval = 1_779_969_600,
        tag: String = "",
        note: String = "",
        groupID: UUID? = nil
    ) -> TindeqRecording {
        TindeqRecording(
            id: uuid(n),
            // Mid-day UTC base + minute offsets: the local calendar day is
            // 2026-05-28 in every timezone the suite can run in.
            recordedAt: Date(timeIntervalSince1970: timeInterval + Double(n * 60)),
            durationMilliseconds: 10_000,
            peakKilograms: 20,
            averageKilograms: 18,
            sampleCount: 10,
            note: note,
            tag: tag,
            side: .unspecified,
            groupID: groupID
        )
    }

    /// A fixture that exercises every branch the snapshot has to keep: grouped
    /// sessions, orphan groups, loose recordings, hidden tags, a pending
    /// session and query-matchable notes.
    private func fixture() -> (sessions: [Session], recordings: [TindeqRecording]) {
        let group = uuid(900)
        let pendingGroup = uuid(901)
        let orphanGroup = uuid(902)
        let sessions = [
            session(1, date: "2026-08-12", type: "gym", typeLabel: "Gym Session", note: "evening board"),
            session(2, date: "2026-08-11", type: "tindeq", typeLabel: "Tindeq", note: "max hangs", groupID: group),
            session(3, date: "2026-08-11", type: "board", typeLabel: "Board Climbing", note: "campus"),
            session(4, date: "2026-08-09", type: "tindeq", typeLabel: "Tindeq", note: "", groupID: pendingGroup, pending: true),
        ]
        let recordings = [
            recording(11, tag: "Crimps", groupID: group),
            recording(12, tag: "Pinch", groupID: group),
            recording(13, tag: "Crimps"),
            recording(14, tag: "Hangboard", note: "one-arm"),
            recording(15, tag: "Pinch"),
            recording(16, tag: "", note: "warmup"),
            // A gauge run never finished: stamped with a group no session
            // references, so it must surface as a loose row.
            recording(17, tag: "Slopers", groupID: orphanGroup),
        ]
        return (sessions, recordings)
    }

    private struct Scenario {
        let name: String
        var query: String = ""
        var selectedType: String?
        var selectedTag: String?
        var hiddenTagNames: Set<String> = []
    }

    private var scenarios: [Scenario] {
        [
            Scenario(name: "baseline"),
            Scenario(name: "typing-matches-a-session", query: "campus"),
            Scenario(name: "typing-matches-a-recording", query: "crimp"),
            Scenario(name: "typing-matches-nothing", query: "zzzz"),
            Scenario(name: "type-filter-gym", selectedType: "gym"),
            Scenario(name: "type-filter-tindeq", selectedType: "tindeq"),
            Scenario(name: "tag-filter-crimps", selectedTag: "Crimps"),
            Scenario(name: "tag-filter-hidden-pinch", selectedTag: "Pinch", hiddenTagNames: ["Pinch"]),
            Scenario(name: "stale-type-selection", selectedType: "slab"),
            Scenario(name: "hidden-tags-only", hiddenTagNames: ["Pinch", "Hangboard"]),
            Scenario(name: "query-plus-type-plus-tag", query: "hang", selectedType: "tindeq", selectedTag: "Crimps"),
            Scenario(name: "hidden-tag-with-query", query: "pinch", hiddenTagNames: ["Pinch"]),
        ]
    }

    // MARK: AC2 — identity/ordering equivalence with the pre-#924 chain

    func testSnapshotKeepsLegacyIdentitiesAndOrderingAcrossScenarios() {
        let (sessions, recordings) = fixture()

        for scenario in scenarios {
            let snapshot = HistoryDerivedData(
                sessions: sessions,
                recordings: recordings,
                hiddenTagNames: scenario.hiddenTagNames,
                query: scenario.query,
                selectedType: scenario.selectedType,
                selectedTag: scenario.selectedTag
            )
            let legacy = HistoryLegacyBaseline.derive(
                sessions: sessions,
                recordings: recordings,
                hiddenTagNames: scenario.hiddenTagNames,
                query: scenario.query,
                selectedType: scenario.selectedType,
                selectedTag: scenario.selectedTag
            )

            XCTAssertEqual(
                snapshot.timelineItems.map(\.id), legacy.timeline.map(\.id),
                "\(scenario.name): All-mode timeline identity/order"
            )
            XCTAssertEqual(
                snapshot.filteredSessions.map(\.id), legacy.sessions.map(\.id),
                "\(scenario.name): Sessions list identity/order"
            )
            XCTAssertEqual(
                snapshot.filteredLooseRecordings.map(\.id), legacy.loose.map(\.id),
                "\(scenario.name): loose recording identity/order"
            )
            XCTAssertEqual(
                snapshot.filteredForceRecordings.map(\.id), legacy.force.map(\.id),
                "\(scenario.name): Force-mode list identity/order"
            )
            XCTAssertEqual(snapshot.options, legacy.options, "\(scenario.name): filter chips")
        }
    }

    func testSnapshotKeepsAbsoluteBaselineOrderingIncludingHiddenTags() {
        let (sessions, recordings) = fixture()

        // Baseline All-mode timeline: the 2026-08 sessions by day (descending,
        // same-day sessions in input order) then the 2026-05-28 loose
        // recordings in input order. The grouped recordings (11, 12) are
        // represented by their session; the orphan-group one (17) is loose.
        let plain = HistoryDerivedData(sessions: sessions, recordings: recordings)
        XCTAssertEqual(plain.timelineItems.map(\.id), [
            "s-\(uuid(1).uuidString)",
            "s-\(uuid(2).uuidString)",
            "s-\(uuid(3).uuidString)",
            "s-\(uuid(4).uuidString)",
            "r-\(uuid(13).uuidString)",
            "r-\(uuid(14).uuidString)",
            "r-\(uuid(15).uuidString)",
            "r-\(uuid(16).uuidString)",
            "r-\(uuid(17).uuidString)",
        ])
        XCTAssertEqual(plain.filteredSessions.map(\.id), [uuid(1), uuid(2), uuid(3), uuid(4)])

        // Hiding a tag drops its chip but never its rows.
        let hidden = HistoryDerivedData(
            sessions: sessions,
            recordings: recordings,
            hiddenTagNames: ["Pinch"]
        )
        XCTAssertFalse(hidden.options.tags.contains("Pinch"))
        XCTAssertEqual(hidden.timelineItems.map(\.id), plain.timelineItems.map(\.id))
        XCTAssertEqual(hidden.filteredForceRecordings.count, plain.filteredForceRecordings.count)
        XCTAssertTrue(hidden.timelineItems.contains { $0.id == "r-\(uuid(15).uuidString)" })

        // A hidden tag that is still selected coerces to nil (web parity).
        XCTAssertNil(
            HistoryDerivedData(
                sessions: sessions,
                recordings: recordings,
                hiddenTagNames: ["Pinch"],
                selectedTag: "Pinch"
            ).options.activeTag
        )
    }

    func testSnapshotKeepsPendingSessionOutOfAssignCandidatesButInTheList() {
        let (sessions, recordings) = fixture()
        let snapshot = HistoryDerivedData(sessions: sessions, recordings: recordings)

        XCTAssertEqual(snapshot.tindeqSessions.map(\.id), [uuid(2)])
        XCTAssertTrue(snapshot.filteredSessions.map(\.id).contains(uuid(4)))
    }

    func testSnapshotKeepsOrphanGroupRecordingLooseAndZoneLookupGrouped() {
        let (sessions, recordings) = fixture()
        let snapshot = HistoryDerivedData(sessions: sessions, recordings: recordings)

        // The group map keeps every group a recording carries (the session
        // row's zone lookup needs it), while only the sessions' own groups
        // decide the loose/grouped split for rows.
        XCTAssertEqual(snapshot.recordingsByGroup[uuid(900)]?.map(\.id), [uuid(11), uuid(12)])
        XCTAssertEqual(snapshot.recordingsByGroup[uuid(902)]?.map(\.id), [uuid(17)])
        XCTAssertEqual(snapshot.sessionGroupIDs, [uuid(900), uuid(901)])
        XCTAssertEqual(
            snapshot.filteredLooseRecordings.map(\.id),
            [uuid(13), uuid(14), uuid(15), uuid(16), uuid(17)]
        )
    }

    // MARK: AC1 — call counts

    func testWholeHistoryScansRunOncePerSnapshotBuild() {
        let (sessions, recordings) = fixture()

        HistoryScanCounter.reset()
        let snapshot = HistoryDerivedData(sessions: sessions, recordings: recordings)

        // One build: one group-map build, one options pass, one timeline sort.
        // `looseRecordings` is 3 by construction — the snapshot's own pass, the
        // one for the filtered loose rows, plus the one `combinedItems`
        // re-runs over the already-loose list (all bounded per revision).
        XCTAssertEqual(HistoryScanCounter.count(.derivedData), 1)
        XCTAssertEqual(HistoryScanCounter.count(.filterOptions), 1)
        XCTAssertEqual(HistoryScanCounter.count(.looseRecordings), 3)
        XCTAssertEqual(HistoryScanCounter.count(.combinedItems), 1)

        // Walking the snapshot the way the rows/predicates do adds no scan.
        var visited = 0
        for item in snapshot.timelineItems {
            _ = item.id
            _ = item.date
            visited += 1
        }
        for session in snapshot.filteredSessions {
            _ = session.groupID.flatMap { snapshot.recordingsByGroup[$0] }
            _ = snapshot.sessionGroupIDs
        }
        for recording in snapshot.filteredForceRecordings {
            _ = snapshot.sessionGroupIDs.contains(recording.groupID ?? recording.id)
        }
        for session in snapshot.tindeqSessions { _ = session.id }
        for recording in snapshot.filteredLooseRecordings { _ = recording.id }
        XCTAssertEqual(visited, snapshot.timelineItems.count)

        XCTAssertEqual(HistoryScanCounter.count(.derivedData), 1)
        XCTAssertEqual(HistoryScanCounter.count(.filterOptions), 1)
        XCTAssertEqual(HistoryScanCounter.count(.looseRecordings), 3)
        XCTAssertEqual(HistoryScanCounter.count(.combinedItems), 1)
    }

    func testWholeHistoryScanCountDoesNotScaleWithItemCount() {
        // A per-item rescan would make the count grow with the dataset; the
        // snapshot must stay flat at one scan per revision.
        for size in [3, 40] {
            let sessions = (1...size).map { n in
                session(n, type: n % 2 == 0 ? "gym" : "tindeq", groupID: n % 3 == 0 ? uuid(500 + n) : nil)
            }
            let recordings = (1...(size * 2)).map { n in
                recording(1_000 + n, tag: n % 3 == 0 ? "Crimps" : "Hangboard", groupID: n % 3 == 0 ? uuid(500 + n) : nil)
            }

            HistoryScanCounter.reset()
            _ = HistoryDerivedData(sessions: sessions, recordings: recordings)

            XCTAssertEqual(HistoryScanCounter.count(.filterOptions), 1, "size \(size)")
            XCTAssertEqual(HistoryScanCounter.count(.derivedData), 1, "size \(size)")
            XCTAssertEqual(HistoryScanCounter.count(.combinedItems), 1, "size \(size)")
        }
    }

    func testCounterCatchesTheLegacyInLoopScanShape() {
        // Discrimination probe for the instrument itself: the pre-#924 shape
        // re-enters the whole-history scans per item, so a call-count test
        // WOULD fail if that shape returned (the RED leg in the report).
        let (sessions, recordings) = fixture()

        HistoryScanCounter.reset()
        _ = HistoryLegacyBaseline.derive(
            sessions: sessions,
            recordings: recordings,
            hiddenTagNames: [],
            query: "",
            selectedType: nil,
            selectedTag: nil
        )

        XCTAssertGreaterThan(HistoryScanCounter.count(.filterOptions), sessions.count + recordings.count)
        XCTAssertGreaterThan(HistoryScanCounter.count(.looseRecordings), sessions.count)
    }

    // MARK: AC2/AC3 — cache invalidation and paging

    func testCacheRebuildsOnlyWhenARelevantInputChanges() {
        let (sessions, recordings) = fixture()
        let cache = HistoryDerivedDataCache()

        func read(
            sessions: [Session],
            recordings: [TindeqRecording],
            hiddenTagNames: Set<String> = [],
            query: String = "",
            selectedType: String? = nil,
            selectedTag: String? = nil
        ) -> HistoryDerivedData {
            cache.data(
                sessions: sessions,
                recordings: recordings,
                hiddenTagNames: hiddenTagNames,
                query: query,
                selectedType: selectedType,
                selectedTag: selectedTag
            )
        }

        let first = read(sessions: sessions, recordings: recordings)
        XCTAssertEqual(cache.buildCount, 1)

        // Same revision (every body evaluation, every page growth).
        for _ in 0..<5 {
            XCTAssertEqual(read(sessions: sessions, recordings: recordings), first)
        }
        XCTAssertEqual(cache.buildCount, 1)

        var changedSessions = sessions
        changedSessions[0].note = "edited"
        _ = read(sessions: changedSessions, recordings: recordings)
        XCTAssertEqual(cache.buildCount, 2, "a session edit must invalidate")

        var changedRecordings = recordings
        changedRecordings[0].tag = "Slopers"
        _ = read(sessions: sessions, recordings: changedRecordings)
        XCTAssertEqual(cache.buildCount, 3, "a recording edit must invalidate")

        _ = read(sessions: sessions, recordings: recordings, hiddenTagNames: ["Pinch"])
        XCTAssertEqual(cache.buildCount, 4, "a tag-hiding change must invalidate")

        _ = read(sessions: sessions, recordings: recordings, query: "crimp")
        XCTAssertEqual(cache.buildCount, 5, "typing must invalidate")

        _ = read(sessions: sessions, recordings: recordings, selectedType: "gym")
        XCTAssertEqual(cache.buildCount, 6, "a type selection must invalidate")

        _ = read(sessions: sessions, recordings: recordings, selectedTag: "Crimps")
        XCTAssertEqual(cache.buildCount, 7, "a tag selection must invalidate")

        // Back to the first revision: the cache holds one revision, so this is
        // a rebuild (never a stale snapshot).
        _ = read(sessions: sessions, recordings: recordings)
        XCTAssertEqual(cache.buildCount, 8)
    }

    func testPageGrowthDoesNotRebuildOrRescanTheSnapshot() {
        let (sessions, recordings) = fixture()
        let cache = HistoryDerivedDataCache()

        HistoryScanCounter.reset()
        let data = cache.data(sessions: sessions, recordings: recordings)
        let scansAfterBuild = HistoryScanCounter.Scan.allCases.map { HistoryScanCounter.count($0) }

        // Growing the visible page only slices the cached snapshot (the view
        // pages with `prefix(visibleCount)`; paging is not an input revision).
        for page in [40, 80, 120] {
            _ = Array(data.timelineItems.prefix(page))
            _ = Array(data.filteredForceRecordings.prefix(page))
            _ = Array(data.filteredSessions.prefix(page))
        }

        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(
            HistoryScanCounter.Scan.allCases.map { HistoryScanCounter.count($0) },
            scansAfterBuild
        )
    }
}
