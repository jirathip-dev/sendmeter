import Foundation
import XCTest
@testable import SendmeterCore

/// #924 AC4: a deterministic small/large dataset benchmark that records the
/// grouping (group-map) count, the whole-history filter work and the elapsed
/// wall time across typing / filter / mode changes — the pre-#924 chain
/// against the snapshot.
///
/// This measures the pure derived-data work on this host; it is NOT a device
/// speedup claim. Timing is reported, never asserted (host load varies); the
/// scan-count columns are deterministic and asserted.
final class HistoryDerivedDataBenchmarkTests: XCTestCase {
    // MARK: Deterministic datasets

    private struct LCG {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private struct Dataset {
        let name: String
        let sessions: [Session]
        let recordings: [TindeqRecording]
    }

    private func dataset(name: String, sessionCount: Int, recordingCount: Int, seed: UInt64) -> Dataset {
        var rng = LCG(state: seed)
        let tags = ["Crimps", "Hangboard", "Pinch", "Slopers", ""]
        let types = [("gym", "Gym Session"), ("tindeq", "Tindeq"), ("board", "Board Climbing")]
        let groupCount = max(1, sessionCount / 4)
        let groups = (0..<groupCount).map { n in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 700_000 + n))!
        }

        let sessions = (0..<sessionCount).map { n -> Session in
            makeSession(n: n, type: types[rng.next(types.count)], groups: groups)
        }
        let recordings = (0..<recordingCount).map { n -> TindeqRecording in
            makeRecording(n: n, tag: tags[rng.next(tags.count)], groups: groups)
        }
        return Dataset(name: name, sessions: sessions, recordings: recordings)
    }

    private func makeSession(n: Int, type: (String, String), groups: [UUID]) -> Session {
        let day = 1 + (n % 28)
        let month = 1 + (n % 8)
        let groupCount = groups.count
        let note = n % 5 == 0 ? "note \(n)" : ""
        return Session(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!,
            date: String(format: "2026-%02d-%02d", month, day),
            type: type.0,
            typeLabel: type.1,
            durationMinutes: 60,
            rpe: 6,
            note: note,
            phase: .capacity,
            groupID: n % 4 == 0 ? groups[n % groupCount] : nil,
            pending: n % 17 == 0
        )
    }

    private func makeRecording(n: Int, tag: String, groups: [UUID]) -> TindeqRecording {
        let groupCount = groups.count
        let note = n % 7 == 0 ? "warmup \(n)" : ""
        return TindeqRecording(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012X", n))!,
            recordedAt: Date(timeIntervalSince1970: 1_779_969_600 + Double(n * 60)),
            durationMilliseconds: 10_000,
            peakKilograms: 20,
            averageKilograms: 18,
            sampleCount: 10,
            note: note,
            tag: tag,
            side: .unspecified,
            groupID: n % 5 == 0 ? groups[n % groupCount] : nil
        )
    }

    // MARK: Harness

    private struct Sample {
        let label: String
        let legacyMilliseconds: Double
        let snapshotMilliseconds: Double
        let legacyGroupMapBuilds: Int
        let snapshotBuilds: Int
        let legacyFilterOptions: Int
        let snapshotFilterOptions: Int
        let legacyLooseScans: Int
        let snapshotLooseScans: Int
        let legacyCombinedScans: Int
        let snapshotCombinedScans: Int
    }

    private func totalScans() -> Int {
        HistoryScanCounter.Scan.allCases.reduce(0) { $0 + HistoryScanCounter.count($1) }
    }

    private func medianMilliseconds(repetitions: Int, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<repetitions {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    /// One screen evaluation on the snapshot side: build (or re-read) the
    /// revision and walk the rows exactly like `HistoryView` does.
    @discardableResult
    private func snapshotScreen(
        cache: HistoryDerivedDataCache,
        dataset: Dataset,
        query: String,
        selectedType: String?,
        selectedTag: String?,
        page: Int
    ) -> HistoryDerivedData {
        let data = cache.data(
            sessions: dataset.sessions,
            recordings: dataset.recordings,
            query: query,
            selectedType: selectedType,
            selectedTag: selectedTag
        )
        var visited = 0
        for session in data.filteredSessions {
            _ = session.groupID.flatMap { data.recordingsByGroup[$0] }
            visited += 1
        }
        for recording in data.filteredForceRecordings {
            _ = data.sessionGroupIDs.contains(recording.groupID ?? recording.id)
            visited += 1
        }
        _ = Array(data.timelineItems.prefix(page))
        _ = visited
        return data
    }

    private func sample(
        label: String,
        dataset: Dataset,
        query: String = "",
        selectedType: String? = nil,
        selectedTag: String? = nil,
        reusesRevision: Bool = false,
        repetitions: Int = 3
    ) -> Sample {
        // Deterministic counts: one cold evaluation per side.
        HistoryScanCounter.reset()
        let legacy = HistoryLegacyBaseline.derive(
            sessions: dataset.sessions,
            recordings: dataset.recordings,
            query: query,
            selectedType: selectedType,
            selectedTag: selectedTag
        )
        let legacyTotalScans = totalScans()
        let legacyFilterOptions = HistoryScanCounter.count(.filterOptions)
        let legacyLoose = HistoryScanCounter.count(.looseRecordings)
        let legacyCombined = HistoryScanCounter.count(.combinedItems)

        let coldCache = HistoryDerivedDataCache()
        HistoryScanCounter.reset()
        let coldData = snapshotScreen(
            cache: coldCache,
            dataset: dataset,
            query: query,
            selectedType: selectedType,
            selectedTag: selectedTag,
            page: 40
        )
        let coldBuildScans = totalScans()
        let coldFilterOptions = HistoryScanCounter.count(.filterOptions)
        let coldLoose = HistoryScanCounter.count(.looseRecordings)
        let coldCombined = HistoryScanCounter.count(.combinedItems)

        // Same-revision re-read (mode switch / page growth): no rebuild.
        HistoryScanCounter.reset()
        snapshotScreen(
            cache: coldCache,
            dataset: dataset,
            query: query,
            selectedType: selectedType,
            selectedTag: selectedTag,
            page: 80
        )
        let rereadScans = totalScans()

        // The two sides must be the same work: identical identities/order.
        XCTAssertEqual(coldData.timelineItems.map(\.id), legacy.timeline.map(\.id), "\(label): timeline")
        XCTAssertEqual(coldData.filteredSessions.map(\.id), legacy.sessions.map(\.id), "\(label): sessions")
        XCTAssertEqual(coldData.filteredForceRecordings.map(\.id), legacy.force.map(\.id), "\(label): force")
        XCTAssertEqual(coldData.options, legacy.options, "\(label): options")
        if reusesRevision {
            XCTAssertEqual(rereadScans, 0, "\(label): a same-revision re-read must not rescan")
            XCTAssertEqual(coldCache.buildCount, 1, "\(label): a same-revision re-read must not rebuild")
        }
        // The snapshot's whole-history work is a constant per revision
        // (1 build + 1 options pass + 3 loose passes + 1 timeline sort). The
        // legacy chain scales with the item count — except when a
        // non-matching query empties every list before a predicate runs, so
        // the strict comparison only holds for the iterating scenarios.
        XCTAssertEqual(coldFilterOptions, 1, "\(label): one options pass per build")
        XCTAssertLessThanOrEqual(coldBuildScans, 6, "\(label): bounded per-revision scan count")
        if query.isEmpty && !reusesRevision {
            XCTAssertGreaterThan(
                legacyTotalScans,
                coldBuildScans,
                "\(label): the pre-#924 chain rescans inside its item loops"
            )
        }

        // Elapsed wall time, median of `repetitions` runs per side.
        let legacyMilliseconds = medianMilliseconds(repetitions: repetitions) {
            _ = HistoryLegacyBaseline.derive(
                sessions: dataset.sessions,
                recordings: dataset.recordings,
                query: query,
                selectedType: selectedType,
                selectedTag: selectedTag
            )
        }
        let snapshotMilliseconds = medianMilliseconds(repetitions: repetitions) {
            if reusesRevision {
                snapshotScreen(
                    cache: coldCache,
                    dataset: dataset,
                    query: query,
                    selectedType: selectedType,
                    selectedTag: selectedTag,
                    page: 80
                )
            } else {
                snapshotScreen(
                    cache: HistoryDerivedDataCache(),
                    dataset: dataset,
                    query: query,
                    selectedType: selectedType,
                    selectedTag: selectedTag,
                    page: 40
                )
            }
        }

        return Sample(
            label: label,
            legacyMilliseconds: legacyMilliseconds,
            snapshotMilliseconds: snapshotMilliseconds,
            legacyGroupMapBuilds: legacy.groupMapBuilds,
            // Columns describe the evaluation that was timed: a cold build for
            // the input-changing scenarios, a same-revision re-read for the
            // mode/page ones (no build, no scan).
            snapshotBuilds: reusesRevision ? 0 : coldCache.buildCount,
            legacyFilterOptions: legacyFilterOptions,
            snapshotFilterOptions: reusesRevision ? 0 : coldFilterOptions,
            legacyLooseScans: legacyLoose,
            snapshotLooseScans: reusesRevision ? 0 : coldLoose,
            legacyCombinedScans: legacyCombined,
            snapshotCombinedScans: reusesRevision ? 0 : coldCombined
        )
    }

    // MARK: The benchmark

    func testSmallAndLargeDatasetBenchmarkRecordsGroupingFilterWorkAndTime() {
        let datasets = [
            dataset(name: "small", sessionCount: 12, recordingCount: 24, seed: 42),
            dataset(name: "large", sessionCount: 240, recordingCount: 480, seed: 42),
        ]

        for data in datasets {
            let samples: [Sample] = [
                sample(label: "initial render (All, no filters)", dataset: data),
                sample(label: "typing: query \"crimp\"", dataset: data, query: "crimp"),
                sample(label: "typing: query \"zzzz\" (no match)", dataset: data, query: "zzzz"),
                sample(label: "filter change: tag \"Crimps\"", dataset: data, selectedTag: "Crimps"),
                sample(label: "filter change: type \"tindeq\"", dataset: data, selectedType: "tindeq"),
                sample(
                    label: "mode change: Sessions (same revision)",
                    dataset: data,
                    reusesRevision: true
                ),
                sample(
                    label: "page growth 40 -> 80 (same revision)",
                    dataset: data,
                    reusesRevision: true
                ),
            ]

            print("[#924 benchmark] dataset=\(data.name) sessions=\(data.sessions.count) recordings=\(data.recordings.count)")
            print("scenario | legacy ms | snapshot ms | legacy groupmaps/opts/loose/combined | snapshot builds/opts/loose/combined")
            for sample in samples {
                print(
                    String(
                        format: "%@ | %.3f | %.3f | %d/%d/%d/%d | %d/%d/%d/%d",
                        sample.label,
                        sample.legacyMilliseconds,
                        sample.snapshotMilliseconds,
                        sample.legacyGroupMapBuilds,
                        sample.legacyFilterOptions,
                        sample.legacyLooseScans,
                        sample.legacyCombinedScans,
                        sample.snapshotBuilds,
                        sample.snapshotFilterOptions,
                        sample.snapshotLooseScans,
                        sample.snapshotCombinedScans
                    )
                )
            }
        }
    }
}
