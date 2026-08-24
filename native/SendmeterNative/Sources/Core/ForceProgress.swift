import Foundation

/// The recording scopes used by the Force progress tiles (#655).
///
/// Keeping this selection in the core module makes the distinction between
/// Static capacity evidence and resisted-movement execution data explicit and
/// testable. The UI should not invent a second filter for either modality.
public enum ForceProgress {
    public static let recentLimit = 8

    /// The native equivalent of the Force tab's `trendChartRecordings` path:
    /// static, measured, effort holds only. Maintenance holds and
    /// resisted-movement traces must not become Static PR, curve, or
    /// asymmetry evidence.
    public static func trendChartRecordings(
        _ recordings: [TindeqRecording],
        tag: String? = nil,
        side: TindeqSide? = nil
    ) -> [TindeqRecording] {
        recordings
            .filter { recording in
                (tag == nil || recording.tag == tag)
                    && (side == nil || recording.side == side)
                    && recording.protocolMode == .hold
                    && recording.source != .manual
                    && recording.peakKilograms != nil
                    && recording.averageKilograms != nil
                    && ZoneMix.isEffortRecording(recording)
            }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    /// One Static evidence scope shared by the compact tile, the full trend,
    /// and a side-scoped force-curve request. `recentRecordings` is the only
    /// intentionally sliced view; `trendRecordings` remains complete for the
    /// detail chart, while `curveFitRecordings` applies the stricter existing
    /// fit-candidate rules without ever admitting movement evidence.
    public static func staticCapacityEvidence(
        recordings: [TindeqRecording],
        tag: String? = nil,
        side: TindeqSide? = nil
    ) -> StaticCapacityEvidence {
        let trendRecordings = trendChartRecordings(recordings, tag: tag, side: side)
        let curveFitRecordings = trendRecordings.filter {
            !$0.rejected && ZoneMix.isCurveFitCandidate($0)
        }
        return StaticCapacityEvidence(
            trendRecordings: trendRecordings,
            recentRecordings: Array(trendRecordings.suffix(recentLimit)),
            curveFitRecordings: curveFitRecordings
        )
    }

    /// Whether the visible recording metadata changed in a way that can alter
    /// Static trend evidence or the existing curve candidate/picking rules.
    /// This is intentionally evaluated at model mutation boundaries, never
    /// while SwiftUI is rendering the Force tab.
    public static func staticCurveInputsChanged(
        before: [TindeqRecording],
        after: [TindeqRecording]
    ) -> Bool {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map {
            ($0.id, StaticCurveRecordingIdentity($0))
        })
        let afterByID = Dictionary(uniqueKeysWithValues: after.map {
            ($0.id, StaticCurveRecordingIdentity($0))
        })
        return beforeByID != afterByID
    }

    /// Whether any metadata used by either progress tile, its detail sheet,
    /// or the selected Static curve changed. This is deliberately broader
    /// than `staticCurveInputsChanged`: Movement's `setMetrics` is a tile
    /// input even though it must never invalidate Static evidence by itself.
    /// The comparison happens at model mutation boundaries, not in a SwiftUI
    /// render path, and Tindeq samples are not part of `TindeqRecording`.
    public static func progressInputsChanged(
        before: [TindeqRecording],
        after: [TindeqRecording]
    ) -> Bool {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map {
            ($0.id, ForceProgressRecordingIdentity($0))
        })
        let afterByID = Dictionary(uniqueKeysWithValues: after.map {
            ($0.id, ForceProgressRecordingIdentity($0))
        })
        return beforeByID != afterByID
    }

    public static func staticCapacityProgress(
        recordings: [TindeqRecording],
        tag: String? = nil,
        side: TindeqSide? = nil
    ) -> StaticCapacityProgress {
        let evidence = staticCapacityEvidence(recordings: recordings, tag: tag, side: side)
        return StaticCapacityProgress(
            recordings: evidence.recentRecordings,
            totalCount: evidence.trendRecordings.count,
            latestPeakKilograms: evidence.recentRecordings.last?.peakKilograms,
            bestPeakKilograms: evidence.recentRecordings.compactMap(\.peakKilograms).max()
        )
    }

    /// Measured resisted-movement sets are identified by their existing
    /// `setMetrics` payload. Cadence-only sessions have no such payload and
    /// intentionally remain out of this progress view rather than becoming
    /// fake zero-force measurements.
    public static func movementRecordings(
        _ recordings: [TindeqRecording],
        tag: String? = nil,
        side: TindeqSide? = nil
    ) -> [TindeqRecording] {
        recordings
            .filter { recording in
                (tag == nil || recording.tag == tag)
                    && (side == nil || recording.side == side)
                    && recording.protocolMode == .reverseAction
                    && recording.source != .manual
                    && recording.setMetrics != nil
            }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    public static func movementProgress(
        recordings: [TindeqRecording],
        tag: String? = nil,
        side: TindeqSide? = nil
    ) -> MovementProgress {
        let rows = movementRecordings(recordings, tag: tag, side: side)
        return MovementProgress(
            recordings: Array(rows.suffix(recentLimit)),
            totalCount: rows.count,
            latestMetrics: rows.last?.setMetrics
        )
    }

    /// Bar height as a fraction of the tile's available height. The 12%
    /// floor keeps a small effort visible, matching the web progress tile.
    public static func barFraction(value: Double?, maximum: Double) -> Double {
        guard let value, value.isFinite else { return 0.12 }
        let ratio = maximum > 0 && maximum.isFinite ? value / maximum : 0
        return max(0.12, min(1, ratio))
    }
}

/// The recording metadata that can alter selected Static trend evidence or
/// the existing force-curve candidate/picking rules. This deliberately omits
/// raw sample arrays and unrelated History/workout fields.
public struct StaticCurveRecordingIdentity: Hashable, Sendable {
    public let id: UUID
    public let recordedAt: Date
    public let durationMilliseconds: Int
    public let peakKilograms: Double?
    public let averageKilograms: Double?
    public let sampleCount: Int
    public let tag: String
    public let side: String
    public let protocolRunID: UUID?
    public let zone: String?
    public let source: String
    public let protocolMode: String
    /// Only recovery notes affect curve eligibility. Arbitrary notes are not
    /// fit inputs and therefore do not churn the curve task unnecessarily.
    public let recoveredNote: String?
    public let rejected: Bool

    public init(_ recording: TindeqRecording) {
        id = recording.id
        recordedAt = recording.recordedAt
        durationMilliseconds = recording.durationMilliseconds
        peakKilograms = recording.peakKilograms
        averageKilograms = recording.averageKilograms
        sampleCount = recording.sampleCount
        tag = recording.tag
        side = recording.side.rawValue
        protocolRunID = recording.protocolRunID
        zone = recording.zone?.rawValue
        source = recording.source.rawValue
        protocolMode = recording.protocolMode.rawValue
        recoveredNote = ZoneMix.isRecoveredRecording(recording) ? recording.note : nil
        rejected = recording.rejected
    }
}

/// The model-owned identity for all recording-backed progress surfaces. The
/// Static portion is shared with the narrower curve identity; movement adds
/// only the measured execution payload that the tile/detail sheet displays.
public struct ForceProgressRecordingIdentity: Equatable, Sendable {
    public let staticCurve: StaticCurveRecordingIdentity
    public let movementMetrics: ReverseActionMetrics?

    public init(_ recording: TindeqRecording) {
        staticCurve = StaticCurveRecordingIdentity(recording)
        movementMetrics = recording.protocolMode == .reverseAction
            && recording.source != .manual
            ? recording.setMetrics
            : nil
    }
}

/// Model-owned mutation contract for the Force progress curve task. The
/// AppModel mirrors `value` into its observed revision; keeping the
/// counters here makes every invalidate boundary testable without compiling
/// the UIKit/SwiftUI target.
public enum ForceProgressInputMutation: Equatable, Sendable {
    case recordings
    case pendingRecordings
    case localSamples
    case curveModel
    case accountReset
}

public struct ForceProgressInputRevision: Equatable, Sendable {
    public private(set) var value: UInt64
    public private(set) var localSampleGeneration: UInt64

    public init(value: UInt64 = 0, localSampleGeneration: UInt64 = 0) {
        self.value = value
        self.localSampleGeneration = localSampleGeneration
    }

    @discardableResult
    public mutating func apply(_ mutation: ForceProgressInputMutation) -> UInt64 {
        if mutation == .localSamples {
            localSampleGeneration &+= 1
        }
        value &+= 1
        return value
    }
}

/// O(1) SwiftUI task identity for the selected Static curve. The recording
/// metadata is represented by the AppModel revision, not rebuilt in `body`.
public struct ForceProgressCurveInputKey: Hashable, Sendable {
    public let selectedTag: String?
    public let selectedSide: String?
    public let revision: UInt64
    public let accountUserID: UUID?
    public let accountEpoch: UInt64

    public init(
        selectedTag: String?,
        selectedSide: String?,
        revision: UInt64,
        accountUserID: UUID?,
        accountEpoch: UInt64
    ) {
        self.selectedTag = selectedTag
        self.selectedSide = selectedSide
        self.revision = revision
        self.accountUserID = accountUserID
        self.accountEpoch = accountEpoch
    }
}

/// O(1) render boundary for the two progress tiles. Raw recording arrays and
/// fitted curve samples stay outside this key; model-owned revisions signal
/// when the child is allowed to rebuild its derived progress values.
public struct ForceProgressCardKey: Hashable, Sendable {
    public let progressRevision: UInt64
    public let selectedTag: String?
    public let selectedSide: String?
    public let hasLoadedRecordings: Bool
    public let curveRevision: UInt64

    public init(
        progressRevision: UInt64,
        selectedTag: String?,
        selectedSide: String?,
        hasLoadedRecordings: Bool,
        curveRevision: UInt64
    ) {
        self.progressRevision = progressRevision
        self.selectedTag = selectedTag
        self.selectedSide = selectedSide
        self.hasLoadedRecordings = hasLoadedRecordings
        self.curveRevision = curveRevision
    }
}

public struct StaticCapacityEvidence: Equatable, Sendable {
    /// Complete selected Static rows for the full trend and the unsliced count.
    public let trendRecordings: [TindeqRecording]
    /// The compact tile's intentionally limited recent window.
    public let recentRecordings: [TindeqRecording]
    /// Selected Static rows safe to pass to the existing curve fitter.
    public let curveFitRecordings: [TindeqRecording]

    public init(
        trendRecordings: [TindeqRecording],
        recentRecordings: [TindeqRecording],
        curveFitRecordings: [TindeqRecording]
    ) {
        self.trendRecordings = trendRecordings
        self.recentRecordings = recentRecordings
        self.curveFitRecordings = curveFitRecordings
    }
}

public struct StaticCapacityProgress: Equatable, Sendable {
    public let recordings: [TindeqRecording]
    /// The unsliced number of rows in the selected Static scope.
    public let totalCount: Int
    public let latestPeakKilograms: Double?
    public let bestPeakKilograms: Double?

    public init(
        recordings: [TindeqRecording],
        totalCount: Int,
        latestPeakKilograms: Double?,
        bestPeakKilograms: Double?
    ) {
        self.recordings = recordings
        self.totalCount = totalCount
        self.latestPeakKilograms = latestPeakKilograms
        self.bestPeakKilograms = bestPeakKilograms
    }
}

public struct MovementProgress: Equatable, Sendable {
    public let recordings: [TindeqRecording]
    public let totalCount: Int
    public let latestMetrics: ReverseActionMetrics?

    public init(
        recordings: [TindeqRecording],
        totalCount: Int,
        latestMetrics: ReverseActionMetrics?
    ) {
        self.recordings = recordings
        self.totalCount = totalCount
        self.latestMetrics = latestMetrics
    }
}
