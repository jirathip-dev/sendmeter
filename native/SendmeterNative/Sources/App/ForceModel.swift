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

    /// The cached static fit for `tag` in a published tag-curve list — the one
    /// lookup the Force tab's zone gating, its curve card and the Focus-Next
    /// tie-break consume.
    ///
    /// Both sides are normalized (trim + lowercased) because the cache key is
    /// normalized while the published curve keeps the recordings' display tag.
    /// Static-only by construction: a reverse-action (movement) fit is never
    /// a hold-protocol reference (#990).
    public static func cachedStaticCurve(
        in curves: [TagForceCurve],
        tag: String
    ) -> TagForceCurve? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return curves.first {
            $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                && $0.modality == "static"
        }
    }

    /// The force-curve signal that lookup produces — the exact value
    /// `ForceRecordingContextCard` gates the four zone protocols on.
    public static func zoneCurveInput(
        in curves: [TagForceCurve],
        tag: String
    ) -> ZoneCurveInput? {
        cachedStaticCurve(in: curves, tag: tag).map { ZoneCurveInput($0) }
    }
}
