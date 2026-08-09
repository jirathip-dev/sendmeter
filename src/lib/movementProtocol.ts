import type { TindeqPreset } from "../types";

/// User-facing terminology for the resisted-movement protocol. Keep these
/// values in one place so presentation layers cannot drift apart.
export const RESISTED_MOVEMENT_LABEL = "Resisted movement" as const;
export const MOVEMENT_LABEL = "MOVEMENT" as const;
export const CONCENTRIC_LABEL = "Concentric" as const;
export const ECCENTRIC_LABEL = "Eccentric" as const;

export const MOVEMENT_PROTOCOL_LABELS = Object.freeze({
  setup: RESISTED_MOVEMENT_LABEL,
  modality: MOVEMENT_LABEL,
  concentric: CONCENTRIC_LABEL,
  eccentric: ECCENTRIC_LABEL,
} as const);

export const MOVEMENT_STARTER_PRESET: TindeqPreset = {
  id: "suggested:movement-starter",
  name: "Movement Starter",
  holdS: 40,
  holdsS: null,
  reps: 10,
  sets: 3,
  restRepsS: 0,
  restSetsS: 60,
  targetKg: null,
  targetPct: null,
  pctBasis: "pr",
  pctStep: 0,
  targetCurve: false,
  alternateSides: false,
  protocolMode: "reverse_action",
  cadenceOutS: 3,
  cadenceReturnS: 1,
  toleranceMode: "percent",
  toleranceValue: 10,
  prepareS: 5,
  setupNote: RESISTED_MOVEMENT_LABEL,
  capacityEvidence: false,
};

/// Compact summary for a protocol picker or selected-protocol card.
/// Reverse Action's clock is presented in movement terms rather than the
/// internal out/return direction names.
export function protocolSummary(preset: TindeqPreset): string {
  const repsAndSets = `${preset.reps} rep${preset.reps === 1 ? "" : "s"} × ${preset.sets} set${preset.sets === 1 ? "" : "s"}`;
  const rest = preset.sets > 1 ? ` · ${preset.restSetsS}s rest` : "";

  if (preset.protocolMode === "reverse_action") {
    return `${preset.cadenceOutS ?? 3}s ${CONCENTRIC_LABEL.toLowerCase()} · ${preset.cadenceReturnS ?? 3}s ${ECCENTRIC_LABEL.toLowerCase()} · ${repsAndSets}${rest}`;
  }

  return `${preset.holdS}s hold · ${repsAndSets}${rest}`;
}
