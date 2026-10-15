import Foundation

/// #1038 G6: the last-pull summary's one line of context — "FDP · Left ·
/// 2 days ago". Pure and testable, because the card and the accessibility
/// label must never disagree about the same pull.
public enum ForceLastPullFormat {
    /// The card's context line. Parts that carry no information are dropped
    /// rather than rendered as empty separators; a pull with no movement and
    /// no side still reads as its age alone.
    public static func contextLine(
        tag: String,
        side: TindeqSide,
        recordedAt: Date,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        var parts: [String] = []
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        if side != .unspecified { parts.append(side.label) }
        parts.append(relativeAge(of: recordedAt, now: now, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// The card's own convenience overload — the recording is the unit the
    /// Force surface holds.
    public static func contextLine(
        _ recording: TindeqRecording,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        contextLine(
            tag: recording.tag,
            side: recording.side,
            recordedAt: recording.recordedAt,
            now: now,
            locale: locale
        )
    }

    /// "just now" / "3 hours ago" / "2 days ago". Deliberately coarse: the
    /// summary is a signpost into History, not a stopwatch.
    public static func relativeAge(
        of date: Date,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
