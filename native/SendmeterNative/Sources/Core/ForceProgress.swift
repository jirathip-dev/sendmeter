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

    public static func staticCapacityProgress(
        recordings: [TindeqRecording],
        tag: String? = nil,
        side: TindeqSide? = nil
    ) -> StaticCapacityProgress {
        let rows = trendChartRecordings(recordings, tag: tag, side: side)
        let recent = Array(rows.suffix(recentLimit))
        return StaticCapacityProgress(
            recordings: recent,
            totalCount: rows.count,
            latestPeakKilograms: recent.last?.peakKilograms,
            bestPeakKilograms: recent.compactMap(\.peakKilograms).max()
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
