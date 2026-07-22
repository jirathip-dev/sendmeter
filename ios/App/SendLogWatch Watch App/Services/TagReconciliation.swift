import Foundation

/// SL-94: whether the watch's persisted last-used Progressor tag
/// (`ForceGaugeView`'s `LAST_TAG_KEY`) should be dropped because it's gone
/// stale — renamed or hidden away on the phone (SL-92) since it was saved.
/// Pure decision logic, pulled out of the view so it's unit-testable without
/// a SwiftUI/UserDefaults harness.
enum TagReconciliation {
    /// `visibleTags` must be a CONFIRMED, NON-EMPTY fetch result — never call
    /// this while a fetch is still in flight/retrying, and never with an empty
    /// list: under RLS an unauthenticated select succeeds with zero rows, so
    /// an empty result is indistinguishable from the SL-75 auth race and would
    /// wipe out a perfectly valid tag (`loadTags` enforces both).
    static func shouldClearStaleTag(_ tag: String, visibleTags: [String]) -> Bool {
        !tag.isEmpty && !visibleTags.contains(tag)
    }
}
