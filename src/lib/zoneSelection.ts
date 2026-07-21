import {
  ZONE_PROTOCOLS,
  zoneTarget,
  type ForceCurveModel,
  type TrainingQuality,
} from "./force-curve";
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
export function buildZoneSelection(
  model: ForceCurveModel | null,
  q: TrainingQuality,
  tag: string,
  alt: boolean,
): ZoneSelection | null {
  if (!model) return null;
  const t = zoneTarget(model, q);
  if (!t) return null;
  const zp = ZONE_PROTOCOLS[q];
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
      holdS: zp.holdS,
      reps: zp.reps,
      sets: zp.sets,
      restRepsS: zp.restRepsS,
      restSetsS: zp.restSetsS,
      targetKg: t.targetKg,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides: alt,
    },
  };
}

/// The zone a selection arms, parsed back from its `zone:${q}` protocol id —
/// so the chips highlight from `selected` alone. Null for custom presets.
export function selectedQuality(
  sel: ZoneSelection | null,
): TrainingQuality | null {
  if (!sel) return null;
  const m = /^zone:(.+)$/.exec(sel.protocol.id);
  const q = m?.[1] as TrainingQuality | undefined;
  return q && q in QUALITY_COLORS ? q : null;
}
