import Combine
import Foundation
import SendmeterCore

/// #672: the Force tab's hot, feature-scoped observable state.
///
/// Before #783, `AppModel` was a single app-wide published model with ~26
/// properties, so a force-stream update (progress revision, tag curves,
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
    /// True once the current account has crossed the recordings' authoritative
    /// sync boundary, including an empty result. A readable first-launch
    /// SQLite file is not enough; `recordings.isEmpty` remains distinct from
    /// "not fetched yet" or an initial fetch failure. Consumers use this to
    /// keep the Force surfaces' empty state honest.
    @Published public internal(set) var hasLoadedRecordings = false

    public init() {}
}
