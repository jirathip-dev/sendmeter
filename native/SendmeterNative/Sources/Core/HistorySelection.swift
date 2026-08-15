import Foundation

/// The pure plan for "Create session from selected loose recordings" (#630):
/// which session fields the new Tindeq session gets, and exactly which
/// recordings move under it. Mirrors web `HistoryView.createSessionFromSelection`.
public struct SelectionSessionPlan: Equatable, Sendable {
    public let date: String
    public let type: String
    public let typeLabel: String
    public let durationMinutes: Int
    public let rpe: Double
    public let note: String
    public let phase: PhaseID
    /// The ticked recordings, chronologically sorted — the exact set that
    /// gets stamped with the new session's group id.
    public let recordingIDs: [UUID]

    public var draft: SessionDraft {
        SessionDraft(
            date: date,
            type: type,
            typeLabel: typeLabel,
            durationMinutes: durationMinutes,
            rpe: rpe,
            note: note,
            phase: phase
        )
    }
}

public enum SelectionSessionPlanner {
    /// RPE 5 default, date = first recording's day, duration = the span from
    /// the first recording's start to the last recording's end, rounded to
    /// whole minutes (minimum 1 — the same `Math.max(1, Math.round(spanMs /
    /// 60000))` the web computes; the `link_tindeq_recordings_to_session` RPC
    /// recomputes the identical value transactionally, clamped to 1...600),
    /// note = "N recordings · tag1, tag2".
    ///
    /// Nil for an empty selection.
    public static func plan(
        recordings: [TindeqRecording],
        phase: PhaseID,
        timeZone: TimeZone = .current
    ) -> SelectionSessionPlan? {
        let sorted = recordings.sorted { $0.recordedAt < $1.recordedAt }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let spanMilliseconds =
            last.recordedAt.timeIntervalSince(first.recordedAt) * 1_000
            + Double(last.durationMilliseconds)
        let durationMinutes = max(1, Int((spanMilliseconds / 60_000).rounded()))

        var seen = Set<String>()
        var tags: [String] = []
        for tag in sorted.map(\.tag) where !tag.isEmpty {
            if seen.insert(tag).inserted { tags.append(tag) }
        }
        let count = sorted.count
        var note = "\(count) recording\(count == 1 ? "" : "s")"
        if !tags.isEmpty { note += " · " + tags.joined(separator: ", ") }

        return SelectionSessionPlan(
            date: LocalDateSupport.string(from: first.recordedAt, timeZone: timeZone),
            type: "tindeq",
            typeLabel: "Tindeq",
            durationMinutes: durationMinutes,
            rpe: 5,
            note: note,
            phase: phase,
            recordingIDs: sorted.map(\.id)
        )
    }
}
