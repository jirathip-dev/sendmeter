import { predictForce, type ForceCurveModel, type TrainingQuality } from "./force-curve";

/// SL-100: which training QUALITY a saved hold belongs to, inferred from its
/// duration. Recordings don't store the zone they were done under, so we
/// bucket by hold length around each zone's anchor hold (power 5s · power-
/// endurance 7s · strength 10s · endurance 30s — see ZONE_PROTOCOLS). The
/// power/PE/strength anchors sit close together so short holds are inherently
/// fuzzy; counting DISTINCT DAYS per zone (below) smooths out the noise.
export function classifyZone(durationS: number): TrainingQuality | null {
  if (durationS < 1) return null; // stray blip, not a real hold
  if (durationS <= 6) return "power";
  if (durationS <= 8.5) return "power-endurance";
  if (durationS <= 20) return "strength";
  return "endurance";
}

/// Distinct training DAYS per zone over the trailing window — "days I touched
/// this quality", which reads as training balance better than a raw rep count
/// (one long endurance session isn't 40 endurance reps' worth of emphasis).
export function zoneTrainingDays(
  recs: { recordedAt: string; durationMs: number }[],
  now: Date,
  windowDays = 28,
): Record<TrainingQuality, number> {
  const cutoff = now.getTime() - windowDays * 86_400_000;
  const daysByZone: Record<TrainingQuality, Set<string>> = {
    power: new Set(),
    strength: new Set(),
    "power-endurance": new Set(),
    endurance: new Set(),
  };
  for (const r of recs) {
    const t = Date.parse(r.recordedAt);
    if (isNaN(t) || t < cutoff) continue;
    const zone = classifyZone(r.durationMs / 1000);
    if (!zone) continue;
    daysByZone[zone].add(r.recordedAt.slice(0, 10));
  }
  return {
    power: daysByZone.power.size,
    strength: daysByZone.strength.size,
    "power-endurance": daysByZone["power-endurance"].size,
    endurance: daysByZone.endurance.size,
  };
}

const ZONE_ORDER: TrainingQuality[] = [
  "power",
  "strength",
  "power-endurance",
  "endurance",
];

/// Recommend the quality to focus on next: the least-trained zone by day
/// count, with the force curve breaking ties. A low CF-to-peak ratio means
/// endurance is the ceiling (bias the tie toward the endurance side); a high
/// ratio means peak strength is limiting (bias toward power/strength). Returns
/// null with no recordings at all. `reason` is a short, explainable line.
export function recommendZone(
  days: Record<TrainingQuality, number>,
  model: ForceCurveModel | null,
): { zone: TrainingQuality; reason: string } | null {
  const total = ZONE_ORDER.reduce((s, z) => s + days[z], 0);
  if (total === 0) return null;

  const min = Math.min(...ZONE_ORDER.map((z) => days[z]));
  const tied = ZONE_ORDER.filter((z) => days[z] === min);

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

  let zone = tied[0]!;
  if (tied.length > 1 && bias) {
    zone = tied.find((z) => bias.includes(z)) ?? tied[0]!;
  }

  const label: Record<TrainingQuality, string> = {
    power: "power",
    strength: "strength",
    "power-endurance": "power-endurance",
    endurance: "endurance",
  };
  const dayWord = days[zone] === 1 ? "day" : "days";
  let reason = `${days[zone]} ${label[zone]} ${dayWord} in the last 4 weeks`;
  if (ratio !== null) {
    reason += ` · CF is ${Math.round(ratio * 100)}% of peak`;
  }
  return { zone, reason };
}
