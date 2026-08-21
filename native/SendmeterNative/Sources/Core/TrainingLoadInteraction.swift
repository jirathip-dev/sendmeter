import Foundation

/// Pure interaction contracts shared by the native Training Load charts.
/// Keeping hit geometry, selection toggling and edge handling here makes the
/// gesture wiring testable without pretending that a SwiftUI view can be
/// exercised by the package test target.
public enum TrainingLoadInteraction {
    /// The painted Activity Mix strip remains intentionally compact.
    public static let activityMixVisualHeight = 10.0

    /// The Activity Mix touch/VoiceOver region follows Apple's comfortable
    /// minimum target while the painted strip stays at `activityMixVisualHeight`.
    public static let activityMixHitHeight = 44.0

    /// Matches the visible gap between weekly bars.
    public static let weeklyBarSpacing = 8.0

    /// Resolves a horizontal point to the weekly bar slot under it. The
    /// spacing is part of the slot calculation, so a scrub stays aligned with
    /// the flexible `HStack` even when the chart is resized.
    public static func weeklyBarIndex(
        x: Double,
        width: Double,
        count: Int,
        spacing: Double = weeklyBarSpacing
    ) -> Int? {
        guard count > 0, width.isFinite, width > 0, x.isFinite else { return nil }
        let safeSpacing = spacing.isFinite ? max(spacing, 0) : 0
        let slot = (width + safeSpacing) / Double(count)
        guard slot > 0 else { return nil }
        let clampedX = min(max(x, 0), width)
        let raw = Int(floor(clampedX / slot))
        return min(max(raw, 0), count - 1)
    }

    /// Resolves a horizontal point to a proportional Activity Mix segment.
    /// Negative/non-finite shares are treated as zero, and the final segment
    /// owns the right edge so rounding never leaves a dead strip.
    public static func activityMixIndex(
        x: Double,
        width: Double,
        percentages: [Double]
    ) -> Int? {
        guard !percentages.isEmpty, width.isFinite, width > 0, x.isFinite else { return nil }
        let position = min(max(x, 0), width)
        let lastIndex = percentages.count - 1
        var start = 0.0

        for (index, percentage) in percentages.enumerated() {
            let safePercentage = percentage.isFinite ? max(percentage, 0) : 0
            let segmentWidth = width * safePercentage / 100
            if position < start + segmentWidth || index == lastIndex {
                return index
            }
            start += segmentWidth
        }
        return nil
    }

    /// Tap toggles the current selection; scrubbing to a different value
    /// selects that value. The views use this for tap-again dismissal, while
    /// their separate tick guard controls haptic deduplication.
    public static func toggledSelection<Value: Equatable>(
        current: Value?,
        candidate: Value
    ) -> Value? {
        current == candidate ? nil : candidate
    }
}
