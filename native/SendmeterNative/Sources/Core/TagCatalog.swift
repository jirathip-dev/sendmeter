import Foundation

/// Per-tag registry metadata (SL-92, web parity #631): `tindeq_tags` is a
/// lightweight per-user registry — tags themselves stay DENORMALIZED as the
/// text `tindeq_recordings.tag`, so a row here only exists once a tag is
/// hidden (or carries a fitted curve, which native computes on-device). RLS
/// scopes every row to `auth.uid()`.
public struct TagMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var hidden: Bool

    public init(name: String, hidden: Bool) {
        self.name = name
        self.hidden = hidden
    }
}

/// One row of the exercise manager: a distinct recording tag, its rep count,
/// and whether it is hidden. Derived from recordings + registry rows.
public struct TagEntry: Equatable, Sendable {
    public let name: String
    public let count: Int
    public let hidden: Bool

    public init(name: String, count: Int, hidden: Bool) {
        self.name = name
        self.count = count
        self.hidden = hidden
    }
}

/// Pure tag-registry logic: building the exercise list from recordings +
/// registry rows, and the rename/hide state transitions (mirrors
/// `TagManagerSheet` + `src/lib/repo/tindeq.ts`).
public enum TagCatalog {
    /// Every distinct non-empty recording tag with its rep count, plus the
    /// hidden flag from the registry (exact-name match — the denormalized
    /// recording text IS the grouping key, same as the web).
    public static func entries(
        recordings: [TindeqRecording],
        metadata: [TagMetadata]
    ) -> [TagEntry] {
        let hidden = Set(metadata.filter(\.hidden).map(\.name))
        var counts: [String: Int] = [:]
        for recording in recordings {
            let tag = recording.tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            counts[tag, default: 0] += 1
        }
        return counts
            .map { TagEntry(name: $0.key, count: $0.value, hidden: hidden.contains($0.key)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func hiddenNames(_ metadata: [TagMetadata]) -> Set<String> {
        Set(metadata.filter(\.hidden).map(\.name))
    }

    /// The pickable tag names: entries minus hidden (the web's Force-tab
    /// picker/trend rule — hidden tags' recordings still exist, they just
    /// leave the default views).
    public static func visibleNames(_ entries: [TagEntry]) -> [String] {
        entries.filter { !$0.hidden }.map(\.name)
    }

    /// The local state transition for a rename: repoint every entry to the
    /// new name, merging counts if both exist. The DB RPC deletes the old
    /// registry row and, when the new name already has a row, ITS hidden
    /// state wins (`rename_tindeq_tag`'s merge contract) — a renamed tag
    /// that doesn't merge back into an existing row becomes visible again.
    public static func applyingRename(
        _ entries: [TagEntry],
        from oldName: String,
        to newName: String
    ) -> [TagEntry] {
        let next = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, next != oldName else { return entries }
        let target = entries.first { $0.name == next }
        var out: [TagEntry] = []
        for entry in entries where entry.name != oldName {
            if entry.name == next {
                out.append(TagEntry(name: next, count: entry.count, hidden: entry.hidden))
            } else {
                out.append(entry)
            }
        }
        guard let source = entries.first(where: { $0.name == oldName }) else { return out }
        out.removeAll { $0.name == next }
        out.append(
            TagEntry(
                name: next,
                count: source.count + (target?.count ?? 0),
                hidden: target?.hidden ?? false
            )
        )
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The local state transition for hide/show — the registry upsert never
    /// touches the recordings, only the entry's flag.
    public static func applyingHidden(
        _ entries: [TagEntry],
        name: String,
        hidden: Bool
    ) -> [TagEntry] {
        entries.map {
            $0.name == name ? TagEntry(name: $0.name, count: $0.count, hidden: hidden) : $0
        }
    }
}
