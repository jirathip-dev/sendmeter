import {
  predictForce,
  ZONE_PROTOCOLS,
  type ForceCurveModel,
  type RecordedZone,
  type TrainingQuality,
} from "./force-curve";
import type { TindeqSide } from "../types";

/// SL-100: which training QUALITY a saved hold belongs to, INFERRED from its
/// duration — the fallback for a recording that doesn't carry the zone it was
/// performed under (#259 added that column; everything saved before it, plus
/// every freehand hold, is null). Buckets by hold length around each zone's
/// anchor hold (power 5s · power-endurance 7s · strength 10s · endurance 30s
/// — see ZONE_PROTOCOLS). The power/PE/strength anchors sit close together so
/// short holds are inherently fuzzy; `zoneTrainingSets` (below) turns each
/// bucketed hold into a duration-normalised set count, so — unlike the old
/// distinct-day count — a hold that lands on the wrong side of a fuzzy
/// 6s/8.5s boundary isn't smoothed away, it shows up as fractional credit in
/// the neighboring zone.
///
/// Do NOT call this directly on a recording: go through `recordingZone`, which
/// prefers the recorded zone and only falls back here.
export function classifyZone(durationS: number): TrainingQuality | null {
  if (durationS < 1) return null; // stray blip, not a real hold
  if (durationS <= 6) return "power";
  if (durationS <= 8.5) return "power-endurance";
  if (durationS <= 20) return "strength";
  return "endurance";
}

/// Where a hold's zone came from (#259).
///   recorded — the recording carries the zone it was performed under
///   inferred — re-derived from hold duration by `classifyZone`
export type ZoneSource = "recorded" | "inferred";

export interface ZoneAttribution {
  zone: RecordedZone | null;
  source: ZoneSource;
}

/// The shape every zone reader needs from a recording. `zone` is optional so
/// callers with older/partial shapes (the offline queue, tests, fixtures)
/// still typecheck — an absent field reads the same as an explicit null.
export interface ZonedHold {
  durationMs: number;
  zone?: RecordedZone | null;
}

/// THE read path for "which zone is this hold" (#259). Prefers the zone the
/// recording was performed under; falls back to inferring it from duration
/// when there is none — which is every recording made before the column
/// existed, plus every freehand hold. The fallback is byte-for-byte the old
/// behaviour (`classifyZone(durationMs / 1000)`), so historical data does not
/// shift; `zoneHistory.test.ts` pins that.
///
/// `source` comes back with it so the UI can say WHICH it is looking at —
/// "recorded as Strength" reads very differently from "inferred from a 9s
/// hold", and conflating the two is the thing this issue exists to stop.
///
/// A recorded zone wins regardless of duration: it's a fact about how the
/// hold was performed, not a guess to be second-guessed. Only an INFERRED
/// zone can come back null (the sub-1s stray-blip rule).
export function recordingZone(rec: ZonedHold): ZoneAttribution {
  if (rec.zone != null) return { zone: rec.zone, source: "recorded" };
  return { zone: classifyZone(rec.durationMs / 1000), source: "inferred" };
}

/// Whether a hold is a maximal-intent effort — i.e. safe to read as evidence
/// of capacity (curve fit, PR/trend charts, training-balance summaries). A
/// Prehab hold (#325) is submaximal BY CONSTRUCTION (30s at 0.70×CF, daily),
/// so it fails this everywhere a recording is otherwise assumed to represent
/// how hard the user pulled: fed into the curve fit it supplies flat ≥10s
/// points that ratchet CF down every session; fed into a peak-force trend it
/// fabricates a "PR dropped" day; counted in a training-balance summary it
/// inflates "N holds" past what the balance itself credits. One predicate for
/// all three, so a future consumer of `recordings` has something to grep for
/// instead of re-deriving `zone !== "prehab"` (and forgetting it).
export function isEffortRecording(rec: ZonedHold): boolean {
  return recordingZone(rec).zone !== "prehab";
}

/// The PR a `pctBasis: "pr"` preset targets (#325): the best EFFORT peak for
/// a tag/side, never a Prehab hold — a Prehab hold at 0.70×CF never wins a
/// `Math.max` against a real effort, but for a tag/side with no real effort
/// yet it WOULD become the PR, silently prescribing every future %-of-PR
/// preset off a submax hold. Null tag means "nothing selected"; null side
/// means "either side" (mirrors `trendChartRecordings`' filter).
export function effortPeakKg<
  T extends ZonedHold & { tag: string; side: TindeqSide; peakKg: number },
>(recs: T[], tag: string | null, side: TindeqSide | null): number | null {
  if (tag === null) return null;
  const matches = recs.filter(
    (r) => r.tag === tag && (side === null || r.side === side) && isEffortRecording(r),
  );
  return matches.length ? Math.max(...matches.map((r) => r.peakKg)) : null;
}

/// The recordings `ForceView` feeds its critical-force fit: scoped to the
/// active tag/side, and — Prehab (#325) — excluded from effort for the exact
/// reason `isEffortRecording` documents (flat ≥10s sub-CF points would
/// otherwise ratchet CF down every session, corrupting every %-of-CF
/// prescription plus the CF the watch reads back for its RPE prediction).
/// Null tag means "nothing armed yet" and returns no candidates, matching
/// `ForceView`'s prior inline filter. Exported (pure, no hooks) so this
/// guarantee is pinned directly rather than by a test that re-implements the
/// filter it's meant to catch the removal of.
export function curveCandidateRecordings<
  T extends ZonedHold & { tag: string; side: TindeqSide },
>(recs: T[], tag: string | null, side: TindeqSide | null): T[] {
  if (tag === null) return [];
  return recs.filter((r) => r.tag === tag && (side === null || r.side === side) && isEffortRecording(r));
}

/// The two counts `TrainingBalanceDetail`'s "what this counts" copy states:
/// how many holds fed the numbers below, and how many of those store their
/// own zone vs. have it inferred. Both computed over EFFORT recordings only
/// (#325) — a Prehab hold is always "recorded" (`recordingZone` never infers
/// it) but never feeds the balance (`zoneSets` drops it), so counting it in
/// either figure would make both sentences literally false. Pure and
/// exported so the page's copy is pinned without having to render a
/// component that portals into `document.body`.
export function balanceScopeCounts(
  windowRecs: ZonedHold[],
): { effortCount: number; recordedCount: number } {
  const effortRecs = windowRecs.filter(isEffortRecording);
  return {
    effortCount: effortRecs.length,
    recordedCount: effortRecs.filter((r) => recordingZone(r).source === "recorded").length,
  };
}

/// Load-aware classifier (SL-97b): once a preset's target resolves to an
/// actual kg (fixed, %-of-PR/CF, or curve, all after the intensity dial's
/// scaling), classify off duration AND load together instead of duration
/// alone — a preset's badge then re-classifies live as the intensity dial or
/// the underlying curve moves, instead of being frozen by its authored hold
/// time. Falls back to the duration-only `classifyZone` when there's no
/// resolved load or no maxF to compare it against (untargeted presets).
export function classifyZoneLoaded(
  holdS: number,
  kg: number | null,
  refs: { maxF: number | null; cf: number | null },
): TrainingQuality | null {
  if (holdS < 1) return null; // stray blip, not a real hold
  if (kg == null || refs.maxF == null) return classifyZone(holdS);
  if (refs.cf != null && kg <= refs.cf) return "endurance";
  // Thresholds mirror each zone's own band low in `zoneTarget` (force-curve.ts)
  // — power 0.9·maxF, strength 0.8·maxF — so a preset badges the same zone its
  // load would actually place it in, not a looser fuzzy bucket (#105/SL-103:
  // this used to say 0.75, below the Strength band's own 0.8 low, so a ~76%
  // preset badged "Strength" while falling short of the zone it named).
  if (kg >= 0.9 * refs.maxF && holdS <= 6) return "power";
  if (kg >= 0.8 * refs.maxF && holdS <= 20) return "strength";
  if (holdS <= 20) return "power-endurance";
  return "endurance";
}

/// One zone's protocol "set" length in seconds — reps × hold, from
/// ZONE_PROTOCOLS — the unit `zoneTrainingSets` normalises against. Exported
/// for #214's breakdown, which shows the division rather than asserting the
/// quotient (see lib/zoneBreakdown.ts).
///
/// Endurance is a special case (#320): its protocol shape is 1 rep × 8 sets
/// (so per-set alternation fires), but the training-balance unit is still
/// the whole 8-hold protocol — holdS × reps alone would drop this to 30s and
/// inflate endurance training-balance 8×. Other zones keep holdS × reps
/// only (power-endurance's own 4 sets are deliberately NOT multiplied in —
/// its unit is one 6-rep round, unchanged by this issue).
export function zoneSetDurationS(zone: TrainingQuality): number {
  const zp = ZONE_PROTOCOLS[zone];
  if (zone === "endurance") return zp.holdS * zp.reps * zp.sets;
  return zp.holdS * zp.reps;
}

/// Duration-normalised set count per zone (#182, extracted for #214): total
/// hold time recorded in a zone, divided by that zone's own protocol set
/// length, so training balance is weighted by how much time you actually
/// spent, not by how many distinct days you touched it. A 5-10 minute warm-up
/// now registers as a fraction of a set instead of needing a whole day's
/// worth of holds to show up at all. No time-window filtering — callers that
/// want a trailing window should filter `recs` first (see
/// `zoneTrainingSets` below) or pre-filter for a per-session mix (#214).
///
/// Buckets by `recordingZone` (#259), so a hold that stored its zone counts
/// toward THAT zone; only holds without one are bucketed by duration. Time is
/// still the weight either way — a recorded zone changes which bucket a hold
/// lands in, never how much it's worth.
export function zoneSets(
  recs: ZonedHold[],
): Record<TrainingQuality, number> {
  const secondsByZone: Record<TrainingQuality, number> = {
    power: 0,
    strength: 0,
    "power-endurance": 0,
    endurance: 0,
  };
  for (const r of recs) {
    const durationS = r.durationMs / 1000;
    const { zone } = recordingZone(r);
    // Prehab (#325) is recorded outside training balance BY DESIGN — it's
    // maintenance work below CF, not a quality to credit toward any of the
    // four training buckets. `!zone` alone (the pre-#325 guard) would let it
    // fall through silently the moment `zone` widened to admit it.
    if (!zone || zone === "prehab") continue;
    secondsByZone[zone] += durationS;
  }
  return {
    power: secondsByZone.power / zoneSetDurationS("power"),
    strength: secondsByZone.strength / zoneSetDurationS("strength"),
    "power-endurance":
      secondsByZone["power-endurance"] / zoneSetDurationS("power-endurance"),
    endurance: secondsByZone.endurance / zoneSetDurationS("endurance"),
  };
}

/// Duration-normalised set count per zone over the trailing window (#182):
/// same as `zoneSets`, but restricted to recordings within `windowDays` of
/// `now` — the window training-balance is scoped to.
export function zoneTrainingSets(
  recs: (ZonedHold & { recordedAt: string })[],
  now: Date,
  windowDays = 28,
): Record<TrainingQuality, number> {
  const cutoff = now.getTime() - windowDays * 86_400_000;
  const kept = recs.filter((r) => {
    const t = Date.parse(r.recordedAt);
    return !isNaN(t) && t >= cutoff;
  });
  return zoneSets(kept);
}

const ZONE_ORDER: TrainingQuality[] = [
  "power",
  "strength",
  "power-endurance",
  "endurance",
];

/// The zone with the highest duration-normalised set count (#214) — used to
/// badge a Tindeq session by the training quality its recordings actually
/// belong to, instead of the app-wide phase. Null when every zone is zero
/// (no classifiable holds in the session). Ties broken deterministically by
/// `ZONE_ORDER`.
export function dominantZone(
  sets: Record<TrainingQuality, number>,
): TrainingQuality | null {
  const max = Math.max(...ZONE_ORDER.map((z) => sets[z]));
  if (max === 0) return null;
  return ZONE_ORDER.find((z) => sets[z] === max) ?? null;
}

// Zones within this many sets of the true minimum are treated as tied
// candidates for the curve bias to break between (#182 follow-up): with a
// continuous, duration-normalised count, exact equality almost never
// happens, so a fixed band stands in for "roughly equally under-trained".
// Exported so the detail page can state the band it applied (#214).
export const TIE_BAND_SETS = 0.5;

/// CF-to-peak ratio below which the curve reads as endurance-limited (and at
/// or above which, strength-limited). Exported for the same reason.
export const CURVE_BIAS_RATIO = 0.35;

export interface ZoneRecommendation {
  zone: TrainingQuality;
  reason: string;
  /// Everything the pick was made from, so #214's detail page can show the
  /// reasoning instead of restating the conclusion.
  detail: {
    /// Lowest set count across all four zones.
    minSets: number;
    /// Zones within TIE_BAND_SETS of `minSets` — the candidates.
    tied: TrainingQuality[];
    /// The pick before any curve bias: the least-trained tied candidate.
    unbiasedZone: TrainingQuality;
    /// CF as a fraction of predicted 5s peak force; null without a usable fit.
    curveRatio: number | null;
    /// Which side of the tie the curve steers toward, if it has an opinion.
    curveBias: "endurance" | "strength" | null;
    /// True when the bias actually moved the pick off `unbiasedZone`.
    biasChangedPick: boolean;
  };
}

/// Recommend the quality to focus on next: the least-trained zone by
/// duration-normalised set count, with the force curve breaking near-ties.
/// A low CF-to-peak ratio means endurance is the ceiling (bias the tie
/// toward the endurance side); a high ratio means peak strength is limiting
/// (bias toward power/strength). Returns null with no recordings at all.
/// `reason` is a short, explainable line.
export function recommendZone(
  sets: Record<TrainingQuality, number>,
  model: ForceCurveModel | null,
): ZoneRecommendation | null {
  const total = ZONE_ORDER.reduce((s, z) => s + sets[z], 0);
  if (total === 0) return null;

  const min = Math.min(...ZONE_ORDER.map((z) => sets[z]));
  const tied = ZONE_ORDER.filter((z) => sets[z] - min <= TIE_BAND_SETS);

  // Curve signal: CF (sustainable force) as a fraction of peak short-hold
  // force. Low → endurance-limited; high → strength-limited.
  let ratio: number | null = null;
  if (model && model.cf !== null) {
    const peak = predictForce(model, 5) || model.maxF;
    if (peak > 0) ratio = model.cf / peak;
  }
  const enduranceSide: TrainingQuality[] = ["endurance", "power-endurance"];
  const strengthSide: TrainingQuality[] = ["power", "strength"];
  const curveBias: "endurance" | "strength" | null =
    ratio === null ? null : ratio < CURVE_BIAS_RATIO ? "endurance" : "strength";
  const bias =
    curveBias === null
      ? null
      : curveBias === "endurance"
        ? enduranceSide
        : strengthSide;

  // Unbiased pick is the true minimum among the tied candidates, not the
  // first one in ZONE_ORDER — the band above admits candidates that aren't
  // the actual minimum, so picking tied[0] would favor `power` (first in
  // ZONE_ORDER) any time it's within band of a genuinely lower zone.
  let zone = tied.reduce((a, b) => (sets[b] < sets[a] ? b : a));
  const unbiasedZone = zone;
  if (tied.length > 1 && bias) {
    // Same reasoning on the biased side: take the least-trained zone the curve
    // steers toward, not the first one in ZONE_ORDER. `find` would return
    // `power` over a genuinely lower `strength` whenever both are in band.
    const biased = tied.filter((z) => bias.includes(z));
    if (biased.length > 0) {
      zone = biased.reduce((a, b) => (sets[b] < sets[a] ? b : a));
    }
  }

  const label: Record<TrainingQuality, string> = {
    power: "power",
    strength: "strength",
    "power-endurance": "power-endurance",
    endurance: "endurance",
  };
  const roundedSets = Math.round(sets[zone] * 10) / 10;
  const setWord = roundedSets === 1 ? "set" : "sets";
  let reason = `${roundedSets} ${label[zone]} ${setWord} in the last 4 weeks`;
  if (ratio !== null) {
    reason += ` · CF is ${Math.round(ratio * 100)}% of peak`;
  }
  return {
    zone,
    reason,
    detail: {
      minSets: min,
      tied,
      unbiasedZone,
      curveRatio: ratio,
      curveBias,
      biasChangedPick: zone !== unbiasedZone,
    },
  };
}
