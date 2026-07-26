import { ZONE_PROTOCOLS, type TrainingQuality } from "./force-curve";
import { classifyZone, zoneSetDurationS } from "./zoneHistory";

/// #214 — the arithmetic BEHIND the training-balance bars, kept pure so the
/// UI can show its working instead of asserting a number. Nothing here
/// re-classifies or re-weights anything: `zoneBreakdown` buckets with the
/// same `classifyZone` and divides by the same `zoneSetDurationS` as
/// `zoneSets`, and a test pins the two to identical output. It only keeps
/// the intermediate values (total hold seconds, the divisor, and which holds
/// fed each zone) that `zoneSets` throws away.

export interface HoldLike {
  recordedAt: string;
  durationMs: number;
}

export interface ZoneHold<T> {
  rec: T;
  durationS: number;
}

export interface ZoneBreakdownEntry<T> {
  zone: TrainingQuality;
  /// Holds classified into this zone, in the order they were passed in.
  holds: ZoneHold<T>[];
  /// Sum of those holds' durations, in seconds — the dividend.
  totalHoldS: number;
  /// This zone's protocol set length (holdS × reps) — the divisor.
  setDurationS: number;
  /// totalHoldS / setDurationS — identical to `zoneSets`' value for this zone.
  sets: number;
}

export interface ZoneBreakdown<T> {
  zones: Record<TrainingQuality, ZoneBreakdownEntry<T>>;
  /// Holds `classifyZone` refuses to bucket (under 1s — stray blips). They
  /// count toward no zone; the UI says so rather than silently dropping them.
  unclassified: ZoneHold<T>[];
}

const ZONE_ORDER: TrainingQuality[] = [
  "power",
  "strength",
  "power-endurance",
  "endurance",
];

/// Per-zone hold list + the division that produced its set count. Callers
/// wanting the trailing-window view should use `zoneBreakdownInWindow`.
export function zoneBreakdown<T extends HoldLike>(recs: T[]): ZoneBreakdown<T> {
  const holdsByZone = {
    power: [] as ZoneHold<T>[],
    strength: [] as ZoneHold<T>[],
    "power-endurance": [] as ZoneHold<T>[],
    endurance: [] as ZoneHold<T>[],
  } satisfies Record<TrainingQuality, ZoneHold<T>[]>;
  const unclassified: ZoneHold<T>[] = [];

  for (const rec of recs) {
    const durationS = rec.durationMs / 1000;
    const zone = classifyZone(durationS);
    if (!zone) {
      unclassified.push({ rec, durationS });
      continue;
    }
    holdsByZone[zone].push({ rec, durationS });
  }

  const entries = {} as Record<TrainingQuality, ZoneBreakdownEntry<T>>;
  for (const zone of ZONE_ORDER) {
    const holds = holdsByZone[zone];
    // Summed in input order, then divided once — the same operations in the
    // same order as `zoneSets`, so the two agree bit-for-bit.
    let totalHoldS = 0;
    for (const h of holds) totalHoldS += h.durationS;
    const setDurationS = zoneSetDurationS(zone);
    entries[zone] = {
      zone,
      holds,
      totalHoldS,
      setDurationS,
      sets: totalHoldS / setDurationS,
    };
  }

  return { zones: entries, unclassified };
}

/// The holds a trailing window keeps — mirrors `zoneTrainingSets`' filter
/// exactly (recordings whose `recordedAt` parses and is at or after the
/// cutoff). Exported so the UI scopes its hold lists with the same rule that
/// scopes the bars, instead of a second copy of it.
export function holdsInWindow<T extends HoldLike>(
  recs: T[],
  now: Date,
  windowDays = 28,
): T[] {
  const cutoff = now.getTime() - windowDays * 86_400_000;
  return recs.filter((r) => {
    const t = Date.parse(r.recordedAt);
    return !isNaN(t) && t >= cutoff;
  });
}

/// Trailing-window variant of `zoneBreakdown`.
export function zoneBreakdownInWindow<T extends HoldLike>(
  recs: T[],
  now: Date,
  windowDays = 28,
): ZoneBreakdown<T> {
  return zoneBreakdown(holdsInWindow(recs, now, windowDays));
}

/// The duration bands `classifyZone` applies, as displayable text. The
/// zone→band mapping is looked up THROUGH `classifyZone` (see `bandFor`), so
/// these labels can't quietly drift from the rule they describe — a test
/// sweeps durations and asserts the two still agree.
export const ZONE_BANDS: { zone: TrainingQuality; band: string; anchorS: number }[] =
  ZONE_ORDER.map((zone) => ({
    zone,
    band: {
      power: "1–6s",
      "power-endurance": "6–8.5s",
      strength: "8.5–20s",
      endurance: "over 20s",
    }[zone],
    anchorS: ZONE_PROTOCOLS[zone].holdS,
  }));

/// The band a single hold fell in, or null for a sub-1s blip that counts
/// toward nothing.
export function bandFor(
  durationS: number,
): { zone: TrainingQuality; band: string } | null {
  const zone = classifyZone(durationS);
  if (!zone) return null;
  const entry = ZONE_BANDS.find((b) => b.zone === zone);
  return entry ? { zone, band: entry.band } : null;
}

/// The caveat that belongs next to those bands — the one already written into
/// `classifyZone`'s own comment, said out loud to the user (#214): recordings
/// don't store the zone they were trained under, so it's re-inferred from hold
/// length, and the power/PE/strength anchors sit close together.
export const ZONE_BAND_CAVEAT =
  "Recordings don't store which zone you meant to train, so the zone is inferred from how long the hold lasted. The power (5s), pow end (7s) and strength (10s) anchors sit close together, so short holds are inherently fuzzy — a hold that lands on the wrong side of the 6s or 8.5s boundary shows up as fractional credit in the neighbouring zone rather than being smoothed away. Holds under 1s are treated as stray blips and counted nowhere.";

/// Sub-1s holds are dropped by `classifyZone`; surfaced so the UI can say how
/// many rather than leaving an unexplained gap between "recordings" and
/// "holds counted".
export const MIN_HOLD_S = 1;
