import Foundation
@testable import SendmeterCore

/// The pre-#924 `HistoryView` derived chain, reconstructed verbatim from base
/// `a5e9868`: every whole-history scan happens inside a per-item predicate,
/// and the row lookups rebuild the group map / session-group set per row.
///
/// This is the baseline the snapshot must stay identical to (the equivalence
/// tests) and the "before" side of the benchmark.
enum HistoryLegacyBaseline {
    struct Result {
        let timeline: [HistoryTimelineItem]
        let sessions: [Session]
        let loose: [TindeqRecording]
        let force: [TindeqRecording]
        let options: HistoryFilterOptions
        /// Whole-history group-map builds this evaluation performed.
        let groupMapBuilds: Int
        /// Rows visited, so the work cannot be optimized away.
        let rowsVisited: Int
    }

    static func derive(
        sessions: [Session],
        recordings: [TindeqRecording],
        hiddenTagNames: Set<String> = [],
        query: String = "",
        selectedType: String? = nil,
        selectedTag: String? = nil
    ) -> Result {
        var groupMapBuilds = 0

        func recordingsByGroup() -> [UUID: [TindeqRecording]] {
            groupMapBuilds += 1
            var result: [UUID: [TindeqRecording]] = [:]
            for recording in recordings {
                guard let groupID = recording.groupID else { continue }
                result[groupID, default: []].append(recording)
            }
            return result
        }
        func sessionGroupIDs() -> Set<UUID> {
            Set(sessions.compactMap(\.groupID))
        }
        func looseRecordings() -> [TindeqRecording] {
            HistoryTimeline.looseRecordings(recordings, in: sessions)
        }
        func filterOptions() -> HistoryFilterOptions {
            HistoryFilters.options(
                sessions: sessions,
                looseRecordings: looseRecordings(),
                groupedRecordings: recordings.filter { $0.groupID != nil },
                selectedType: selectedType,
                selectedTag: selectedTag,
                hiddenTagNames: hiddenTagNames
            )
        }
        func queryFilteredSessions() -> [Session] {
            guard !query.isEmpty else { return sessions }
            return sessions.filter {
                $0.typeLabel.localizedCaseInsensitiveContains(query)
                    || $0.note.localizedCaseInsensitiveContains(query)
                    || $0.date.localizedCaseInsensitiveContains(query)
            }
        }
        func queryFilteredRecordings() -> [TindeqRecording] {
            HistoryFilters.recordingsMatchingQuery(recordings, query: query)
        }

        let filteredSessions = queryFilteredSessions().filter { session in
            HistoryFilters.sessionMatches(
                session,
                groupRecordings: session.groupID.flatMap { recordingsByGroup()[$0] } ?? [],
                type: filterOptions().activeType,
                tag: filterOptions().activeTag
            )
        }
        let filteredLoose = HistoryTimeline.looseRecordings(queryFilteredRecordings(), in: sessions).filter {
            HistoryFilters.looseRecordingMatches($0, type: filterOptions().activeType, tag: filterOptions().activeTag)
        }
        let filteredForce = queryFilteredRecordings().filter {
            HistoryFilters.looseRecordingMatches($0, type: filterOptions().activeType, tag: filterOptions().activeTag)
        }
        let timeline = HistoryTimeline.combinedItems(sessions: filteredSessions, recordings: filteredLoose)

        // Row work: the old view rebuilt the group map for every session row's
        // zone lookup and the session-group set for every recording row.
        var rowsVisited = 0
        for session in filteredSessions {
            if let groupID = session.groupID { _ = recordingsByGroup()[groupID] }
            rowsVisited += 1
        }
        for recording in filteredForce {
            _ = sessionGroupIDs().contains(recording.groupID ?? recording.id)
            rowsVisited += 1
        }

        return Result(
            timeline: timeline,
            sessions: filteredSessions,
            loose: filteredLoose,
            force: filteredForce,
            options: filterOptions(),
            groupMapBuilds: groupMapBuilds,
            rowsVisited: rowsVisited
        )
    }
}
