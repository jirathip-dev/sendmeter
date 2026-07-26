import {
  ZONE_INTENSITY,
  zonePrescription,
  type ForceCurveModel,
  type TrainingQuality,
} from "./force-curve";
import { classifyZoneLoaded } from "./zoneHistory";
import type { GaugeTarget } from "../components/ForceCurveCard";
import type { TindeqPreset } from "../types";

/// A selected zone = a load band for the live chart + a full guided protocol
/// (pull time / rest / reps / sets) for the fullscreen countdown. Shared by
/// TargetZonesCard (the chips) and ZoneFocusCard (the SL-100 recommendation).
export interface ZoneSelection {
  target: GaugeTarget;
  protocol: TindeqPreset;
}

/// Each training quality gets its own hue (cool → warm as it moves from
/// endurance to power), so the zone chips read as a spectrum, not one color.
export const QUALITY_COLORS: Record<TrainingQuality, string> = {
  power: "var(--danger)", // orange — max intensity
  strength: "var(--warning)", // yellow
  "power-endurance": "var(--info)", // violet
  endurance: "var(--success)", // electric blue
};

/// Build the gauge band + guided protocol for a zone (pure). Returns null if
/// the curve can't derive this zone (e.g. no CF for endurance / pow-end).
/// `intensityPct` (SL-97) scales the target load; the hold/reps prescription
/// is adjusted to keep the training dose equivalent — see
/// `zonePrescription` in force-curve.ts for the math.
export function buildZoneSelection(
  model: ForceCurveModel | null,
  q: TrainingQuality,
  tag: string,
  alt: boolean,
  intensityPct = 100,
): ZoneSelection | null {
  if (!model) return null;
  const p = zonePrescription(model, q, intensityPct);
  if (!p) return null;
  const t = p.target;
  return {
    target: {
      kg: t.targetKg,
      lowKg: t.lowKg,
      highKg: t.highKg,
      workS: t.workS,
      label: `${t.label} · ${tag}`,
    },
    protocol: {
      id: `zone:${q}`,
      name: `${t.label} · ${tag}`,
      holdS: p.holdS,
      reps: p.reps,
      sets: p.sets,
      restRepsS: p.restRepsS,
      restSetsS: p.restSetsS,
      targetKg: t.targetKg,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides: alt,
    },
  };
}

const INTENSITY_KEY = "sendmeter:zone-intensity";

/// ONE global intensity pct (SL-97b) — a single dial (rendered in the
/// recommended-zone card, #172) rather than each zone remembering its own.
/// It scales RECOMMENDED ZONES ONLY; custom presets are never rescaled.
/// Persisted as a plain number; an invalid or missing value (including a
/// stale per-quality map from before SL-97b) falls back to 100
/// (ZONE_INTENSITY.default).
export function loadIntensity(): number {
  try {
    const raw = localStorage.getItem(INTENSITY_KEY);
    if (!raw) return ZONE_INTENSITY.default;
    const v = JSON.parse(raw) as unknown;
    if (typeof v === "number" && v >= ZONE_INTENSITY.min && v <= ZONE_INTENSITY.max) {
      return v;
    }
    return ZONE_INTENSITY.default;
  } catch {
    return ZONE_INTENSITY.default;
  }
}

export function saveIntensity(pct: number): void {
  try {
    localStorage.setItem(INTENSITY_KEY, JSON.stringify(pct));
  } catch {
    /* quota / disabled storage — persistence is best-effort */
  }
}

/// Re-derive whatever is currently armed at a new intensity pct. RECOMMENDED
/// ZONES ONLY: anything without a `zone:${q}` id (i.e. a custom preset) is
/// returned untouched — that guard is what keeps the dial from ever rescaling
/// a user-defined preset's load. Falls back to the current selection if the
/// zone can no longer be derived, so moving the dial can't silently disarm.
export function applyIntensity(
  sel: ZoneSelection | null,
  model: ForceCurveModel | null,
  tag: string | null,
  intensityPct: number,
): ZoneSelection | null {
  const q = selectedQuality(sel);
  if (!sel || !q || !model || !tag) return sel;
  return buildZoneSelection(model, q, tag, sel.protocol.alternateSides, intensityPct) ?? sel;
}

/// The zone a PROTOCOL arms, parsed back from the `zone:${q}` id
/// `buildZoneSelection` mints. Null for a custom preset, which has no
/// declared quality — only a load and a hold time.
export function protocolQuality(p: TindeqPreset): TrainingQuality | null {
  const m = /^zone:(.+)$/.exec(p.id);
  const q = m?.[1] as TrainingQuality | undefined;
  return q && q in QUALITY_COLORS ? q : null;
}

/// The zone a selection arms — so the chips highlight from `selected` alone.
/// Null for custom presets.
export function selectedQuality(
  sel: ZoneSelection | null,
): TrainingQuality | null {
  return sel ? protocolQuality(sel.protocol) : null;
}

/// The quality a hold saved from this protocol was PERFORMED under (#259) —
/// what the recording stores, so neither History nor the training-balance
/// chart has to re-derive it from duration afterwards.
///
/// An armed zone states its own quality outright. A custom preset doesn't, so
/// it gets the LOAD-AWARE classification — the exact call `PresetManager`'s
/// badge makes (`classifyZoneLoaded`, duration AND resolved load), so what
/// gets stored is what the user was shown when they armed it. That load half
/// is precisely what a later duration-only re-derivation throws away: a 7s
/// hold at 85% of max is Strength on the badge and Power Endurance by
/// duration alone, and before this the second one silently won.
///
/// `targetKg` is the preset's target for the SET being saved (per-set ramps
/// mean set 3 can classify differently from set 1). Null with no protocol —
/// a freehand hold records no zone rather than a guess.
export function performedQuality(
  p: TindeqPreset | null,
  targetKg: number | null,
  refs: { maxF: number | null; cf: number | null },
): TrainingQuality | null {
  if (!p) return null;
  return protocolQuality(p) ?? classifyZoneLoaded(p.holdS, targetKg, refs);
}
