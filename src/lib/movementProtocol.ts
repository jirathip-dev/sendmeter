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

/// A Progressor recording cannot run for more than 30 minutes. Reverse Action
/// stores one continuous recording per set, so this is a per-set contract (the
/// inter-set rest and the prepare countdown do not consume the recording
/// buffer). Keep one second of headroom in normalization: a sample arriving
/// exactly on the BLE cap can race the wall-clock boundary handler otherwise.
export const TINDEQ_MAX_MOVEMENT_SET_S = 30 * 60;
const TINDEQ_SAFE_MOVEMENT_SET_S = TINDEQ_MAX_MOVEMENT_SET_S - 1;
export const TINDEQ_MIN_MOVEMENT_CADENCE_S = 0.5;
export const TINDEQ_MAX_MOVEMENT_CADENCE_S = 30;

type MovementPresetFields = Pick<
  TindeqPreset,
  "protocolMode" | "reps" | "cadenceOutS" | "cadenceReturnS"
>;

function boundedMovementCadence(value: number | null | undefined): number {
  return Number.isFinite(value)
    ? Math.max(
        TINDEQ_MIN_MOVEMENT_CADENCE_S,
        Math.min(TINDEQ_MAX_MOVEMENT_CADENCE_S, value as number),
      )
    : 3;
}

/// The maximum authored reps for one cadence cycle. The database currently
/// caps reps at 50; keep that upper bound here so older/malformed payloads do
/// not create a shape the editor itself could never save.
export function maxMovementRepsForCadence(
  cadenceOutS: number | null | undefined,
  cadenceReturnS: number | null | undefined,
): number {
  const cycleS =
    boundedMovementCadence(cadenceOutS) +
    boundedMovementCadence(cadenceReturnS);
  return Math.max(1, Math.min(50, Math.floor(TINDEQ_SAFE_MOVEMENT_SET_S / cycleS)));
}

/// Raw per-set work duration. Callers that consume a decoded or persisted
/// preset should use `normalizeMovementPreset` first; this raw form is useful
/// to reject an over-cap draft before it is saved.
export function movementSetDurationS(p: MovementPresetFields): number {
  if (p.protocolMode !== "reverse_action") return 0;
  const reps = Number.isFinite(p.reps) ? p.reps : Number.POSITIVE_INFINITY;
  const out = p.cadenceOutS ?? 3;
  const back = p.cadenceReturnS ?? 3;
  return reps * (out + back);
}

export function movementSetExceedsTindeqCap(p: MovementPresetFields): boolean {
  const durationS = movementSetDurationS(p);
  return p.protocolMode === "reverse_action" &&
    (!Number.isFinite(durationS) || durationS > TINDEQ_MAX_MOVEMENT_SET_S);
}

/// Normalize a server/local-storage preset at every decode/runtime boundary.
/// Historical rows remain untouched in Supabase, while the runtime drops only
/// the tail reps that cannot fit the Progressor's recording window. This is
/// deterministic and keeps the Watch from starting a set it will stop at 30m
/// without a matching guided boundary. The generic return preserves callers'
/// richer row shape (id/name/targets) without duplicating this helper.
export function normalizeMovementPreset<T extends MovementPresetFields>(p: T): T {
  if (p.protocolMode !== "reverse_action") return p;
  const cadenceOutS = boundedMovementCadence(p.cadenceOutS);
  const cadenceReturnS = boundedMovementCadence(p.cadenceReturnS);
  const maxReps = maxMovementRepsForCadence(cadenceOutS, cadenceReturnS);
  const reps = Math.max(1, Math.min(maxReps, Math.trunc(p.reps)));
  if (
    p.reps === reps &&
    (p.cadenceOutS ?? 3) === cadenceOutS &&
    (p.cadenceReturnS ?? 3) === cadenceReturnS
  ) {
    return p;
  }
  return { ...p, reps, cadenceOutS, cadenceReturnS };
}

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
