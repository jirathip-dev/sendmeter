import Foundation

/// The cache identity for one fitted force curve.
///
/// Tags are normalized at the boundary so a metadata edit from "Crimp" to
/// " crimp " invalidates and warms the same cache entry. The display label is
/// kept on `TagForceCurve`; this type is only the fit-input identity.
public struct TagCurveCacheKey: Hashable, Sendable {
    public let tag: String
    public let modality: String

    public init(tag: String, modality: String) {
        self.tag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.modality = modality
    }
}

/// Per-key generations let an edit invalidate one fit without discarding an
/// unrelated tag's in-flight work. AccountScopedFetch remains the outer
/// ownership check; this index is the input-snapshot check inside the account.
public struct TagCurveCacheGenerationIndex: Equatable, Sendable {
    private var values: [TagCurveCacheKey: UInt64] = [:]

    public init() {}

    public func generation(for key: TagCurveCacheKey) -> UInt64 {
        values[key] ?? 0
    }

    @discardableResult
    public mutating func invalidate(_ keys: Set<TagCurveCacheKey>) -> Set<TagCurveCacheKey> {
        for key in keys {
            values[key, default: 0] &+= 1
        }
        return keys
    }
}

/// Pure decisions shared by AppModel's optimistic and persistence paths.
/// Keeping these decisions here makes the async implementation testable
/// without constructing the iOS repository and also documents that an upload
/// always touches both sides of a changed key, including an equal server row.
public enum TagCurveCachePolicy {
    public static func affectedKeys(
        old: TagCurveCacheKey?,
        new: TagCurveCacheKey?
    ) -> Set<TagCurveCacheKey> {
        Set([old, new].compactMap { $0 })
    }

    /// Resolve the cache keys touched by a metadata edit. The draft already
    /// contains the user's new values, so it is not a safe source for the old
    /// key. Callers must capture `authoritativeBefore` from the account-scoped
    /// model before awaiting persistence; the draft is only a fallback for a
    /// row that is no longer present locally.
    public static func metadataEditKeys(
        authoritativeBefore: TagCurveCacheKey?,
        draft: TagCurveCacheKey,
        saved: TagCurveCacheKey
    ) -> Set<TagCurveCacheKey> {
        affectedKeys(old: authoritativeBefore ?? draft, new: saved)
    }

    /// A pending recording is fit-eligible only when its samples are locally
    /// available. The explicit inclusion set is the optimistic sample store;
    /// without it, pending metadata must not silently produce a fit with no
    /// samples.
    public static func includes(
        recordingID: UUID,
        pendingIDs: Set<UUID>,
        locallyAvailableSampleIDs: Set<UUID>
    ) -> Bool {
        !pendingIDs.contains(recordingID) || locallyAvailableSampleIDs.contains(recordingID)
    }
}

/// The RPE cache only needs CF/W′/Max. Chart uncertainty is an explicitly
/// separate, background-only fit so a synchronous rep save cannot pay for it.
public enum TagCurveFitPurpose: Sendable {
    case pointEstimate
    case chartBand

    public var bootstrapSamples: Int {
        switch self {
        case .pointEstimate: return 0
        case .chartBand: return 200
        }
    }
}

/// A request stamp for an asynchronous tag-curve fit.
///
/// `AccountScopedFetch` protects account ownership; `generation` protects the
/// current key's fit inputs within that account. Both checks are required: a
/// fit started before a recording save or refresh must not repopulate that
/// cache key after its inputs have changed, even when the account is unchanged.
public struct TagCurveCacheRequest: Equatable, Sendable {
    public let accountFetch: AccountScopedFetch
    public let generation: UInt64

    public init(accountFetch: AccountScopedFetch, generation: UInt64) {
        self.accountFetch = accountFetch
        self.generation = generation
    }

    public func canApply(
        to currentUserID: UUID?,
        accountEpoch: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch)
            && generation == currentGeneration
    }
}
