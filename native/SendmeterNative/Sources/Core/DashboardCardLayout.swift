import Foundation

/// Shared geometry contracts for the Dashboard's paired context cards.
public enum DashboardCardLayout {
    /// The measured native Training Block card height in the Dashboard row.
    ///
    /// Send Conditions applies this as a minimum too, so Check, unavailable,
    /// and populated readings all share the same baseline while accessibility-
    /// sized content can grow rather than clip.
    public static let contextRowCardHeight: CGFloat = 314
}
