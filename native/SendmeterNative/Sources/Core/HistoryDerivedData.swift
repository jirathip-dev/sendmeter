import Foundation

/// Whole-history scan instrumentation for the History derived-data snapshot
/// (#924). Product code never reads it; the scan entry points bump it so the
/// call-count tests can fail when a whole-history scan re-enters a per-item
/// loop (the pre-#924 `HistoryView` shape).
public enum HistoryScanCounter {
    public enum Scan: String, CaseIterable {
        /// One `HistoryDerivedData` build (group map + projections).
        case derivedData
        /// One `HistoryFilters.options` pass (type chips, tag set, sort).
        case filterOptions
        /// One `HistoryTimeline.looseRecordings` pass.
        case looseRecordings
        /// One `HistoryTimeline.combinedItems` pass.
        case combinedItems
    }

    private static let lock = NSLock()
    private static var counts: [Scan: Int] = [:]

    static func bump(_ scan: Scan) {
        lock.lock()
        counts[scan, default: 0] += 1
        lock.unlock()
    }

    public static func count(_ scan: Scan) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[scan] ?? 0
    }

    public static func reset() {
        lock.lock()
        counts = [:]
        lock.unlock()
    }
}

/// The History screen's whole derived data for ONE input revision (#924): the
/// recording group map, the filter-chip options and the filtered projections
/// are computed exactly once here and reused by the session / recording
/// predicates and the rows.
///
/// Every output keeps the semantics the view computed inline before this
/// snapshot existed — search, type/tag filters, hidden tags, loose/orphan
/// group rules and ordering are unchanged (the equivalence tests compare this
/// snapshot against the pre-#924 shape).
public struct HistoryDerivedData: Equatable, Sendable {
    /// Filter chips over the complete effective timeline, with a stale
    /// selection coerced to nil (see `HistoryFilters.options`).
    public let options: HistoryFilterOptions
    /// Recordings grouped by `groupID` — orphan groups included, so a row can
    /// look up its own group without rescanning the recording list.
    public let recordingsByGroup: [UUID: [TindeqRecording]]
    /// The group ids any session references: the loose/grouped split a
    /// recording row needs.
    public let sessionGroupIDs: Set<UUID>
    /// Tindeq sessions carrying a group — the "Assign…" candidates.
    public let tindeqSessions: [Session]
    /// Sessions matching the query and the type/tag filters, input order.
    public let filteredSessions: [Session]
    /// Loose recordings matching the query and the type/tag filters, input
    /// order.
    public let filteredLooseRecordings: [TindeqRecording]
    /// Every recording (grouped + loose) matching the query and the type/tag
    /// filters, input order — the Force mode list.
    public let filteredForceRecordings: [TindeqRecording]
    /// The combined All-mode timeline: sessions + loose recordings,
    /// interleaved by day (descending), same-day sessions first.
    public let timelineItems: [HistoryTimelineItem]

    public init(
        sessions: [Session],
        recordings: [TindeqRecording],
        hiddenTagNames: Set<String> = [],
        query: String = "",
        selectedType: String? = nil,
        selectedTag: String? = nil
    ) {
        HistoryScanCounter.bump(.derivedData)

        var groupMap: [UUID: [TindeqRecording]] = [:]
        for recording in recordings {
            guard let groupID = recording.groupID else { continue }
            groupMap[groupID, default: []].append(recording)
        }
        self.recordingsByGroup = groupMap
        self.sessionGroupIDs = Set(sessions.compactMap(\.groupID))

        // Options come from the COMPLETE timeline: a hidden tag only drops
        // its chip, never a row (#647).
        let loose = HistoryTimeline.looseRecordings(recordings, in: sessions)
        let options = HistoryFilters.options(
            sessions: sessions,
            looseRecordings: loose,
            groupedRecordings: recordings.filter { $0.groupID != nil },
            selectedType: selectedType,
            selectedTag: selectedTag,
            hiddenTagNames: hiddenTagNames
        )
        self.options = options

        let querySessions: [Session]
        if query.isEmpty {
            querySessions = sessions
        } else {
            querySessions = sessions.filter {
                $0.typeLabel.localizedCaseInsensitiveContains(query)
                    || $0.note.localizedCaseInsensitiveContains(query)
                    || $0.date.localizedCaseInsensitiveContains(query)
            }
        }
        let queryRecordings = HistoryFilters.recordingsMatchingQuery(recordings, query: query)

        // Hoisted once: the predicates below must never re-enter a
        // whole-history scan per item.
        let activeType = options.activeType
        let activeTag = options.activeTag

        let filteredSessions = querySessions.filter { session in
            HistoryFilters.sessionMatches(
                session,
                groupRecordings: session.groupID.flatMap { groupMap[$0] } ?? [],
                type: activeType,
                tag: activeTag
            )
        }
        let filteredLooseRecordings = HistoryTimeline.looseRecordings(queryRecordings, in: sessions)
            .filter { HistoryFilters.looseRecordingMatches($0, type: activeType, tag: activeTag) }
        let filteredForceRecordings = queryRecordings.filter {
            HistoryFilters.looseRecordingMatches($0, type: activeType, tag: activeTag)
        }

        self.filteredSessions = filteredSessions
        self.filteredLooseRecordings = filteredLooseRecordings
        self.filteredForceRecordings = filteredForceRecordings
        self.tindeqSessions = sessions.filter {
            $0.type == "tindeq" && $0.groupID != nil && !$0.pending
        }
        self.timelineItems = HistoryTimeline.combinedItems(
            sessions: filteredSessions,
            recordings: filteredLooseRecordings
        )
    }
}

/// Memoizes `HistoryDerivedData` for the current input revision (#924).
/// Reference type so a SwiftUI view can keep one in `@State`: the snapshot is
/// rebuilt only when a relevant input changes (sessions, recordings, hidden
/// tags, query, type/tag selection). Growing the visible page re-reads the
/// same snapshot — paging is not a rebuild.
public final class HistoryDerivedDataCache {
    private struct Revision: Equatable {
        let sessions: [Session]
        let recordings: [TindeqRecording]
        let hiddenTagNames: Set<String>
        let query: String
        let selectedType: String?
        let selectedTag: String?
    }

    private var revision: Revision?
    private var snapshot: HistoryDerivedData?
    /// Test instrumentation: how many snapshots this cache has built.
    public private(set) var buildCount = 0

    public init() {}

    public func data(
        sessions: [Session],
        recordings: [TindeqRecording],
        hiddenTagNames: Set<String> = [],
        query: String = "",
        selectedType: String? = nil,
        selectedTag: String? = nil
    ) -> HistoryDerivedData {
        let next = Revision(
            sessions: sessions,
            recordings: recordings,
            hiddenTagNames: hiddenTagNames,
            query: query,
            selectedType: selectedType,
            selectedTag: selectedTag
        )
        if let revision, let snapshot, revision == next {
            return snapshot
        }
        let built = HistoryDerivedData(
            sessions: sessions,
            recordings: recordings,
            hiddenTagNames: hiddenTagNames,
            query: query,
            selectedType: selectedType,
            selectedTag: selectedTag
        )
        revision = next
        snapshot = built
        buildCount += 1
        return built
    }
}
