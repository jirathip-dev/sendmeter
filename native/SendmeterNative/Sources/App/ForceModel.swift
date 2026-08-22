import Combine
import Foundation
import SendmeterCore

/// #672: the Force tab's hot, feature-scoped observable state.
///
/// `AppModel` was a single app-wide `ObservableObject` with ~26 `@Published`
/// properties, so a force-stream publish (progress revision, tag curves,
/// guided-protocol flag, recordings-loaded flag) invalidated every observing
/// body. This model hoists the force-EXCLUSIVE hot state into its own
/// invalidation domain. Shared collections (`recordings`, `presets`,
/// `tagMetadata`, ...) are read by History/Settings too, so they deliberately
/// stay on `AppModel`.
@MainActor
public final class ForceModel: ObservableObject {
    @Published public internal(set) var forceProgressRevision: UInt64 = 0
    @Published public internal(set) var tagCurves: [TagForceCurve] = []
    @Published public internal(set) var guidedProtocolActive = false
    /// True once the recording list has been fetched and merged at least once
    /// for the current account (even if it came back empty). Recordings have
    /// no disk cache, so `recordings.isEmpty` cannot distinguish "no force
    /// history" from "not fetched yet" or an initial fetch failure. Consumers
    /// use this to keep the Force consistency card's empty state honest.
    @Published public internal(set) var hasLoadedRecordings = false

    public init() {}
}
