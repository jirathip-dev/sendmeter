import Foundation

/// One session-type filter chip option (#630) — mirrors web
/// `historyFilterOptions`'s `{ id, label }` shape.
public struct HistoryTypeOption: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct HistoryFilterOptions: Equatable, Sendable {
    public let types: [HistoryTypeOption]
    public let tags: [String]
    /// Nil means "All". A selection that no longer exists in the data is
    /// coerced to nil at render time (web parity) so the UI can't re-engage
    /// a stale filter once matching data reappears.
    public let activeType: String?
    public let activeTag: String?

    public init(types: [HistoryTypeOption], tags: [String], activeType: String?, activeTag: String?) {
        self.types = types
        self.tags = tags
        self.activeType = activeType
        self.activeTag = activeTag
    }
}

/// Session-type + force-tag filter chips over the combined timeline (#630),
/// mirroring web `src/lib/historyFilters.ts`.
public enum HistoryFilters {
    /// Options come from the complete effective timeline: one type chip per
    /// session type (plus "Tindeq" when loose recordings exist and no tindeq
    /// session does), and one tag chip per distinct recording tag across
    /// loose AND grouped recordings. Hidden tags are omitted from the chip
    /// list only; their recordings remain part of the effective timeline.
    public static func options(
        sessions: [Session],
        looseRecordings: [TindeqRecording],
        groupedRecordings: [TindeqRecording],
        selectedType: String?,
        selectedTag: String?,
        hiddenTagNames: Set<String> = []
    ) -> HistoryFilterOptions {
        HistoryScanCounter.bump(.filterOptions)
        var labels: [(id: String, label: String)] = []
        var seenTypes = Set<String>()
        for session in sessions where seenTypes.insert(session.type).inserted {
            labels.append((session.type, session.typeLabel))
        }
        if !looseRecordings.isEmpty, !seenTypes.contains("tindeq") {
            labels.append(("tindeq", "Tindeq"))
        }

        var tags = Set<String>()
        for recording in looseRecordings + groupedRecordings
            where !recording.tag.isEmpty && !hiddenTagNames.contains(recording.tag) {
            tags.insert(recording.tag)
        }

        return HistoryFilterOptions(
            types: labels.map { HistoryTypeOption(id: $0.id, label: $0.label) },
            tags: tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            activeType: selectedType.flatMap { selected in
                labels.contains { $0.id == selected } ? selected : nil
            },
            activeTag: selectedTag.flatMap { tags.contains($0) ? $0 : nil }
        )
    }

    /// Recordings shown by the History search/default source. Hidden tags do
    /// not participate here: hiding a tag only removes its chip, while the
    /// recording remains visible in All/Force modes and searchable by tag.
    public static func recordingsMatchingQuery(
        _ recordings: [TindeqRecording],
        query: String
    ) -> [TindeqRecording] {
        guard !query.isEmpty else { return recordings }
        return recordings.filter {
            $0.tag.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || $0.side.label.localizedCaseInsensitiveContains(query)
        }
    }

    /// A session matches a type filter by its own type; a tag filter matches
    /// only when at least one recording in its group carries the tag (a
    /// session with no group can never match a tag filter).
    public static func sessionMatches(
        _ session: Session,
        groupRecordings: [TindeqRecording],
        type: String?,
        tag: String?
    ) -> Bool {
        if let type, session.type != type { return false }
        guard let tag else { return true }
        guard session.groupID != nil else { return false }
        return groupRecordings.contains { $0.tag == tag }
    }

    /// A loose recording matches a type filter only for "tindeq" (recordings
    /// are never another session type), and a tag filter by its own tag.
    public static func looseRecordingMatches(
        _ recording: TindeqRecording,
        type: String?,
        tag: String?
    ) -> Bool {
        (type == nil || type == "tindeq") && (tag == nil || recording.tag == tag)
    }

    /// A filter change can hide a ticked recording without unticking it —
    /// prune the selection to what the new filter still shows, so a bulk
    /// action never silently includes a row the user can no longer see
    /// (web `pruneSelectionToVisible`).
    public static func pruneSelection(
        _ selected: Set<UUID>,
        toVisible recordings: [TindeqRecording],
        type: String?,
        tag: String?
    ) -> Set<UUID> {
        guard !selected.isEmpty else { return selected }
        let visible = Set(
            recordings.filter { looseRecordingMatches($0, type: type, tag: tag) }.map(\.id)
        )
        return selected.filter { visible.contains($0) }
    }
}
