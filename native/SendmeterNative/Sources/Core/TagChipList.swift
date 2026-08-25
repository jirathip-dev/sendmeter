import Foundation

/// Derives the compact exercise-chip presentation for the native Force
/// recording context (#750). Kept pure so duplicate removal, active-tag
/// inclusion, the `+N` count, and reveal-all behavior are unit-tested rather
/// than only exercised by the SwiftUI body. Mirrors the Capacitor
/// `TagSideEditor` visibleTags/hiddenCount shape.
public struct TagChipList: Equatable, Sendable {
    /// Capacitor's `VISIBLE`: the first N known exercises are always shown.
    public static let visibleChipCount = 8

    /// Trimmed, de-duplicated exercise names in their supplied order. An
    /// unknown active exercise is inserted first so it is immediately visible
    /// and toggleable, exactly like the web's brand-new-tag chip.
    public let uniqueTags: [String]
    public let activeTag: String
    public let showsAll: Bool

    public init(allTags: [String], activeTag: String, showsAll: Bool = false) {
        let trimmedTags = allTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var unique: [String] = []
        for tag in trimmedTags where seen.insert(tag).inserted {
            unique.append(tag)
        }

        let trimmedActive = activeTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedActive.isEmpty, !seen.contains(trimmedActive) {
            unique.insert(trimmedActive, at: 0)
        }

        self.uniqueTags = unique
        self.activeTag = trimmedActive
        self.showsAll = showsAll
    }

    /// The chips to render: all of them when revealed, otherwise the first
    /// `visibleChipCount` plus the active one when it is hidden beyond that
    /// prefix.
    public var visibleTags: [String] {
        guard !showsAll else { return uniqueTags }
        guard uniqueTags.count > Self.visibleChipCount else { return uniqueTags }

        var visible = Array(uniqueTags.prefix(Self.visibleChipCount))
        if !activeTag.isEmpty,
           let activeIndex = uniqueTags.firstIndex(of: activeTag),
           activeIndex >= Self.visibleChipCount {
            visible.append(activeTag)
        }
        return visible
    }

    /// Never negative: the active-tag inclusion is part of the visible set,
    /// not an extra chip tacked onto the hidden count.
    public var hiddenCount: Int {
        max(0, uniqueTags.count - visibleTags.count)
    }

    public func showingAll() -> TagChipList {
        TagChipList(allTags: uniqueTags, activeTag: activeTag, showsAll: true)
    }
}
