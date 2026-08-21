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

    /// A stable, metadata-only identity for the input to a selected Static
    /// curve. The full recording list is retained here rather than a view
    /// window: an old row can enter/leave `pickCurveRecordings` when its tag,
    /// side, duration, date, or force metadata changes. Raw samples are not
    /// part of the identity; `localSampleGeneration` is the AppModel-owned
    /// invalidation boundary for the separate in-memory sample store.
    public static func staticCurveInputIdentity(
        recordings: [TindeqRecording],
        tag: String?,
        side: TindeqSide?,
        pendingRecordingIDs: Set<UUID> = Set<UUID>(),
        locallyAvailableSampleIDs: Set<UUID> = Set<UUID>(),
        localSampleGeneration: UInt64 = 0,
        accountUserID: UUID? = nil,
        accountEpoch: UInt64 = 0
    ) -> StaticCurveInputIdentity {
        let recordingIdentities = recordings
            .map(StaticCurveRecordingIdentity.init)
            .sorted { lhs, rhs in
                lhs.id.uuidString < rhs.id.uuidString
            }
        return StaticCurveInputIdentity(
            selectedTag: tag,
            selectedSide: side?.rawValue,
            recordings: recordingIdentities,
            pendingRecordingIDs: pendingRecordingIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            locallyAvailableSampleIDs: locallyAvailableSampleIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            localSampleGeneration: localSampleGeneration,
            accountUserID: accountUserID,
            accountEpoch: accountEpoch
        )
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

/// Complete task identity for the side/tag-scoped Static curve request.
/// Account and optimistic/local-sample generations are included because the
/// same visible recording IDs can otherwise be reused across an account
/// switch or a pending-sample replacement.
public struct StaticCurveInputIdentity: Hashable, Sendable {
    public let selectedTag: String?
    public let selectedSide: String?
    public let recordings: [StaticCurveRecordingIdentity]
    public let pendingRecordingIDs: [UUID]
    public let locallyAvailableSampleIDs: [UUID]
    public let localSampleGeneration: UInt64
    public let accountUserID: UUID?
    public let accountEpoch: UInt64

    public init(
        selectedTag: String?,
        selectedSide: String?,
        recordings: [StaticCurveRecordingIdentity],
        pendingRecordingIDs: [UUID],
        locallyAvailableSampleIDs: [UUID],
        localSampleGeneration: UInt64,
        accountUserID: UUID?,
        accountEpoch: UInt64
    ) {
        self.selectedTag = selectedTag
        self.selectedSide = selectedSide
        self.recordings = recordings
        self.pendingRecordingIDs = pendingRecordingIDs
        self.locallyAvailableSampleIDs = locallyAvailableSampleIDs
        self.localSampleGeneration = localSampleGeneration
        self.accountUserID = accountUserID
        self.accountEpoch = accountEpoch
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
