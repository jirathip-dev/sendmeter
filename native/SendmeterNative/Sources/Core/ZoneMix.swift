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

    /// Load-aware zone classification (#750, port of the web's
    /// `classifyZoneLoaded`): a protocol hold classifies on duration AND its
    /// resolved load once both are available, so a 7s hold at 85% of max
    /// force reads as Strength rather than being re-bucketed as Power
    /// Endurance from duration alone. Falls back to duration-only when there
    /// is no resolved load or no max-force reference to compare it against.
    public static func classifyZoneLoaded(
        durationSeconds: Double,
        targetKilograms: Double?,
        references: ZoneCurveInput?
    ) -> ZoneQuality? {
        guard durationSeconds >= 1 else { return nil }
        guard let targetKilograms,
              targetKilograms.isFinite,
              targetKilograms > 0,
              let maxForce = references?.maxForce,
              maxForce.isFinite,
              maxForce > 0 else {
            return classifyZone(durationSeconds: durationSeconds)
        }

        if let cf = references?.cf, cf.isFinite, cf > 0, targetKilograms <= cf {
            return .endurance
        }
        if targetKilograms >= 0.9 * maxForce, durationSeconds <= 6 {
            return .power
        }
        if targetKilograms >= 0.8 * maxForce, durationSeconds <= 20 {
            return .strength
        }
        if durationSeconds <= 20 {
            return .powerEndurance
        }
        return .endurance
    }

    /// The zone a hold saved from `preset` was performed under
    /// (#750, port of the web's `performedQuality`). A recommended protocol
    /// states its zone elsewhere; a saved/movement preset has no declared
    /// quality, so it uses the load-aware classifier with the preset's
    /// per-set hold and resolved target band.
    public static func performedQuality(
        preset: TindeqPreset?,
        targetBand: ForceTargetBand?,
        references: ZoneCurveInput?,
        setNumber: Int
    ) -> RecordedZone? {
        guard let preset else { return nil }
        let holdSeconds = Double(preset.holdSeconds(forSet: setNumber))
        guard let quality = classifyZoneLoaded(
            durationSeconds: holdSeconds,
            targetKilograms: targetBand?.kilograms,
            references: references
        ) else {
            return nil
        }
        return recordedZone(for: quality)
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
    /// #902: the smart Hill capability fit the web's `predictCapability`
    /// consumes for the power-endurance 60s reference (F60). Native fits are
    /// always the hill family (`ForceCurveEngine.fitCapability`), so no
    /// `family` discriminator is needed.
    public let capabilityFit: ForceCapabilityFit?

    public init(
        cf: Double?,
        maxForce: Double?,
        wPrime: Double?,
        capabilityFit: ForceCapabilityFit? = nil
    ) {
        self.cf = cf
        self.maxForce = maxForce
        self.wPrime = wPrime
        self.capabilityFit = capabilityFit
    }

    /// From a full `ForceCurveModel` — the web's exact shape.
    public init(_ model: ForceCurveModel) {
        self.init(
            cf: model.criticalForceKilograms,
            maxForce: model.maximumForceKilograms,
            wPrime: model.impulseAboveCriticalForceKilogramSeconds,
            capabilityFit: model.capabilityFit
        )
    }

    /// From the native cached tag curve, which now carries the fit's maximum
    /// force so the peak prediction is capped exactly like the web's.
    public init(_ curve: TagForceCurve) {
        self.init(
            cf: curve.cf,
            maxForce: curve.maxForceKilograms,
            wPrime: curve.wPrime,
            capabilityFit: curve.forceCurveModel?.capabilityFit
        )
    }

    /// #902: the power-endurance reference — the smart Hill capability curve
    /// predicted at 60 seconds (web `predictCapability(model, 60)`). Nil
    /// unless a usable hill fit exists (mirrors the web's validity gate:
    /// family is always `hill` natively, cf/maxF/tau/p finite with
    /// `maxF > cf`).
    public var f60Kilograms: Double? {
        guard let fit = capabilityFit,
              fit.criticalForceKilograms.isFinite, fit.criticalForceKilograms > 0,
              fit.maximumForceKilograms.isFinite,
              fit.maximumForceKilograms > fit.criticalForceKilograms,
              fit.tau.isFinite, fit.tau > 0,
              fit.exponent.isFinite, fit.exponent > 0,
              fit.sumSquaredError.isFinite, fit.sumSquaredError >= 0
        else { return nil }
        let predicted = ForceCurveEngine.predictCapabilityFit(fit, seconds: 60)
        return predicted.isFinite && predicted > 0 ? predicted : nil
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
        let curveBias: ZoneCurveBias? = ratio.map {
            $0 < Self.curveBiasRatio ? .endurance : .strength
        }
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
    /// finding 11). The caller sets this as the selected preset; the save-time
    /// zone then comes from `recordingZone(for: .suggestedZone(zone))` so a
    /// recording saved under the run carries the quality it was performed
    /// under, with no standalone zone setting involved.
    ///
    /// #902: the preset is transient and carries the zone quality + SL-97
    /// intensity so the target resolver reproduces the web's per-quality band.
    /// At 100% (or with no usable reference) the timing is exactly the
    /// `zoneProtocols` table — byte-identical to the pre-#902 preset; a
    /// non-100% intensity with a usable reference adjusts hold (and endurance
    /// sets) so the executed engine schedule matches the web's dose math.
    public static func zonePreset(
        for zone: ZoneQuality,
        intensityPercent: Int = Self.zoneIntensityDefault,
        references: ZoneCurveInput? = nil
    ) -> TindeqPreset {
        let prescription = zoneProtocols[zone] ?? ZoneProtocol(
            holdSeconds: 5,
            restBetweenRepetitionsSeconds: 150,
            repetitions: 6,
            sets: 1,
            restBetweenSetsSeconds: 0
        )
        let pct = clampZoneIntensity(intensityPercent)
        var holdSeconds = prescription.holdSeconds
        var sets = prescription.sets
        if pct != Self.zoneIntensityDefault,
           let references,
           let target = zoneTarget(for: zone, references: references, intensityPercent: pct) {
            holdSeconds = target.holdSeconds
            if let adjustedSets = target.adjustedSets {
                sets = adjustedSets
            }
        }
        return TindeqPreset(
            name: zone.label,
            holdSeconds: holdSeconds,
            repetitions: prescription.repetitions,
            sets: sets,
            restBetweenRepetitionsSeconds: prescription.restBetweenRepetitionsSeconds,
            restBetweenSetsSeconds: prescription.restBetweenSetsSeconds,
            zoneQuality: zone,
            zoneIntensityPercent: pct
        )
    }

    /// The web's `prehabTarget` (#325): 0.70 × critical force, falling back
    /// to 0.30 × best short-window force (`maxF`) when CF isn't fitted —
    /// `force-curve.ts:prehabTarget`. Rounded to 1 dp like the web. Returns
    /// nil when neither reference is usable, which is the web's "no usable
    /// force-curve target" gate (the Prehab chip is disabled).
    public static func prehabTargetKilograms(cf: Double?, maxForce: Double?) -> Double? {
        if let cf, cf > 0 {
            return ((cf * 0.70) * 10).rounded() / 10
        }
        if let maxForce, maxForce > 0 {
            return ((maxForce * 0.30) * 10).rounded() / 10
        }
        return nil
    }

    /// The best single-pull peak for a tag/side (web `maxF`), mirroring the
    /// `forceReferences` metadata filter: effort recordings only, side-resolved
    /// (unspecified reads both, else the exact side and then a side-less
    /// fallback). Used to resolve the maintenance fallback and gate the
    /// maintenance chips at pick time.
    public static func personalRecordKilograms(
        recordings: [TindeqRecording],
        tag: String,
        side: TindeqSide
    ) -> Double? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let byTag = recordings.filter {
            $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                && isEffortRecording($0)
        }
        let exactSide = byTag.filter { side == .unspecified || $0.side == side }
        let metadata = exactSide.isEmpty && side != .unspecified
            ? byTag.filter { $0.side == .unspecified }
            : exactSide
        return metadata.compactMap(\.peakKilograms).filter { $0 > 0 }.max()
    }

    /// Builds the guided-protocol preset a MAINTENANCE zone arms — the native
    /// sibling of the web's `buildWarmupSelection(...).protocol` /
    /// `buildPrehabSelection(...).protocol` (#710). Warm-up ramps
    /// 30% → 40% → 50% → 60% of PR (20s → 15s → 10s → 10s holds) and Prehab
    /// holds at a FIXED `0.70 × CF`, falling back to `0.30 × maxF` when CF
    /// isn't fitted — `buildPrehabSelection` stores `targetPct: null`,
    /// `pctBasis: "pr"` and a concrete `targetKg`, so the native preset uses
    /// `targetKilograms` rather than a `.criticalForce` percentage.
    /// Maintenance is deliberately NOT a `ZoneQuality`: it always records and
    /// never feeds training balance (web `zoneSets` drops it). Returns nil for
    /// a non-maintenance zone, and nil for a maintenance zone whose reference
    /// (PR for warm-up, CF-or-maxF for prehab) isn't usable — the caller gates
    /// the chip on that.
    public static func maintenancePreset(
        for zone: RecordedZone,
        model: ZoneCurveInput? = nil,
        personalRecord: Double? = nil
    ) -> TindeqPreset? {
        switch zone {
        case .warmup:
            // Warm-up is %-of-PR, resolved at launch from `forceReferences`;
            // gate the chip on a usable PR (web `warmupTarget` needs prKg>0).
            guard (personalRecord ?? model?.maxForce) ?? 0 > 0 else { return nil }
            return TindeqPreset(
                name: "Warm-up",
                holdSeconds: 20,
                holdSecondsBySet: [20, 15, 10, 10],
                repetitions: 1,
                sets: 4,
                restBetweenRepetitionsSeconds: 0,
                restBetweenSetsSeconds: 60,
                targetPercentage: 30,
                percentageBasis: .personalRecord,
                percentageStep: 10,
                alternateSides: true
            )
        case .prehab:
            guard let kg = prehabTargetKilograms(
                cf: model?.cf,
                maxForce: personalRecord ?? model?.maxForce
            ) else { return nil }
            return TindeqPreset(
                name: "Prehab",
                holdSeconds: 90,
                holdSecondsBySet: [90, 60, 30, 30],
                repetitions: 1,
                sets: 4,
                restBetweenRepetitionsSeconds: 0,
                restBetweenSetsSeconds: 20,
                targetKilograms: kg,
                percentageBasis: .personalRecord,
                alternateSides: true
            )
        default:
            return nil
        }
    }

    /// #711: the transient guided-protocol preset a MOVEMENT (resisted
    /// movement / reverse-action) selection arms — the native sibling of the
    /// web's `MOVEMENT_STARTER_PRESET`. Deliberately NOT persisted (like
    /// `zonePreset` / `maintenancePreset`), so it never appears in the user's
    /// own protocol library. Reverse Action stores one continuous recording
    /// per set, so the web's exact starter cadence (3s concentric · 1s
    /// eccentric) is mirrored here.
    public static func movementPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Movement Starter",
            holdSeconds: 40,
            repetitions: 10,
            sets: 3,
            restBetweenRepetitionsSeconds: 0,
            restBetweenSetsSeconds: 60,
            protocolMode: .reverseAction,
            cadenceOutSeconds: 3,
            cadenceReturnSeconds: 1,
            prepareSeconds: 5,
            setupNote: MovementTerminology.resistedMovement
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

    /// The save-time zone for the currently armed recording-context selection
    /// (#750). There is deliberately no persisted/standalone zone fallback:
    /// a suggestion states its own zone, a saved/movement preset is
    /// classified from its resolved protocol, and a free pull records nil.
    public static func recordingZone(
        for selection: ForceProtocolSelection,
        preset: TindeqPreset?,
        targetBand: ForceTargetBand?,
        references: ZoneCurveInput?,
        setNumber: Int = 1
    ) -> RecordedZone? {
        switch selection {
        case .free:
            return nil
        case .suggestedZone(let quality):
            return recordedZone(for: quality)
        case .suggestedMaintenance(let zone):
            return zone
        case .movement, .savedPreset:
            return performedQuality(
                preset: preset,
                targetBand: targetBand,
                references: references,
                setNumber: setNumber
            )
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

// MARK: - Zone target bands + adjustable session intensity (#902, SL-97 parity)

extension ZoneMix {
    /// The web's `ZONE_INTENSITY` dial constants (`force-curve.ts` SL-97):
    /// 60–110% in 5% steps, default 100. Applied to the four trainable
    /// qualities; maintenance protocols are deliberately unchanged.
    public static let zoneIntensityMinimum = 60
    public static let zoneIntensityMaximum = 110
    public static let zoneIntensityStep = 5
    public static let zoneIntensityDefault = 100

    /// `clampIntensity` (`force-curve.ts`): a raw pct is clamped to
    /// [60, 110] before any band/hold math.
    public static func clampZoneIntensity(_ percent: Int) -> Int {
        min(zoneIntensityMaximum, max(zoneIntensityMinimum, percent))
    }

    /// `roundHoldS` (`force-curve.ts`): holds <20s round to the nearest
    /// second; ≥20s round to the nearest 5s (the base protocols are already
    /// specified on those grids: 5/7/10s vs 30s).
    public static func roundHoldSeconds(_ seconds: Double) -> Int {
        seconds < 20
            ? Int(seconds.rounded())
            : Int((seconds / 5).rounded()) * 5
    }

    /// `HOLD_CLAMP_S` (`force-curve.ts`): the per-zone hold clamps for the
    /// above-CF zones. Endurance has no entry — its hold runs through
    /// `adjustedEndurance`'s own [20, 240] clamp.
    public static func holdClampSeconds(for quality: ZoneQuality) -> ClosedRange<Double>? {
        switch quality {
        case .power: return 3...15
        case .strength: return 5...30
        case .powerEndurance: return 5...15
        case .endurance: return nil
        }
    }

    /// `adjustedHoldAboveCf` (`force-curve.ts`): hold compensation for the
    /// above-CF zones (power / strength / power-endurance). Scaling the load
    /// down extends the hold so the per-rep dose — impulse above CF (W′
    /// cost), or plain force × time without a CF fit — stays constant. The
    /// returned value is clamped to the zone's hold clamp and rounded.
    public static func adjustedHoldAboveCf(
        quality: ZoneQuality,
        cf: Double?,
        wPrime: Double?,
        baseKilograms: Double,
        adjustedKilograms: Double,
        baseHoldSeconds: Double
    ) -> Int {
        guard let clamp = holdClampSeconds(for: quality) else {
            return roundHoldSeconds(baseHoldSeconds)
        }
        let holdSeconds: Double
        if let cf, cf.isFinite, wPrime != nil, baseKilograms > cf {
            if adjustedKilograms > cf {
                // Constant W′ cost: (F − CF) × t stays fixed.
                holdSeconds = (baseKilograms - cf) * baseHoldSeconds / (adjustedKilograms - cf)
            } else {
                // At/below CF the W′ cost is undefined (the hold could run
                // indefinitely) — cap at the zone's longest allowed hold.
                holdSeconds = clamp.upperBound
            }
        } else {
            // No CF fit — impulse-preserving fallback: force × time constant.
            holdSeconds = baseHoldSeconds * baseKilograms / adjustedKilograms
        }
        let clamped = min(clamp.upperBound, max(clamp.lowerBound, holdSeconds))
        return roundHoldSeconds(clamped)
    }

    /// `adjustedEndurance` (`force-curve.ts`): hold compensation for
    /// endurance (targets sit at/below CF, where W′ accounting is invalid).
    /// A pure heuristic of the intensity: total time-under-tension
    /// (sets × hold) stays roughly constant — hold scales by `(100/pct)²`
    /// clamped to [20, 240]s, and sets shrink to compensate (reps stays 1 —
    /// the 1×N protocol shape, #320). Like the web's exported function, the
    /// raw pct is deliberately NOT clamped to the UI dial here (callers on
    /// the zone path clamp first via `clampZoneIntensity`); the [20, 240]
    /// clamp is what makes extreme inputs safe.
    public static func adjustedEndurance(
        baseHoldSeconds: Int,
        baseSets: Int,
        intensityPercent: Int
    ) -> (holdSeconds: Int, sets: Int) {
        let rawHoldSeconds = Double(baseHoldSeconds) * pow(100.0 / Double(intensityPercent), 2)
        let holdSeconds = roundHoldSeconds(min(240, max(20, rawHoldSeconds)))
        let sets = min(
            baseSets,
            max(1, Int((Double(baseSets * baseHoldSeconds) / Double(holdSeconds)).rounded()))
        )
        return (holdSeconds, sets)
    }

    /// `zoneTarget` (`force-curve.ts`): the per-quality target band + adjusted
    /// hold for `quality` at `intensityPercent`, derived from `references`.
    /// Returns nil when the quality's required reference is unusable — the
    /// honest no-target state (the suggested chip is disabled; no stale band,
    /// no invented target). Every number mirrors the web's rounding exactly
    /// (kg to 1 dp; hold rounded per `roundHoldSeconds` after clamping).
    public static func zoneTarget(
        for quality: ZoneQuality,
        references: ZoneCurveInput,
        intensityPercent: Int = Self.zoneIntensityDefault
    ) -> ZoneQualityTarget? {
        let pct = clampZoneIntensity(intensityPercent)
        let scale = Double(pct) / 100
        let suffix = pct == Self.zoneIntensityDefault ? "" : " · intensity \(pct)%"
        let protocolHold = Double(anchorHoldSeconds(quality))

        let aboveCf: (
            reference: Double,
            baseKilograms: Double,
            lowMultiplier: Double,
            highMultiplier: Double,
            basis: String,
            referenceName: String
        )?
        switch quality {
        case .power, .strength:
            guard let maxForce = references.maxForce, maxForce.isFinite, maxForce > 0 else { return nil }
            let center: Double = quality == .power ? 0.95 : 0.85
            let lowMultiplier: Double = quality == .power ? 0.90 : 0.80
            let highMultiplier: Double = quality == .power ? 1.00 : 0.90
            let basis = quality == .power
                ? "90–100% of your best short-window force (\(fmtOneDecimal(maxForce)) kg)"
                : "80–90% of max (\(fmtOneDecimal(maxForce)) kg)"
            aboveCf = (
                maxForce,
                round1(maxForce * center),
                lowMultiplier,
                highMultiplier,
                basis,
                "From maxF \(fmtOneDecimal(maxForce)) kg"
            )
        case .powerEndurance:
            guard let f60 = references.f60Kilograms else { return nil }
            aboveCf = (
                f60,
                round1(f60),
                0.93,
                1.07,
                "Hill capability curve at 60 seconds",
                "From F60 \(fmtOneDecimal(f60)) kg"
            )
        case .endurance:
            aboveCf = nil
        }

        if let aboveCf {
            let adjustedKilograms = round1(aboveCf.baseKilograms * scale)
            let hold = adjustedHoldAboveCf(
                quality: quality,
                cf: references.cf,
                wPrime: references.wPrime,
                baseKilograms: aboveCf.baseKilograms,
                adjustedKilograms: adjustedKilograms,
                baseHoldSeconds: protocolHold
            )
            return ZoneQualityTarget(
                quality: quality,
                lowKilograms: round1(aboveCf.reference * aboveCf.lowMultiplier * scale),
                targetKilograms: adjustedKilograms,
                highKilograms: round1(aboveCf.reference * aboveCf.highMultiplier * scale),
                holdSeconds: hold,
                exactHoldSeconds: exactAdjustedHold(
                    quality: quality,
                    cf: references.cf,
                    wPrime: references.wPrime,
                    baseKilograms: aboveCf.baseKilograms,
                    adjustedKilograms: adjustedKilograms,
                    baseHoldSeconds: protocolHold
                ),
                baseHoldSeconds: anchorHoldSeconds(quality),
                adjustedSets: nil,
                basis: aboveCf.basis + suffix,
                referenceNote: aboveCf.referenceName
            )
        }

        // Endurance: 80–100% of critical force (center 90%), with the hold /
        // sets adjusted by the TUT heuristic.
        guard let cf = references.cf, cf.isFinite, cf > 0 else { return nil }
        let baseKilograms = round1(cf * 0.9)
        let adjustedKilograms = round1(baseKilograms * scale)
        let baseSets = zoneProtocols[quality]?.sets ?? 1
        let endurance = adjustedEndurance(
            baseHoldSeconds: anchorHoldSeconds(quality),
            baseSets: baseSets,
            intensityPercent: pct
        )
        return ZoneQualityTarget(
            quality: quality,
            lowKilograms: round1(cf * 0.8 * scale),
            targetKilograms: adjustedKilograms,
            highKilograms: round1(cf * scale),
            holdSeconds: endurance.holdSeconds,
            exactHoldSeconds: min(240, max(20, Double(anchorHoldSeconds(quality)) * pow(100.0 / Double(pct), 2))),
            baseHoldSeconds: anchorHoldSeconds(quality),
            adjustedSets: endurance.sets == baseSets ? nil : endurance.sets,
            basis: "80–100% of critical force (\(fmtOneDecimal(cf)) kg)\(suffix)",
            referenceNote: "From CF \(fmtOneDecimal(cf)) kg"
        )
    }

    /// The exact (pre-rounding) adjusted hold the `~Ns hold` readout renders.
    /// `adjustedHoldAboveCf`'s rounded result stays the executed schedule;
    /// this keeps the "≈" display honest when rounding moved the number.
    private static func exactAdjustedHold(
        quality: ZoneQuality,
        cf: Double?,
        wPrime: Double?,
        baseKilograms: Double,
        adjustedKilograms: Double,
        baseHoldSeconds: Double
    ) -> Double {
        guard let clamp = holdClampSeconds(for: quality) else { return baseHoldSeconds }
        let raw: Double
        if let cf, cf.isFinite, wPrime != nil, baseKilograms > cf {
            if adjustedKilograms > cf {
                raw = (baseKilograms - cf) * baseHoldSeconds / (adjustedKilograms - cf)
            } else {
                raw = clamp.upperBound
            }
        } else {
            raw = baseHoldSeconds * baseKilograms / adjustedKilograms
        }
        return min(clamp.upperBound, max(clamp.lowerBound, raw))
    }

    /// `fmt1` (`force-curve.ts`): `Math.round(v * 10) / 10`.
    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// One-decimal display of a rounded kg reference ("22.0") — the module
    /// readouts and source notes format references this way.
    static func fmtOneDecimal(_ value: Double) -> String {
        String(format: "%.1f", round1(value))
    }
}

/// #902: one quality's resolved target at a given session intensity — the
/// native sibling of the web's `ZoneTarget` record (`force-curve.ts`),
/// carrying the numbers the load module renders live.
public struct ZoneQualityTarget: Sendable, Equatable {
    public let quality: ZoneQuality
    public let lowKilograms: Double
    public let targetKilograms: Double
    public let highKilograms: Double
    /// The executed hold per rep — rounded (and endurance sets-shrunk)
    /// exactly like the web.
    public let holdSeconds: Int
    /// The exact pre-rounding adjusted hold — the "~Ns hold" display basis.
    public let exactHoldSeconds: Double
    /// The zone's protocol-table anchor hold at 100% (the
    /// "Adjusted from Ns @100%" note basis).
    public let baseHoldSeconds: Int
    /// Endurance-only: the shrunk set count at this intensity; nil for the
    /// above-CF zones whose set count never changes.
    public let adjustedSets: Int?
    /// The web's basis sentence, with the live reference value where the web
    /// carries one (Power/Strength/Endurance) and the " · intensity N%"
    /// suffix when intensity ≠ 100.
    public let basis: String
    /// The short source note the load module shows at 100% intensity
    /// ("From maxF 22.0 kg" / "From CF 20.0 kg" / "From F60 25.0 kg").
    public let referenceNote: String

    public init(
        quality: ZoneQuality,
        lowKilograms: Double,
        targetKilograms: Double,
        highKilograms: Double,
        holdSeconds: Int,
        exactHoldSeconds: Double,
        baseHoldSeconds: Int,
        adjustedSets: Int?,
        basis: String,
        referenceNote: String
    ) {
        self.quality = quality
        self.lowKilograms = lowKilograms
        self.targetKilograms = targetKilograms
        self.highKilograms = highKilograms
        self.holdSeconds = holdSeconds
        self.exactHoldSeconds = exactHoldSeconds
        self.baseHoldSeconds = baseHoldSeconds
        self.adjustedSets = adjustedSets
        self.basis = basis
        self.referenceNote = referenceNote
    }

    /// True when the intensity moved the executed schedule off the protocol
    /// anchor (the "Adjusted from Ns @100%" note + "~Ns hold" readout).
    public var isAdjusted: Bool {
        holdSeconds != baseHoldSeconds || adjustedSets != nil
    }

    /// The module's source note: the reference note at 100%, or the
    /// adjustment note ("Adjusted from 5s @100%") once the intensity moved
    /// the schedule.
    public var sourceNote: String {
        isAdjusted ? "Adjusted from \(baseHoldSeconds)s @100%" : referenceNote
    }
}
