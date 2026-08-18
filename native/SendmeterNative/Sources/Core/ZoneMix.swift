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

    /// The long form the Focus-Next reason sentence uses — the web's `label`
    /// record in `recommendZone` ("power-endurance", not the bar's short
    /// "Pow End") (#653 review finding 13).
    public var longLabel: String {
        switch self {
        case .power: return "power"
        case .strength: return "strength"
        case .powerEndurance: return "power-endurance"
        case .endurance: return "endurance"
        }
    }
}

/// Zone classification + duration-normalized set counts (#630): which
/// training QUALITY a session's recordings belong to — the same
/// classification the web's Training-balance card and History zone badge
/// (#214) use. Port of `src/lib/zoneHistory.ts`'s `classifyZone` /
/// `zoneSets` / `dominantZone`.
public enum ZoneMix {
    /// One zone's protocol prescription — the single source of truth for the
    /// web's `ZONE_PROTOCOLS` table (`force-curve.ts:444-453`), from which the
    /// set-duration divisor, the guided preset, and the duration bands are all
    /// derived so they can't drift apart (#653 review finding 11).
    public struct ZoneProtocol {
        public let holdSeconds: Int
        public let restBetweenRepetitionsSeconds: Int
        public let repetitions: Int
        /// Sets. Endurance is modeled as 1 rep × 8 sets (#320) so each 30s
        /// recovery is a set boundary.
        public let sets: Int
        public let restBetweenSetsSeconds: Int
        /// True only for endurance: its training-balance unit is the WHOLE
        /// 8-hold protocol, so `sets` is multiplied into the set duration.
        /// Every other zone's unit is one round (holdS × reps), deliberately
        /// not multiplied by the number of rounds (web `zoneSetDurationS`).
        public let setDurationIncludesSets: Bool

        public init(
            holdSeconds: Int,
            restBetweenRepetitionsSeconds: Int,
            repetitions: Int,
            sets: Int,
            restBetweenSetsSeconds: Int,
            setDurationIncludesSets: Bool = false
        ) {
            self.holdSeconds = holdSeconds
            self.restBetweenRepetitionsSeconds = restBetweenRepetitionsSeconds
            self.repetitions = repetitions
            self.sets = sets
            self.restBetweenSetsSeconds = restBetweenSetsSeconds
            self.setDurationIncludesSets = setDurationIncludesSets
        }

        /// The training-balance set length: holdS × reps × sets for endurance
        /// (its unit is the whole 8-hold protocol, #320), holdS × reps for the
        /// others (web `zoneSetDurationS`).
        public var setDurationSeconds: Double {
            let setsFactor = setDurationIncludesSets ? Double(sets) : 1
            return Double(holdSeconds) * Double(repetitions) * setsFactor
        }
    }

    /// ZONE_PROTOCOLS (web `force-curve.ts`): power 5s×6, strength 10s×5,
    /// power-endurance 7s×6, endurance 30s×1×8.
    public static let zoneProtocols: [ZoneQuality: ZoneProtocol] = [
        .power: ZoneProtocol(holdSeconds: 5, restBetweenRepetitionsSeconds: 150, repetitions: 6, sets: 1, restBetweenSetsSeconds: 0),
        .strength: ZoneProtocol(holdSeconds: 10, restBetweenRepetitionsSeconds: 150, repetitions: 5, sets: 1, restBetweenSetsSeconds: 0),
        .powerEndurance: ZoneProtocol(holdSeconds: 7, restBetweenRepetitionsSeconds: 3, repetitions: 6, sets: 4, restBetweenSetsSeconds: 120),
        .endurance: ZoneProtocol(holdSeconds: 30, restBetweenRepetitionsSeconds: 0, repetitions: 1, sets: 8, restBetweenSetsSeconds: 30, setDurationIncludesSets: true)
    ]

    /// One zone's protocol "set" length in seconds — derived from the single
    /// `zoneProtocols` table (web ZONE_PROTOCOLS): power 5s×6, strength 10s×5,
    /// power-endurance 7s×6, endurance 30s×1×8 (endurance's 8 sets are
    /// deliberately multiplied in — its training-balance unit is the whole
    /// 8-hold protocol, #320).
    public static func zoneSetDurationSeconds(_ zone: ZoneQuality) -> Double {
        zoneProtocols[zone]?.setDurationSeconds ?? 0
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
            case .powerEndurance: return .powerEndurance
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

// MARK: - Training balance (web `zoneHistory.ts` — #653)

/// The curve signal `recommendZone` consumes — CF as a fraction of the
/// predicted 5s peak, the exact fields the web's `ForceCurveModel` exposes
/// (`force-curve.ts`: `cf`, `maxF`, `wPrime`). Native callers build this from
/// whichever fit they hold: `ForceCurveModel` (cf + maxF + impulse) or the
/// cached `TagForceCurve` (cf + wPrime + the fit's max force). The peak is
/// always `min(maxF, cf + W′/5)` exactly like web `predictForce`, so a
/// low-W′/high-maxF fit is capped and the bias matches the web's (#653 review
/// finding 7).
public struct ZoneCurveInput: Sendable, Equatable {
    public let cf: Double?
    /// The fit's maximum force (web `maxF`).
    public let maxForce: Double?
    public let wPrime: Double?

    public init(cf: Double?, maxForce: Double?, wPrime: Double?) {
        self.cf = cf
        self.maxForce = maxForce
        self.wPrime = wPrime
    }

    /// From a full `ForceCurveModel` — the web's exact shape.
    public init(_ model: ForceCurveModel) {
        self.init(
            cf: model.criticalForceKilograms,
            maxForce: model.maximumForceKilograms,
            wPrime: model.impulseAboveCriticalForceKilogramSeconds
        )
    }

    /// From the native cached tag curve, which now carries the fit's maximum
    /// force so the peak prediction is capped exactly like the web's.
    public init(_ curve: TagForceCurve) {
        self.init(cf: curve.cf, maxForce: curve.maxForceKilograms, wPrime: curve.wPrime)
    }
}

extension ZoneMix {
    /// Trailing-window variant of `zoneSets` (#653): the same duration-
    /// normalised set counts, restricted to recordings within `windowDays` of
    /// `now` — the window the Training-balance card is scoped to. `recordedAt`
    /// is an instant: a recording at exactly the cutoff timestamp is kept
    /// (the web's `t >= cutoff`), and an unparseable date is dropped rather
    /// than credited.
    public static func zoneTrainingSets(
        _ recordings: [TindeqRecording],
        now: Date,
        windowDays: Int = 28
    ) -> [ZoneQuality: Double] {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let kept = recordings.filter { $0.recordedAt >= cutoff }
        return zoneSets(kept)
    }

    /// The holds a trailing window keeps — mirrors `zoneTrainingSets`' filter
    /// exactly (recordings at or after the cutoff). Exported so the detail
    /// sheet scopes its hold lists with the same rule that scopes the bars,
    /// instead of a second copy of the cutoff rule (web `holdsInWindow`).
    public static func holdsInWindow(
        _ recordings: [TindeqRecording],
        now: Date,
        windowDays: Int = 28
    ) -> [TindeqRecording] {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        return recordings.filter { $0.recordedAt >= cutoff }
    }

    /// The web's `recommendZone` (#653): the least-trained quality by
    /// duration-normalised set count, with the force curve breaking near-ties.
    /// `ZoneMix.tieBandSets` (web `TIE_BAND_SETS`) is the band within which two
    /// zones count as "roughly equally under-trained"; `ZoneMix.curveBiasRatio`
    /// (web `CURVE_BIAS_RATIO`) is the CF/peak threshold
    /// below which the curve reads as endurance-limited (endurance side wins)
    /// and at or above which strength-limited (strength side wins). Returns
    /// nil with no training at all. `model` is nil when no fit exists — the
    /// least-trained zone stands on its own.
    ///
    /// Two non-obvious web behaviours are preserved exactly: the unbiased pick
    /// is the argmin over the TIED set (never `tied[0]`, which would favour
    /// `power`), and the biased pick is the argmin over `tied ∩ biasSide`
    /// (again not `first`, which would favour `power` over a genuinely lower
    /// `strength`).
    public static func recommendZone(
        sets: [ZoneQuality: Double],
        model: ZoneCurveInput?
    ) -> ZoneRecommendation? {
        let total = zoneOrder.reduce(0) { $0 + (sets[$1] ?? 0) }
        guard total > 0 else { return nil }

        let minSets = zoneOrder.map { sets[$0] ?? 0 }.min() ?? 0
        let tied = zoneOrder.filter { (sets[$0] ?? 0) - minSets <= Self.tieBandSets }

        // Curve signal: CF (sustainable force) as a fraction of peak short-
        // hold force. Low → endurance-limited; high → strength-limited. Mirrors
        // the web's `predictForce(model, 5) || model.maxF` exactly:
        //   predictForce = maxF when wPrime is nil OR cf is nil
        //   otherwise    = min(maxF, cf + wPrime/5)
        // A wPrime of 0 or negative still computes the predicted peak (the web
        // guards only `wPrime !== null`), so `min(maxF, cf + w/5)` can bind at
        // cf itself — never treated as "no peak" (#653 review finding 8).
        var ratio: Double?
        if let model, let cf = model.cf {
            let peak: Double?
            if let wPrime = model.wPrime {
                let predicted = cf + wPrime / 5
                peak = model.maxForce.map { min($0, predicted) } ?? predicted
            } else {
                peak = model.maxForce
            }
            if let peak, peak > 0, peak.isFinite {
                ratio = cf / peak
            }
        }
        let enduranceSide: [ZoneQuality] = [.endurance, .powerEndurance]
        let strengthSide: [ZoneQuality] = [.power, .strength]
        let curveBias: ZoneCurveBias? = ratio == nil
            ? nil
            : (ratio! < Self.curveBiasRatio ? .endurance : .strength)
        let bias: [ZoneQuality]? = curveBias.map {
            $0 == .endurance ? enduranceSide : strengthSide
        }

        // Unbiased pick: the true minimum among the tied candidates. `tied`
        // admits candidates that aren't the actual minimum, so the first
        // entry in ZONE_ORDER (power) must not win by order alone.
        var zone = tied.reduce(tied[0]) { (sets[$1] ?? 0) < (sets[$0] ?? 0) ? $1 : $0 }
        let unbiasedZone = zone
        if tied.count > 1, let bias {
            let biased = tied.filter { bias.contains($0) }
            if !biased.isEmpty {
                zone = biased.reduce(biased[0]) { (sets[$1] ?? 0) < (sets[$0] ?? 0) ? $1 : $0 }
            }
        }

        let roundedSets = (sets[zone] ?? 0).roundedToTenths
        let setWord = roundedSets == 1 ? "set" : "sets"
        var reason = "\(roundedSets.fmtTenths) \(zone.longLabel) \(setWord) in the last 4 weeks"
        if let ratio {
            reason += " · CF is \(Int((ratio * 100).rounded()))% of peak"
        }
        return ZoneRecommendation(
            zone: zone,
            reason: reason,
            detail: ZoneRecommendationDetail(
                minSets: minSets,
                tied: tied,
                unbiasedZone: unbiasedZone,
                curveRatio: ratio,
                curveBias: curveBias,
                biasChangedPick: zone != unbiasedZone
            )
        )
    }

    /// The two counts `TrainingBalanceDetailView`'s "what this counts" copy
    /// states (#653): how many holds fed the numbers, and how many of those
    /// store their own zone vs. have it inferred. Both computed over EFFORT
    /// recordings only — warm-up/prehab are always recorded but never feed
    /// the balance, so counting them in either figure would make the copy
    /// literally false (web `balanceScopeCounts`).
    public static func balanceScopeCounts(
        _ recordings: [TindeqRecording]
    ) -> (effortCount: Int, recordedCount: Int) {
        let effort = recordings.filter(isEffortRecording)
        let recorded = effort.filter { $0.zone != nil }.count
        return (effort.count, recorded)
    }

    /// Per-zone breakdown of a set of holds (#653) — the arithmetic BEHIND
    /// the bars, so the detail sheet can show its working instead of
    /// asserting a number (web `zoneBreakdown.ts`). Every bucket uses the same
    /// `zone(for:)` and the same `zoneSetDurationSeconds` as `zoneSets`, so the
    /// two agree bit-for-bit; only the intermediates are kept.
    public static func zoneBreakdown(
        _ recordings: [TindeqRecording]
    ) -> ZoneBreakdown {
        var holdsByZone: [ZoneQuality: [ZoneHold]] = [:]
        var unclassified: [ZoneHold] = []
        var excluded: [ZoneHold] = []
        for recording in recordings {
            let durationS = Double(recording.durationMilliseconds) / 1_000
            let source: ZoneSource = recording.zone == nil ? .inferred : .recorded
            let hold = ZoneHold(recording: recording, durationS: durationS, source: source)
            // Maintenance zones are recorded facts, but deliberately not
            // trainable — they land in `excluded`, never in `unclassified`
            // (web `zoneBreakdown` checks maintenance FIRST).
            if recording.zone == .warmup || recording.zone == .prehab {
                excluded.append(hold)
                continue
            }
            guard let zone = zone(for: recording) else {
                // Only an INFERRED zone can fail here — the sub-1s stray-blip
                // rule. A recorded zone is honoured at any duration.
                unclassified.append(hold)
                continue
            }
            holdsByZone[zone, default: []].append(hold)
        }
        let zones = Dictionary(
            uniqueKeysWithValues: ZoneQuality.allCases.map { zone in
                let holds = holdsByZone[zone] ?? []
                var totalHoldS = 0.0
                for hold in holds { totalHoldS += hold.durationS }
                let setDurationS = zoneSetDurationSeconds(zone)
                let recordedCount = holds.filter { $0.source == .recorded }.count
                return (
                    zone,
                    ZoneBreakdownEntry(
                        zone: zone,
                        holds: holds,
                        totalHoldS: totalHoldS,
                        setDurationS: setDurationS,
                        sets: setDurationS > 0 ? totalHoldS / setDurationS : 0,
                        recordedCount: recordedCount,
                        inferredCount: holds.count - recordedCount
                    )
                )
            }
        )
        return ZoneBreakdown(zones: zones, unclassified: unclassified, excluded: excluded)
    }

    /// The duration bands `classifyZone` applies, for the detail sheet's band
    /// table (web `ZONE_BANDS`). The zone → band mapping is looked up through
    /// `classifyZone` (see `band(for:)`), so the labels can't quietly drift
    /// from the rule they describe. The anchor is derived from the single
    /// `zoneProtocols` table, not hardcoded again (#653 review finding 11).
    public static let zoneBands: [ZoneBand] = [
        ZoneBand(zone: .power, band: "1–6s"),
        ZoneBand(zone: .powerEndurance, band: "6–8.5s"),
        ZoneBand(zone: .strength, band: "8.5–20s"),
        ZoneBand(zone: .endurance, band: "over 20s")
    ].map { ZoneBand(zone: $0.zone, band: $0.band, anchorS: anchorHoldSeconds($0.zone)) }

    /// The protocol's anchor hold seconds for a zone — the `holdS` of
    /// `ZONE_PROTOCOLS`, used for the breakdown's "holdS × N holds = set
    /// duration" identity.
    public static func anchorHoldSeconds(_ zone: ZoneQuality) -> Int {
        zoneProtocols[zone]?.holdSeconds ?? 1
    }

    /// The band a single hold's DURATION falls in, or nil for a sub-1s blip —
    /// the inference rule, not necessarily the hold's zone (a recording that
    /// carries its own zone was never bucketed by this).
    public static func band(for durationS: Double) -> ZoneBand? {
        guard let zone = classifyZone(durationSeconds: durationS) else { return nil }
        return zoneBands.first(where: { $0.zone == zone })
    }

    /// The caveat that belongs next to those bands (web `ZONE_BAND_CAVEAT`):
    /// a hold recorded under an armed zone/preset stores its zone as a fact;
    /// everything else has it inferred from hold length.
    public static let zoneBandCaveat = "A hold recorded under an armed zone or preset stores the zone it was performed under — those are marked \"recorded\" and use it as-is. Every other hold — anything saved before this app stored it, and any freehand pull with no protocol armed — has its zone inferred from how long the hold lasted. The power (5s), pow end (7s) and strength (10s) anchors sit close together, so short holds are inherently fuzzy: an inferred hold that lands on the wrong side of the 6s or 8.5s boundary shows up as fractional credit in the neighbouring zone rather than being smoothed away. Inferred holds under 1s are treated as stray blips and counted nowhere."

    /// Builds the guided-protocol preset a recommended zone arms — the native
    /// sibling of the web's `buildZoneSelection(...).protocol`, derived from
    /// the SAME `zoneProtocols` table the balance divisor reads, so a
    /// prescription change can never silently drift the two apart (#653 review
    /// finding 11). The caller sets this as the selected preset AND stamps the
    /// Force metadata `zone` with `recordedZone(for:)` so a recording saved
    /// under the run carries the quality it was performed under.
    public static func zonePreset(for zone: ZoneQuality) -> TindeqPreset {
        let prescription = zoneProtocols[zone] ?? ZoneProtocol(
            holdSeconds: 5,
            restBetweenRepetitionsSeconds: 150,
            repetitions: 6,
            sets: 1,
            restBetweenSetsSeconds: 0
        )
        return TindeqPreset(
            name: zone.label,
            holdSeconds: prescription.holdSeconds,
            repetitions: prescription.repetitions,
            sets: prescription.sets,
            restBetweenRepetitionsSeconds: prescription.restBetweenRepetitionsSeconds,
            restBetweenSetsSeconds: prescription.restBetweenSetsSeconds
        )
    }

    /// The `RecordedZone` a recommended zone's recordings are stamped with
    /// when its preset is armed — every zone has one, so a guided run's holds
    /// carry the performed quality as a fact instead of being re-inferred from
    /// measured duration (which hands-free start latency can skew across the
    /// 6s/8.5s band, #653 review finding 1).
    public static func recordedZone(for zone: ZoneQuality) -> RecordedZone? {
        switch zone {
        case .power: return .power
        case .strength: return .strength
        case .powerEndurance: return .powerEndurance
        case .endurance: return .endurance
        }
    }
    /// TIE_BAND_SETS (web `zoneHistory.ts`): zones within this many sets of
    /// the true minimum are treated as tied candidates for the curve bias to
    /// break.
    public static let tieBandSets = 0.5

    /// CURVE_BIAS_RATIO (web `zoneHistory.ts`): CF-to-peak ratio below which
    /// the curve reads as endurance-limited (and at or above which
    /// strength-limited).
    public static let curveBiasRatio = 0.35
}

public enum ZoneCurveBias: String, Sendable {
    case endurance
    case strength
}

public struct ZoneRecommendation: Sendable, Equatable {
    public let zone: ZoneQuality
    /// Short, explainable line: "1.5 strength sets in the last 4 weeks",
    /// plus " · CF is 33% of peak" when the curve had a say.
    public let reason: String
    public let detail: ZoneRecommendationDetail

    public init(zone: ZoneQuality, reason: String, detail: ZoneRecommendationDetail) {
        self.zone = zone
        self.reason = reason
        self.detail = detail
    }
}

public struct ZoneRecommendationDetail: Sendable, Equatable {
    /// Lowest set count across all four zones.
    public let minSets: Double
    /// Zones within `TIE_BAND_SETS` of `minSets` — the candidates.
    public let tied: [ZoneQuality]
    /// The pick before any curve bias: the least-trained tied candidate.
    public let unbiasedZone: ZoneQuality
    /// CF as a fraction of predicted 5s peak force; nil without a usable fit.
    public let curveRatio: Double?
    /// Which side of the tie the curve steers toward, if it has an opinion.
    public let curveBias: ZoneCurveBias?
    /// True when the bias actually moved the pick off `unbiasedZone`.
    public let biasChangedPick: Bool

    public init(
        minSets: Double,
        tied: [ZoneQuality],
        unbiasedZone: ZoneQuality,
        curveRatio: Double?,
        curveBias: ZoneCurveBias?,
        biasChangedPick: Bool
    ) {
        self.minSets = minSets
        self.tied = tied
        self.unbiasedZone = unbiasedZone
        self.curveRatio = curveRatio
        self.curveBias = curveBias
        self.biasChangedPick = biasChangedPick
    }
}

/// The duration band a hold's inference buckets into, for the detail sheet's
/// band table (#653, web `ZONE_BANDS`).
public struct ZoneBand: Sendable, Equatable {
    public let zone: ZoneQuality
    public let band: String
    public let anchorS: Int

    public init(zone: ZoneQuality, band: String, anchorS: Int = 0) {
        self.zone = zone
        self.band = band
        self.anchorS = anchorS
    }
}

/// Where a hold's zone came from (#653, web `ZoneSource`).
public enum ZoneSource: Sendable {
    case recorded
    case inferred
}

/// One hold bucketed into a zone's breakdown (web `ZoneHold`).
public struct ZoneHold: Sendable, Equatable {
    public let recording: TindeqRecording
    public let durationS: Double
    public let source: ZoneSource

    public init(recording: TindeqRecording, durationS: Double, source: ZoneSource) {
        self.recording = recording
        self.durationS = durationS
        self.source = source
    }
}

public struct ZoneBreakdownEntry: Sendable, Equatable {
    public let zone: ZoneQuality
    public let holds: [ZoneHold]
    /// Sum of those holds' durations, in seconds — the dividend.
    public let totalHoldS: Double
    /// This zone's protocol set length (holdS × reps) — the divisor.
    public let setDurationS: Double
    /// totalHoldS / setDurationS — identical to `zoneSets`' value.
    public let sets: Double
    /// How many of `holds` carried the zone vs. had it inferred.
    public let recordedCount: Int
    public let inferredCount: Int

    public init(
        zone: ZoneQuality,
        holds: [ZoneHold],
        totalHoldS: Double,
        setDurationS: Double,
        sets: Double,
        recordedCount: Int,
        inferredCount: Int
    ) {
        self.zone = zone
        self.holds = holds
        self.totalHoldS = totalHoldS
        self.setDurationS = setDurationS
        self.sets = sets
        self.recordedCount = recordedCount
        self.inferredCount = inferredCount
    }
}

public struct ZoneBreakdown: Sendable, Equatable {
    public let zones: [ZoneQuality: ZoneBreakdownEntry]
    /// Holds `classifyZone` refuses to bucket (under 1s — stray blips).
    public let unclassified: [ZoneHold]
    /// Warm-up and Prehab holds — recorded outside training balance BY DESIGN.
    public let excluded: [ZoneHold]

    public init(
        zones: [ZoneQuality: ZoneBreakdownEntry],
        unclassified: [ZoneHold],
        excluded: [ZoneHold]
    ) {
        self.zones = zones
        self.unclassified = unclassified
        self.excluded = excluded
    }
}

private extension Double {
    /// `Math.round(n * 10) / 10` — the web's `fmt1` / `roundedSets` rounding.
    var roundedToTenths: Double {
        (self * 10).rounded() / 10
    }

    /// Round to tenths, then format without a trailing `.0` — JS template
    /// interpolation of `Math.round(n * 10) / 10` ("1", "1.2"). The web's
    /// `recommendZone` reason reads this exact shape.
    var fmtTenths: String {
        let rounded = roundedToTenths
        if rounded == rounded.rounded() { return "\(Int(rounded))" }
        return String(format: "%.1f", rounded)
    }
}
