import {
  predictForce,
  ZONE_PROTOCOLS,
  type ForceCurveModel,
  type TrainingQuality,
} from "./force-curve";

/// SL-100: which training QUALITY a saved hold belongs to, inferred from its
/// duration. Recordings don't store the zone they were done under, so we
/// bucket by hold length around each zone's anchor hold (power 5s · power-
/// endurance 7s · strength 10s · endurance 30s — see ZONE_PROTOCOLS). The
/// power/PE/strength anchors sit close together so short holds are inherently
/// fuzzy; `zoneTrainingSets` (below) turns each bucketed hold into a
/// duration-normalised set count, so — unlike the old distinct-day count —
/// a hold that lands on the wrong side of a fuzzy 6s/8.5s boundary isn't
/// smoothed away, it shows up as fractional credit in the neighboring zone.
export function classifyZone(durationS: number): TrainingQuality | null {
  if (durationS < 1) return null; // stray blip, not a real hold
  if (durationS <= 6) return "power";
  if (durationS <= 8.5) return "power-endurance";
  if (durationS <= 20) return "strength";
  return "endurance";
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
/// ZONE_PROTOCOLS — the unit `zoneTrainingSets` normalises against.
function zoneSetDurationS(zone: TrainingQuality): number {
  const zp = ZONE_PROTOCOLS[zone];
  return zp.holdS * zp.reps;
}

/// Duration-normalised set count per zone over the trailing window (#182):
/// total hold time recorded in a zone, divided by that zone's own protocol
/// set length, so training balance is weighted by how much time you actually
/// spent, not by how many distinct days you touched it. A 5-10 minute warm-up
/// now registers as a fraction of a set instead of needing a whole day's
/// worth of holds to show up at all.
export function zoneTrainingSets(
  recs: { recordedAt: string; durationMs: number }[],
  now: Date,
  windowDays = 28,
): Record<TrainingQuality, number> {
  const cutoff = now.getTime() - windowDays * 86_400_000;
  const secondsByZone: Record<TrainingQuality, number> = {
    power: 0,
    strength: 0,
    "power-endurance": 0,
    endurance: 0,
  };
  for (const r of recs) {
    const t = Date.parse(r.recordedAt);
    if (isNaN(t) || t < cutoff) continue;
    const durationS = r.durationMs / 1000;
    const zone = classifyZone(durationS);
    if (!zone) continue;
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

const ZONE_ORDER: TrainingQuality[] = [
  "power",
  "strength",
  "power-endurance",
  "endurance",
];

// Zones within this many sets of the true minimum are treated as tied
// candidates for the curve bias to break between (#182 follow-up): with a
// continuous, duration-normalised count, exact equality almost never
// happens, so a fixed band stands in for "roughly equally under-trained".
const TIE_BAND_SETS = 0.5;

/// Recommend the quality to focus on next: the least-trained zone by
/// duration-normalised set count, with the force curve breaking near-ties.
/// A low CF-to-peak ratio means endurance is the ceiling (bias the tie
/// toward the endurance side); a high ratio means peak strength is limiting
/// (bias toward power/strength). Returns null with no recordings at all.
/// `reason` is a short, explainable line.
export function recommendZone(
  sets: Record<TrainingQuality, number>,
  model: ForceCurveModel | null,
): { zone: TrainingQuality; reason: string } | null {
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
  const bias =
    ratio === null ? null : ratio < 0.35 ? enduranceSide : strengthSide;

  // Unbiased pick is the true minimum among the tied candidates, not the
  // first one in ZONE_ORDER — the band above admits candidates that aren't
  // the actual minimum, so picking tied[0] would favor `power` (first in
  // ZONE_ORDER) any time it's within band of a genuinely lower zone.
  let zone = tied.reduce((a, b) => (sets[b] < sets[a] ? b : a));
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
  return { zone, reason };
}
