import type { TindeqPreset, TindeqRecordingMeta, TindeqSide } from "../types";
import {
  prehabTarget,
  zonePrescription,
  type ForceCurveModel,
  type TrainingQuality,
} from "./force-curve";
import {
  holdForSet,
  presetTargetKg,
  type AlternatingHoldDurations,
  type PresetRefs,
} from "./protocol";
import type { ProtocolSegment } from "./protocol";

export interface ResolvedForceTarget {
  kg: number;
  lowKg: number;
  highKg: number;
  workS: number;
  label: string;
}

export interface HandPrescription {
  refs: PresetRefs;
  targets: (ResolvedForceTarget | null)[];
}

export interface AlternatingPrescription {
  protocol: TindeqPreset;
  left: HandPrescription;
  right: HandPrescription;
}

export interface HandInputs {
  model: ForceCurveModel | null;
  prKg: number | null;
}

function refs(input: HandInputs): PresetRefs {
  return {
    prKg: input.prKg,
    cf: input.model?.cf ?? null,
    wPrime: input.model?.wPrime ?? null,
    maxF: input.model?.maxF ?? null,
    capabilityFit: input.model?.capabilityFit ?? null,
  };
}

function target(kg: number, holdS: number, label: string): ResolvedForceTarget {
  return { kg, lowKg: kg * 0.9, highKg: kg * 1.1, workS: holdS, label };
}

/** Recommended zones require two independently usable models, without fallback. */
export function resolveAlternatingRecommendation(
  inputs: { left: HandInputs; right: HandInputs },
  quality: TrainingQuality,
  tag: string,
  intensityPct: number,
  sets: number,
): AlternatingPrescription | null {
  if (!inputs.left.model || !inputs.right.model) return null;
  const left = zonePrescription(inputs.left.model, quality, intensityPct);
  const right = zonePrescription(inputs.right.model, quality, intensityPct);
  if (!left || !right) return null;
  const protocol: TindeqPreset = {
    id: `zone:${quality}`,
    name: `${left.target.label} · ${tag}`,
    holdS: left.holdS,
    holdsS: null,
    reps: left.reps,
    sets,
    restRepsS: left.restRepsS,
    restSetsS: left.restSetsS,
    targetKg: null,
    targetPct: null,
    pctBasis: "pr",
    pctStep: 0,
    targetCurve: false,
    alternateSides: true,
  };
  const hand = (
    side: "L" | "R",
    p: typeof left,
    input: HandInputs,
  ): HandPrescription => ({
    refs: refs(input),
    targets: Array.from({ length: sets }, () =>
      target(p.target.targetKg, p.holdS, `${p.target.label} · ${tag} ${side}`),
    ),
  });
  return {
    protocol,
    left: hand("L", left, inputs.left),
    right: hand("R", right, inputs.right),
  };
}

/** Exact hold schedule consumed by the alternating timeline. */
export function alternatingHoldDurations(
  prescription: AlternatingPrescription | null,
): AlternatingHoldDurations | undefined {
  if (!prescription) return undefined;
  return {
    left: prescription.left.targets.map(
      (resolved, i) => resolved?.workS ?? holdForSet(prescription.protocol, i + 1),
    ),
    right: prescription.right.targets.map(
      (resolved, i) => resolved?.workS ?? holdForSet(prescription.protocol, i + 1),
    ),
  };
}

/**
 * Resolve an alternating custom preset per hand AND set. Reference-derived
 * modes must settle for every set on both hands; fixed/no-target modes keep
 * their authored semantics even when no force model exists.
 */
export function resolveAlternatingPreset(
  preset: TindeqPreset,
  inputs: { left: HandInputs; right: HandInputs },
): AlternatingPrescription | null {
  if (!preset.alternateSides) return null;
  const referenceDerived = preset.targetCurve || preset.targetPct != null;
  const hand = (input: HandInputs): HandPrescription | null => {
    const handRefs = refs(input);
    const targets = Array.from({ length: preset.sets }, (_, i) => {
      const set = i + 1;
      const kg = presetTargetKg(preset, handRefs, set);
      return kg == null ? null : target(kg, holdForSet(preset, set), preset.name);
    });
    if (referenceDerived && targets.some((t) => t === null)) return null;
    return { refs: handRefs, targets };
  };
  const left = hand(inputs.left);
  const right = hand(inputs.right);
  return left && right ? { protocol: preset, left, right } : null;
}

/** Resolve the built-in maintenance prescriptions from each hand's own data. */
export function resolveAlternatingMaintenance(
  preset: TindeqPreset,
  inputs: { left: HandInputs; right: HandInputs },
): AlternatingPrescription | null {
  if (!preset.alternateSides || (preset.id !== "zone:warmup" && preset.id !== "zone:prehab")) {
    return null;
  }
  if (preset.id === "zone:warmup") return resolveAlternatingPreset(preset, inputs);
  const hand = (input: HandInputs, side: "L" | "R"): HandPrescription | null => {
    if (!input.model) return null;
    const resolved = prehabTarget(input.model);
    if (!resolved) return null;
    return {
      refs: refs(input),
      targets: Array.from({ length: preset.sets }, (_, index) =>
        target(resolved.targetKg, holdForSet(preset, index + 1), `${preset.name} ${side}`),
      ),
    };
  };
  const left = hand(inputs.left, "L");
  const right = hand(inputs.right, "R");
  return left && right ? { protocol: preset, left, right } : null;
}

export function prescriptionForSegment(
  prescription: AlternatingPrescription | null,
  side: TindeqSide | null | undefined,
  set: number,
): { hand: HandPrescription; target: ResolvedForceTarget | null } | null {
  if (!prescription || (side !== "left" && side !== "right")) return null;
  const hand = side === "left" ? prescription.left : prescription.right;
  return { hand, target: hand.targets[Math.max(1, set) - 1] ?? null };
}

/** The hold whose target should be displayed at a timeline position. */
export function targetHoldSegment(
  timeline: ProtocolSegment[] | null,
  current: ProtocolSegment | null,
  done: boolean,
): ProtocolSegment | null {
  if (!timeline) return null;
  if (current?.phase === "hold") return current;
  if (current) {
    const next = timeline.find(
      (s) => s.phase === "hold" && s.startS >= current.startS + current.durS,
    );
    if (next) return next;
  }
  const holds = timeline.filter((s) => s.phase === "hold");
  return done ? (holds.at(-1) ?? null) : (holds[0] ?? null);
}

export function needsHandReferences(preset: TindeqPreset): boolean {
  return preset.alternateSides && (preset.targetCurve || preset.targetPct != null);
}

function prescriptionKey(prescription: AlternatingPrescription | null): string | null {
  if (!prescription) return null;
  const hand = (value: HandPrescription) => [
    value.refs.prKg,
    value.refs.cf,
    value.refs.wPrime,
    value.refs.maxF,
    value.targets.map((resolved) =>
      resolved
        ? [resolved.kg, resolved.lowKg, resolved.highKg, resolved.workS, resolved.label]
        : null,
    ),
  ];
  const p = prescription.protocol;
  return JSON.stringify([
    p.id,
    p.name,
    p.holdS,
    p.holdsS,
    p.reps,
    p.sets,
    p.restRepsS,
    p.restSetsS,
    p.targetKg,
    p.targetPct,
    p.pctBasis,
    p.pctStep,
    p.targetCurve,
    p.alternateSides,
    hand(prescription.left),
    hand(prescription.right),
  ]);
}

/** Hold the exact prescription while active without idle render loops. */
export function nextLockedAlternatingPrescription(
  runActive: boolean,
  live: AlternatingPrescription | null,
  locked: AlternatingPrescription | null,
): AlternatingPrescription | null {
  if (runActive) return locked;
  return prescriptionKey(live) === prescriptionKey(locked) ? locked : live;
}

type CurveKeyRecording = Pick<
  TindeqRecordingMeta,
  "id" | "recordedAt" | "durationMs" | "peakKg"
>;

/**
 * Stable identity for the two curve inputs. Counts alone miss same-count row
 * replacements and can leave a stale hand model marked as settled.
 */
export function alternatingCurveInputKey(
  tag: string | null,
  left: readonly CurveKeyRecording[],
  right: readonly CurveKeyRecording[],
): string {
  const rows = (values: readonly CurveKeyRecording[]) =>
    values
      .map((row) => `${row.id}:${row.recordedAt}:${row.durationMs}:${row.peakKg}`)
      .sort()
      .join(",");
  return `${tag ?? ""}|${rows(left)}|${rows(right)}`;
}
