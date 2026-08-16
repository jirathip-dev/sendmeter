import Foundation

/// The four TRAINABLE training qualities a Tindeq session's recordings
/// classify into — the web's `TrainingQuality` (power / strength /
/// power-endurance / endurance). Maintenance zones (warmup, prehab) are NOT
/// qualities: they have no set-duration divisor and are always recorded
/// explicitly rather than inferred from duration.
public enum ZoneQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case power
    case strength
    case powerEndurance = "power-endurance"
    case endurance

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .power: return "Power"
        case .strength: return "Strength"
        case .powerEndurance: return "Pow End"
        case .endurance: return "Endurance"
        }
    }
}

/// Zone classification + duration-normalized set counts (#630): which
/// training QUALITY a session's recordings belong to — the same
/// classification the web's Training-balance card and History zone badge
/// (#214) use. Port of `src/lib/zoneHistory.ts`'s `classifyZone` /
/// `zoneSets` / `dominantZone`.
public enum ZoneMix {
    /// One zone's protocol "set" length in seconds — reps × hold from
    /// ZONE_PROTOCOLS (web force-curve.ts): power 5s×6, strength 10s×5,
    /// power-endurance 7s×6, endurance 30s×1×8 (endurance's 8 sets are
    /// deliberately multiplied in — its training-balance unit is the whole
    /// 8-hold protocol, #320).
    public static func zoneSetDurationSeconds(_ zone: ZoneQuality) -> Double {
        switch zone {
        case .power: return 5 * 6
        case .strength: return 10 * 5
        case .powerEndurance: return 7 * 6
        case .endurance: return 30 * 1 * 8
        }
    }

    /// Buckets by hold length around each zone's anchor hold (power 5s ·
    /// power-endurance 7s · strength 10s · endurance 30s). Nil for a
    /// sub-1s stray blip.
    public static func classifyZone(durationSeconds: Double) -> ZoneQuality? {
        guard durationSeconds >= 1 else { return nil }
        if durationSeconds <= 6 { return .power }
        if durationSeconds <= 8.5 { return .powerEndurance }
        if durationSeconds <= 20 { return .strength }
        return .endurance
    }

    /// The zone a recording belongs to: the zone it was performed under wins
    /// regardless of duration; only a recording WITHOUT one is inferred from
    /// duration (web `recordingZone`). Native's recorded zones map onto the
    /// four qualities; native "capacity" (a native-only zone value the web's
    /// enum doesn't know) reads as endurance — long holds — rather than
    /// dropping the recording from the mix. Warmup/prehab are maintenance and
    /// excluded by construction (nil), so the balance counts only real work.
    public static func zone(for recording: TindeqRecording) -> ZoneQuality? {
        if let recorded = recording.zone {
            switch recorded {
            case .power: return .power
            case .strength: return .strength
            case .endurance: return .endurance
            case .capacity: return .endurance
            case .warmup, .prehab: return nil
            }
        }
        return classifyZone(durationSeconds: Double(recording.durationMilliseconds) / 1_000)
    }

    /// Duration-normalised set count per zone: total hold time recorded in a
    /// zone divided by that zone's own protocol set length, so the mix is
    /// weighted by time actually spent, not rep count (web `zoneSets`).
    public static func zoneSets(_ recordings: [TindeqRecording]) -> [ZoneQuality: Double] {
        var seconds: [ZoneQuality: Double] = [:]
        for recording in recordings {
            guard let zone = zone(for: recording) else { continue }
            seconds[zone, default: 0] += Double(recording.durationMilliseconds) / 1_000
        }
        var sets: [ZoneQuality: Double] = [:]
        for zone in ZoneQuality.allCases {
            let divisor = zoneSetDurationSeconds(zone)
            sets[zone] = divisor > 0 ? (seconds[zone] ?? 0) / divisor : 0
        }
        return sets
    }

    /// Tie-break order for `dominantZone` (web `ZONE_ORDER`).
    public static let zoneOrder: [ZoneQuality] = [.power, .strength, .powerEndurance, .endurance]

    /// The zone with the highest duration-normalised set count — the badge a
    /// Tindeq session shows. Nil when every zone is zero (no classifiable
    /// holds). Ties break deterministically by `zoneOrder`.
    public static func dominantZone(_ sets: [ZoneQuality: Double]) -> ZoneQuality? {
        guard let max = zoneOrder.map({ sets[$0] ?? 0 }).max(), max > 0 else { return nil }
        return zoneOrder.first { (sets[$0] ?? 0) == max }
    }

    /// Whether a recording counts as maximal-intent EFFORT evidence — the
    /// web's `isEffortRecording` (`zoneHistory.ts`): NOT a maintenance zone.
    /// `zone(for:)` returns nil for warmup/prehab by construction, so this is
    /// simply `zone != nil`. Warm-up and Prehab are deliberately submaximal
    /// maintenance work; neither can stand in for a maximal-intent
    /// observation in the curve fit, PR, or trend (#651).
    public static func isEffortRecording(_ recording: TindeqRecording) -> Bool {
        zone(for: recording) != nil
    }

    /// The web's recovery/salvage-blob exclusion (#486, #651): a whole-buffer
    /// blob whose `durationMs` is inflated by inter-rep rests and whose
    /// `avgKg` is deflated — exactly the two fields `computeForceCurve`
    /// consumes. The CONJUNCTION matters: zone == nil AND protocolRunID ==
    /// nil AND a known salvage note. Note text alone gives false positives on
    /// legitimate reconstructions. Mirrors `SALVAGE_BLOB_NOTES` +
    /// `isRecoveredRecording` in `zoneHistory.ts`.
    public static func isRecoveredRecording(_ recording: TindeqRecording) -> Bool {
        guard recording.zone == nil,
              recording.protocolRunID == nil
        else { return false }
        return recording.note == "Recovered after sign-out"
            || recording.note == "Recovered after connection loss"
    }

    /// The web's `curveCandidateRecordings` filter for the curve FIT
    /// (`zoneHistory.ts`): effort AND measured AND static-capacity AND not a
    /// salvage blob, with a peak and average present. Deliberately does NOT
    /// exclude recovery from PR/trend/asymmetry/balance — a blob's `peakKg`
    /// is a max over samples and is unaffected by rest contamination (#486,
    /// #651). Only the fit consumes this.
    public static func isCurveFitCandidate(_ recording: TindeqRecording) -> Bool {
        guard isEffortRecording(recording),
              recording.peakKilograms != nil,
              recording.averageKilograms != nil
        else { return false }
        return !isRecoveredRecording(recording)
    }
}
