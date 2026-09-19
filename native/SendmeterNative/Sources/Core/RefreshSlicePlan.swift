import Foundation

// MARK: - Per-slice refresh outcomes (#923)

/// #923: one independently-fetched table of the authoritative refresh.
///
/// `refreshAll` starts nine fetches concurrently. Before this type existed
/// they were awaited with `try await` in sequence, so the FIRST failure threw
/// out of the whole pass and cancelled the reconciliation of every sibling —
/// a failed health fetch could discard a perfectly good sessions page that had
/// already come back.
public enum RefreshSlice: String, CaseIterable, Sendable {
    case sessions
    case recordings
    case settings
    case phasePeriods
    case healthMetrics
    case presets
    case routinePresets
    case workoutsAndAttempts
    case tagMetadata

    public var displayName: String {
        switch self {
        case .sessions: return "Sessions"
        case .recordings: return "Force recordings"
        case .settings: return "Settings"
        case .phasePeriods: return "Training blocks"
        case .healthMetrics: return "Health metrics"
        case .presets: return "Presets"
        case .routinePresets: return "Routines"
        case .workoutsAndAttempts: return "Workouts"
        case .tagMetadata: return "Exercise tags"
        }
    }
}

/// #923: the unit that either publishes together or not at all.
///
/// Only a group whose every slice fetched successfully may be applied to the
/// cache and published, so a partially authoritative group is never exposed.
/// The two multi-slice groups are the dependent pairs the schema itself
/// couples:
///
/// - `sessionsAndRecordings`: a recording points at its session, and both are
///   the Trash-backed entities whose reconciliation is decided together by the
///   account's purge generation.
/// - `settingsAndPhase`: one writer (`switchPhase`) writes the settings row
///   and the period rows as one transition; publishing half of it would show
///   a training block the settings row does not agree with.
///
/// `workoutsAndAttempts` is one slice already (attempts are children of the
/// workout page) and stays one group. Every other entity is independent.
public enum RefreshConsistencyGroup: String, CaseIterable, Sendable {
    case sessionsAndRecordings
    case settingsAndPhase
    case healthMetrics
    case presets
    case routinePresets
    case workoutsAndAttempts
    case tagMetadata

    public var slices: [RefreshSlice] {
        switch self {
        case .sessionsAndRecordings: return [.sessions, .recordings]
        case .settingsAndPhase: return [.settings, .phasePeriods]
        case .healthMetrics: return [.healthMetrics]
        case .presets: return [.presets]
        case .routinePresets: return [.routinePresets]
        case .workoutsAndAttempts: return [.workoutsAndAttempts]
        case .tagMetadata: return [.tagMetadata]
        }
    }

    public var displayName: String {
        switch self {
        case .sessionsAndRecordings: return "Sessions and force recordings"
        case .settingsAndPhase: return "Settings and training blocks"
        case .healthMetrics: return "Health metrics"
        case .presets: return "Presets"
        case .routinePresets: return "Routines"
        case .workoutsAndAttempts: return "Workouts"
        case .tagMetadata: return "Exercise tags"
        }
    }

    public static func group(of slice: RefreshSlice) -> RefreshConsistencyGroup {
        allCases.first { $0.slices.contains(slice) } ?? .sessionsAndRecordings
    }
}

/// The collected per-slice outcomes of one refresh pass.
public struct RefreshSliceOutcomes: Equatable, Sendable {
    public private(set) var failedSlices: Set<RefreshSlice>
    /// A cancelled pass is not a verdict: it publishes nothing, advances no
    /// cursor and reports no failure (the user's work is simply still there).
    public private(set) var wasCancelled: Bool

    public init(failedSlices: Set<RefreshSlice> = [], wasCancelled: Bool = false) {
        self.failedSlices = failedSlices
        self.wasCancelled = wasCancelled
    }

    public mutating func record(slice: RefreshSlice, failed: Bool) {
        if failed {
            failedSlices.insert(slice)
        } else {
            failedSlices.remove(slice)
        }
    }

    public mutating func markCancelled() {
        wasCancelled = true
    }

    /// Only a group whose every slice succeeded may be applied and published.
    public func publishes(_ group: RefreshConsistencyGroup) -> Bool {
        !wasCancelled && group.slices.allSatisfy { !failedSlices.contains($0) }
    }

    public var publishableGroups: [RefreshConsistencyGroup] {
        RefreshConsistencyGroup.allCases.filter { publishes($0) }
    }

    /// The groups a failure kept off screen. A cancelled pass reports none:
    /// nothing was refused, the pass simply has no verdict (#923 AC5).
    public var failedGroups: [RefreshConsistencyGroup] {
        guard !wasCancelled else { return [] }
        return RefreshConsistencyGroup.allCases.filter { !publishes($0) }
    }

    public var didPublishAnyGroup: Bool { !publishableGroups.isEmpty }

    /// Every slice reconciled: this is the only pass allowed to advance the
    /// account-wide "last full refresh" freshness stamp.
    public var didFullyRefresh: Bool { !wasCancelled && failedSlices.isEmpty }

    /// Failed slices in a stable order, so the representative failure (and the
    /// banner copy) does not depend on which task happened to throw first.
    public var failedSlicesInOrder: [RefreshSlice] {
        RefreshSlice.allCases.filter { failedSlices.contains($0) }
    }
}

/// #923: the scoped failure information an explicit refresh (or a background
/// pass) leaves behind when some slices published and others did not. It is
/// deliberately narrower than the global offline banner: it names the groups
/// that did not refresh, and the surface that owns it carries the retry.
public struct RefreshFailureSummary: Equatable, Sendable {
    public let accountUserID: UUID
    public let groups: [RefreshConsistencyGroup]
    public let reason: String
    public let source: ErrorSurfaceSource
    public let occurredAt: Date

    public init(
        accountUserID: UUID,
        groups: [RefreshConsistencyGroup],
        reason: String,
        source: ErrorSurfaceSource,
        occurredAt: Date
    ) {
        self.accountUserID = accountUserID
        self.groups = groups
        self.reason = reason
        self.source = source
        self.occurredAt = occurredAt
    }

    public var groupNames: String {
        let names = groups.map(\.displayName)
        switch names.count {
        case 0: return "Some data"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    public var message: String {
        "\(groupNames) didn't refresh (\(reason)). The rest of your data is up to date."
    }
}
