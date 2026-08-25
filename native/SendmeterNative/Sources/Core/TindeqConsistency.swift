import Foundation

/// The pure data model for the Force consistency card (#654).
///
/// Consistency means distinct local calendar days trained in each rolling
/// seven-day window. A recording is not a unit of consistency: three pulls on
/// one day still count as one day, while two tags on that day each contribute
/// one day to their own `byTag` count.
public enum TindeqConsistency {
    public static let windowCount = 8
    public static let daysPerWindow = 7
    public static let barHeight: Double = 64

    public struct Week: Equatable, Sendable, Identifiable {
        public let label: String
        public let days: Int
        public let byTag: [String: Int]

        public var id: String { label }

        public init(label: String, days: Int, byTag: [String: Int]) {
            self.label = label
            self.days = days
            self.byTag = byTag
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let weeks: [Week]
        public let tags: [String]

        public init(weeks: [Week], tags: [String]) {
            self.weeks = weeks
            self.tags = tags
        }

        public var hasRecordings: Bool {
            weeks.contains { $0.days > 0 }
        }
    }

    /// Computes the eight windows ending on the local calendar day containing
    /// `now`. The oldest window is `7w`; the final six days plus today are
    /// labelled `Now`, matching the web card's rolling-window semantics.
    public static func compute(
        recordings: [TindeqRecording],
        hiddenTags: Set<String>,
        now: Date,
        timeZone: TimeZone
    ) -> Snapshot {
        let today = LocalDateSupport.string(from: now, timeZone: timeZone)
        let oldestDay = LocalDateSupport.daysAgo(
            windowCount * daysPerWindow - 1,
            from: now,
            timeZone: timeZone
        )

        // Scope once to the inclusive 56-day window. This both keeps future
        // rows out of the chart and ensures tag chips cannot be sourced from
        // an older or future-dated recording.
        let scoped = recordings.compactMap { recording -> (recording: TindeqRecording, day: String)? in
            let day = LocalDateSupport.string(from: recording.recordedAt, timeZone: timeZone)
            guard day >= oldestDay, day <= today, !hiddenTags.contains(recording.tag) else {
                return nil
            }
            return (recording, day)
        }

        let tags = Set(
            scoped.compactMap { item in
                item.recording.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : item.recording.tag
            }
        ).sorted(by: alphabetically)

        let weeks = (0..<windowCount).map { index in
            // The array is oldest → newest: 7w, 6w, …, 1w, Now.
            let weeksBack = windowCount - 1 - index
            let start = LocalDateSupport.daysAgo(
                weeksBack * daysPerWindow + daysPerWindow - 1,
                from: now,
                timeZone: timeZone
            )
            let end = LocalDateSupport.daysAgo(
                weeksBack * daysPerWindow,
                from: now,
                timeZone: timeZone
            )
            var allDays = Set<String>()
            var daysByTag: [String: Set<String>] = [:]

            for item in scoped where item.day >= start && item.day <= end {
                allDays.insert(item.day)
                let tag = item.recording.tag
                guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                daysByTag[tag, default: []].insert(item.day)
            }

            let byTag = daysByTag.mapValues(\.count)
            return Week(
                label: weeksBack == 0 ? "Now" : "\(weeksBack)w",
                days: allDays.count,
                byTag: byTag
            )
        }

        return Snapshot(weeks: weeks, tags: tags)
    }

    /// Returns the same bar's day count under a tag filter. This deliberately
    /// does not stack tag counts: a selected tag narrows every bar in place.
    public static func selectedTagDays(
        for week: Week,
        selectedTag: String?
    ) -> Int {
        guard let selectedTag else { return week.days }
        return week.byTag[selectedTag] ?? 0
    }

    /// A selected tag may disappear after a refresh when it is hidden or ages
    /// out of the rolling window. In that case the card must visibly return to
    /// All rather than leave an all-zero chart behind.
    public static func effectiveSelectedTag(
        _ selectedTag: String?,
        availableTags: [String]
    ) -> String? {
        guard let selectedTag, availableTags.contains(selectedTag) else { return nil }
        return selectedTag
    }

    private static func alphabetically(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison == .orderedSame { return lhs < rhs }
        return comparison == .orderedAscending
    }
}
