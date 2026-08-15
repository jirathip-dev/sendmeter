import Foundation

/// One row of the combined History timeline (#630): a session or a loose
/// Tindeq recording, interleaved by day — the web's `HistoryView` shape
/// (`TimelineItem`).
public enum HistoryTimelineItem: Equatable, Sendable, Identifiable {
    case session(Session)
    case recording(TindeqRecording)

    public var id: String {
        switch self {
        case let .session(session): return "s-\(session.id.uuidString)"
        case let .recording(recording): return "r-\(recording.id.uuidString)"
        }
    }

    /// The day this item belongs to (YYYY-MM-DD). Sessions carry their own
    /// date; recordings are bucketed by their recorded day.
    public var date: String {
        switch self {
        case let .session(session): return session.date
        case let .recording(recording): return LocalDateSupport.string(from: recording.recordedAt)
        }
    }

    /// Sessions sort before recordings within the same day (web: sessions
    /// get sortKey `…~1`, recordings `…~0`, descending).
    var kindRank: Int {
        switch self {
        case .session: return 0
        case .recording: return 1
        }
    }
}

public enum HistoryTimeline {
    /// The recordings that surface as loose rows in the combined timeline:
    /// no group at all, OR a group no session references. The second clause
    /// is the web's orphan-rescue rule: a gauge run that was never "finished"
    /// logs recordings stamped with a `groupID` but no session row — treat
    /// them as loose, or they'd show nowhere (not under a session, and
    /// excluded from the loose list — the "PR missing from History" bug).
    public static func looseRecordings(
        _ recordings: [TindeqRecording],
        in sessions: [Session]
    ) -> [TindeqRecording] {
        let sessionGroupIDs = Set(sessions.compactMap(\.groupID))
        return recordings.filter { recording in
            guard let groupID = recording.groupID else { return true }
            return !sessionGroupIDs.contains(groupID)
        }
    }

    /// The combined timeline: every session plus the loose recordings,
    /// interleaved by day (descending), with same-day sessions before that
    /// day's loose recordings. Within a kind the input order is preserved
    /// (stable). Mirrors web `HistoryView`'s `items` sort.
    public static func combinedItems(
        sessions: [Session],
        recordings: [TindeqRecording],
        timeZone: TimeZone = .current
    ) -> [HistoryTimelineItem] {
        let sessionItems: [HistoryTimelineItem] = sessions.map { .session($0) }
        let recordingItems: [HistoryTimelineItem] = looseRecordings(recordings, in: sessions)
            .map { .recording($0) }
        let all = sessionItems + recordingItems
        return all.enumerated()
            .sorted { left, right in
                let (lhs, rhs) = (left.element, right.element)
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}
