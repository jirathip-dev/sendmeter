import type { TindeqPreset, TindeqSide } from "../types";
import { zonePrescription, type ForceCurveModel, type TrainingQuality } from "./force-curve";
import { holdForSet, presetTargetKg, type PresetRefs } from "./protocol";
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
    holdsS: Array.from({ length: sets }, (_, i) => (i % 2 === 0 ? left.holdS : right.holdS)),
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

export function nextLockedAlternatingPrescription(
  runActive: boolean,
  live: AlternatingPrescription | null,
  locked: AlternatingPrescription | null,
): AlternatingPrescription | null {
  return runActive ? locked : live;
}
