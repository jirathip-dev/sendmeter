import Foundation

/// Pure geometry contracts for the Dashboard's paired context cards.
public enum DashboardCardLayout {
    /// A row must be at least as tall as its tallest measured child. The
    /// SwiftUI row reserves all Send Conditions states before calling this,
    /// then places every child with the returned height.
    public static func equalizedRowHeight(_ measuredHeights: [CGFloat]) -> CGFloat {
        measuredHeights.max() ?? 0
    }
}
