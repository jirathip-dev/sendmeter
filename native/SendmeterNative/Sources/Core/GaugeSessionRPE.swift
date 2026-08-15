import Foundation
import SendLogWatchCore

/// A tag's fitted critical-force curve, the per-rep `cf`/`wPrime` a gauge
/// session's W'-depletion prediction reads (mirrors the web's cached
/// `TagCurve` registry — `src/lib/repo/tindeq.ts` `fetchTagCurves`, which is
/// itself partitioned by execution modality).
public struct TagForceCurve: Codable, Equatable, Sendable {
    public let tag: String
    /// "static" or "reverse_action" — the modality of the recordings the
    /// curve was fitted from. A session can mix modalities, so the curve is
    /// resolved per rep, never per session.
    public let modality: String
    public let cf: Double
    public let wPrime: Double

    public init(tag: String, modality: String, cf: Double, wPrime: Double) {
        self.tag = tag
        self.modality = modality
        self.cf = cf
        self.wPrime = wPrime
    }
}

/// The phone's prediction result. Kept as its own type (not
/// `SendLogWatchCore.PredictedRPE`, whose initializer is internal) so the
/// prehab-only branch can express its measured-zero outcome; the shape is
/// identical to the watch's `PredictedRPE` and the web's `PredictedRpe`.
public struct GaugeSessionRPEPrediction: Equatable, Sendable {
    public let rpe: Double
    /// False when the session fell back (no rep had a curve AND no
    /// known-minimal rep supplied a measured zero). Either way the value is
    /// written with `rpe_confirmed = false` — nobody reviewed it.
    public let fromCurve: Bool
    /// Σ d_i, nil when nothing could be measured.
    public let load: Double?

    public init(rpe: Double, fromCurve: Bool, load: Double?) {
        self.rpe = rpe
        self.fromCurve = fromCurve
        self.load = load
    }

    public init(_ predicted: PredictedRPE) {
        self.rpe = predicted.rpe
        self.fromCurve = predicted.fromCurve
        self.load = predicted.load
    }
}

/// Phone gauge-session RPE prediction (#627): the web predicts at session end
/// from W'-depletion (`src/lib/gaugeSessionEnd.ts` `predictGaugeSessionRpe` →
/// `rpeDepletion.ts`), and the watch already runs the identical model from
/// `SendLogWatchCore/RPEDepletion.swift`. The app links SendLogWatchCore, so
/// this layer REUSES `RPEDepletion` for the math instead of reimplementing it
/// — the only thing the phone adds is the mapping from its own recordings +
/// fitted curves onto `DepletionRep`, plus the one web-only distinction the
/// watch model cannot express: a Prehab rep is known-minimal BY CONSTRUCTION
/// (`isDepletionEffortRecording`, `src/lib/zoneHistory.ts`), so its depletion
/// is a measured zero even without a fitted curve.
public enum GaugeSessionRPE {
    public static func modality(of recording: TindeqRecording) -> String {
        recording.protocolMode == .reverseAction ? "reverse_action" : "static"
    }

    /// The web's per-rep tag→curve lookup (`predictGaugeSessionRpe`): each rep
    /// is measured against ITS OWN tag's curve for that rep's modality.
    public static func predict(
        recordings: [TindeqRecording],
        curves: [TagForceCurve]
    ) -> GaugeSessionRPEPrediction {
        let byTagModality = Dictionary(
            curves.map { ("\($0.tag)|\($0.modality)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let effortReps = recordings.compactMap { recording -> DepletionRep? in
            let isEffort = recording.zone != .prehab
            guard isEffort else { return nil }
            let key = "\(recording.tag)|\(modality(of: recording))"
            let curve = byTagModality[key]
            return DepletionRep(
                peakKg: recording.peakKilograms ?? 0,
                durationS: Double(recording.durationMilliseconds) / 1_000,
                cf: curve?.cf,
                wPrime: curve?.wPrime
            )
        }
        let hasKnownMinimalRep = recordings.contains { $0.zone == .prehab }

        let predicted = RPEDepletion.predictSessionRPE(effortReps)
        if predicted.fromCurve || !hasKnownMinimalRep {
            return GaugeSessionRPEPrediction(predicted)
        }
        // Every rep was known-minimal (Prehab): the session's load is a
        // measured zero, not an unknown — the web's `sessionDepletion` reads
        // exactly this via the non-effort rep's `0` contribution.
        return GaugeSessionRPEPrediction(
            rpe: RPEDepletion.rpeForDepletion(0),
            fromCurve: true,
            load: 0
        )
    }
}

/// Session duration in minutes from the recordings' actual span — first
/// recording start to last recording end — clamped to the DB's 1..600
/// `sessions.duration_min` bound. Mirrors `computeGroupDurationMin` /
/// `clampDurationMin` (`src/lib/duration.ts`), including the `null` for an
/// empty list (callers fall back to the wall-clock estimate).
public enum GaugeSessionDuration {
    public static func clamp(minutes: Double) -> Int {
        max(1, min(600, Int(minutes.rounded())))
    }

    public static func spanMinutes(recordings: [TindeqRecording]) -> Int? {
        guard !recordings.isEmpty else { return nil }
        let starts = recordings.map(\.recordedAt.timeIntervalSince1970)
        let ends = recordings.map { $0.recordedAt.timeIntervalSince1970 + Double($0.durationMilliseconds) / 1_000 }
        let spanSeconds = (ends.max() ?? 0) - (starts.min() ?? 0)
        return clamp(minutes: spanSeconds / 60)
    }
}

/// The auto-logged gauge session's note: "N recordings · tag1, tag2" —
/// identical shape to the web's `endGaugeSession` note and the watch's
/// `PendingTindeqSession.build` ("N recording(s)").
public enum GaugeSessionNote {
    public static func build(recordings: [TindeqRecording]) -> String {
        let count = recordings.count
        let tags = recordings.map(\.tag).filter { !$0.isEmpty }.unique()
        var parts = ["\(count) recording\(count == 1 ? "" : "s")"]
        if !tags.isEmpty {
            parts.append(tags.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

private extension Array where Element == String {
    func unique() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
