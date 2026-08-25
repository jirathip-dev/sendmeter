import {
  isMaintenanceZone,
  QUALITIES,
  ZONE_PROTOCOLS,
  type RecordedZone,
  type TrainingQuality,
} from "./force-curve";
import {
  classifyZone,
  recordingZone,
  trainingBalanceZone,
  zoneSetDurationS,
  type ZonedHold,
  type ZoneSource,
} from "./zoneHistory";

/// #214 — the arithmetic BEHIND the training-balance bars, kept pure so the
/// UI can show its working instead of asserting a number. Nothing here
/// re-classifies or re-weights anything: `zoneBreakdown` buckets with the
/// same `recordingZone` and divides by the same `zoneSetDurationS` as
/// `zoneSets`, and a test pins the two to identical output. It only keeps
/// the intermediate values (total hold seconds, the divisor, which holds fed
/// each zone, and — since #259 — whether each hold's zone was recorded or
/// inferred) that `zoneSets` throws away.

export interface HoldLike extends ZonedHold {
  recordedAt: string;
}

export interface ZoneHold<T> {
  rec: T;
  durationS: number;
  /// Whether this hold's zone came off the recording or was inferred from
  /// `durationS` (#259) — the difference the explainer exists to show.
  source: ZoneSource;
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
  /// How many of `holds` carried the zone vs. had it inferred (#259). Sums to
  /// holds.length; both are stated so "3 holds" never hides a mix.
  recordedCount: number;
  inferredCount: number;
}

export interface ZoneBreakdown<T> {
  zones: Record<TrainingQuality, ZoneBreakdownEntry<T>>;
  /// Holds `classifyZone` refuses to bucket (under 1s — stray blips). They
  /// count toward no zone; the UI says so rather than silently dropping them.
  unclassified: ZoneHold<T>[];
  /// Warm-up and Prehab holds — recorded outside training balance BY DESIGN,
  /// not an inference failure like `unclassified`.
  excluded: ZoneHold<T>[];
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
  const excluded: ZoneHold<T>[] = [];

  for (const rec of recs) {
    const durationS = rec.durationMs / 1000;
    const { zone, source } = recordingZone(rec);
    // #657: the same bucket mapping as `zoneSets` — a native-only recorded
    // "capacity" zone counts toward endurance (see trainingBalanceZone).
    // Maintenance zones are recorded facts, but deliberately not trainable.
    if (isMaintenanceZone(zone)) {
      excluded.push({ rec, durationS, source });
      continue;
    }
    if (!zone) {
      unclassified.push({ rec, durationS, source });
      continue;
    }
    const bucket = trainingBalanceZone(zone);
    if (!bucket) {
      excluded.push({ rec, durationS, source });
      continue;
    }
    holdsByZone[bucket].push({ rec, durationS, source });
  }

  const entries = {} as Record<TrainingQuality, ZoneBreakdownEntry<T>>;
  for (const zone of ZONE_ORDER) {
    const holds = holdsByZone[zone];
    // Summed in input order, then divided once — the same operations in the
    // same order as `zoneSets`, so the two agree bit-for-bit.
    let totalHoldS = 0;
    for (const h of holds) totalHoldS += h.durationS;
    const setDurationS = zoneSetDurationS(zone);
    const recordedCount = holds.filter((h) => h.source === "recorded").length;
    entries[zone] = {
      zone,
      holds,
      totalHoldS,
      setDurationS,
      sets: totalHoldS / setDurationS,
      recordedCount,
      inferredCount: holds.length - recordedCount,
    };
  }

  return { zones: entries, unclassified, excluded };
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

/// The band a single hold's DURATION falls in, or null for a sub-1s blip.
/// This is the inference rule, not necessarily the hold's zone — a recording
/// that carries its own zone was never bucketed by this. Use `holdOrigin` to
/// display a hold; this stays exported for the band table above and its
/// drift test.
export function bandFor(
  durationS: number,
): { zone: TrainingQuality; band: string } | null {
  const zone = classifyZone(durationS);
  if (!zone) return null;
  const entry = ZONE_BANDS.find((b) => b.zone === zone);
  return entry ? { zone, band: entry.band } : null;
}

export interface HoldOrigin {
  zone: RecordedZone | null;
  source: ZoneSource;
  /// The zone's display label ("Strength"), or null for an unclassified blip.
  label: string | null;
  /// Why this hold has that zone, short enough to sit in a dense row: the
  /// word "recorded", or the duration band that produced the inference.
  short: string | null;
  /// The same thing said in full, for an explainer: "recorded as Strength" /
  /// "inferred from a 9s hold". Derived from the same attribution as `short`,
  /// so the two can't drift apart.
  long: string | null;
}

/// How one hold got its zone, ready to display (#259). The single place the
/// recorded/inferred distinction turns into words, so History, the Force list
/// and the training-balance page all phrase it identically.
export function holdOrigin(rec: ZonedHold): HoldOrigin {
  const durationS = rec.durationMs / 1000;
  const { zone, source } = recordingZone(rec);
  // Maintenance zones are always RECORDED (never inferred), so they get their
  // own short-circuit rather than flowing through the trainable label lookup.
  if (isMaintenanceZone(zone)) {
    const label = zone === "warmup" ? "Warm-up" : "Prehab";
    return {
      zone,
      source,
      label,
      short: "recorded",
      long: `recorded as ${label} — not counted toward training balance`,
    };
  }
  const label = zone ? (QUALITIES.find((q) => q.id === zone)?.label ?? zone) : null;
  if (!zone) return { zone, source, label: null, short: null, long: null };
  if (source === "recorded") {
    return { zone, source, label, short: "recorded", long: `recorded as ${label}` };
  }
  const band = ZONE_BANDS.find((b) => b.zone === zone)?.band ?? null;
  // 9 → "9s", 9.35 → "9.4s" — the hold as the user would read it off the row.
  const rounded = Math.round(durationS * 10) / 10;
  return {
    zone,
    source,
    label,
    short: band,
    long: `inferred from a ${rounded}s hold`,
  };
}

/// The caveat that belongs next to those bands — the one already written into
/// `classifyZone`'s own comment, said out loud to the user (#214), now with
/// the #259 split: a hold saved under an armed zone or preset carries that
/// zone as a fact; everything else still has it inferred from hold length,
/// and the power/PE/strength anchors sit close together.
export const ZONE_BAND_CAVEAT =
  "A hold recorded under an armed zone or preset stores the zone it was performed under — those are marked \"recorded\" and use it as-is. Every other hold — anything saved before this app stored it, and any freehand pull with no protocol armed — has its zone inferred from how long the hold lasted. The power (5s), pow end (7s) and strength (10s) anchors sit close together, so short holds are inherently fuzzy: an inferred hold that lands on the wrong side of the 6s or 8.5s boundary shows up as fractional credit in the neighbouring zone rather than being smoothed away. Inferred holds under 1s are treated as stray blips and counted nowhere.";

/// Sub-1s holds are dropped by `classifyZone`; surfaced so the UI can say how
/// many rather than leaving an unexplained gap between "recordings" and
/// "holds counted". Only ever applies to INFERRED holds — a recorded zone is
/// honoured at any duration (see `recordingZone`).
export const MIN_HOLD_S = 1;
