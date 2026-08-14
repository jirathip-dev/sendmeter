import type {
  CadenceMarker,
  NewTindeqRecording,
  ReverseActionDirection,
  ReverseActionSetMetrics,
  ReverseActionToleranceMode,
  TindeqSample,
} from "../types";
import type { RecordingSaveOutcome } from "./recordingSave";

export interface ReverseActionPrescription {
  reps: number;
  sets: number;
  cadenceOutS: number;
  cadenceReturnS: number;
  restSetsS: number;
  prepareS: number;
}

export interface ReverseActionSegment {
  phase: "prepare" | "move" | "setRest";
  side: null;
  direction: ReverseActionDirection | null;
  rep: number;
  set: number;
  startS: number;
  durS: number;
}

export interface ReverseActionTargetBand {
  kg: number;
  lowKg: number;
  highKg: number;
}

export interface ReverseActionSetSlice {
  samples: TindeqSample[];
  markers: CadenceMarker[];
  plannedDurationMs: number;
}

export interface BuildReverseActionRecordingInput {
  id: string;
  samples: readonly TindeqSample[];
  timeline: readonly ReverseActionSegment[];
  set: number;
  physicalEndMs?: number;
  protocolShiftS?: number;
  /// Optional for measured resisted movement. A target-free set still keeps
  /// its raw trace and completion/stability metrics; target accuracy remains
  /// null rather than inventing a load.
  targetBand: ReverseActionTargetBand | null;
  cadenceOutS: number;
  cadenceReturnS: number;
  base: Pick<
    NewTindeqRecording,
    "note" | "tag" | "side" | "groupId" | "protocolRunId" | "zone"
  > & { setupNote: string; capacityEvidence?: boolean | null };
}

function round(value: number, places: number): number {
  const scale = 10 ** places;
  return Math.round(value * scale) / scale;
}

/// Expand one Reverse Action prescription into a wall-clock cadence. Movement
/// is continuous within a set: OUT then RETURN for every rep, with rest only
/// between sets. `prepareS` applies once before set 1.
export function buildReverseActionTimeline(
  p: ReverseActionPrescription,
): ReverseActionSegment[] {
  const segments: ReverseActionSegment[] = [];
  let startS = 0;
  const push = (
    phase: ReverseActionSegment["phase"],
    direction: ReverseActionDirection | null,
    rep: number,
    set: number,
    durS: number,
  ) => {
    if (durS <= 0) return;
    segments.push({ phase, side: null, direction, rep, set, startS, durS });
    startS += durS;
  };

  push("prepare", null, 1, 1, p.prepareS);
  for (let set = 1; set <= p.sets; set += 1) {
    for (let rep = 1; rep <= p.reps; rep += 1) {
      push("move", "out", rep, set, p.cadenceOutS);
      push("move", "return", rep, set, p.cadenceReturnS);
    }
    if (set < p.sets) push("setRest", null, p.reps, set, p.restSetsS);
  }
  return segments;
}

export function reverseActionSetSegments(
  timeline: readonly ReverseActionSegment[],
  set: number,
): ReverseActionSegment[] {
  return timeline.filter((segment) => segment.phase === "move" && segment.set === set);
}

export function completesReverseActionSetAt(
  timeline: readonly ReverseActionSegment[],
  index: number,
): boolean {
  const segment = timeline[index];
  if (!segment || segment.phase !== "move") return false;
  return !timeline
    .slice(index + 1)
    .some((candidate) => candidate.phase === "move" && candidate.set === segment.set);
}

/// Stable transition key for audio/haptic cadence cues. Direction is
/// intentionally part of the identity: OUT and RETURN share rep/set/phase,
/// so omitting it suppresses every RETURN cue.
export function reverseActionCadenceKey(segment: ReverseActionSegment): string {
  return `${segment.phase}-${segment.set}-${segment.rep}-${segment.direction ?? ""}`;
}

export function reverseActionSetWindow(
  timeline: readonly ReverseActionSegment[],
  set: number,
): { startS: number; endS: number; durationS: number } | null {
  const segments = reverseActionSetSegments(timeline, set);
  const first = segments[0];
  const last = segments[segments.length - 1];
  if (!first || !last) return null;
  const endS = last.startS + last.durS;
  return { startS: first.startS, endS, durationS: endS - first.startS };
}

/// Expected direction/rep boundaries, normalized to the start of one saved
/// set trace. The marker at t=0 is intentional: it labels rep 1 / OUT.
export function cadenceMarkersForSet(
  timeline: readonly ReverseActionSegment[],
  set: number,
): CadenceMarker[] {
  const window = reverseActionSetWindow(timeline, set);
  if (!window) return [];
  return reverseActionSetSegments(timeline, set).map((segment) => ({
    tMs: Math.round((segment.startS - window.startS) * 1_000),
    rep: segment.rep,
    direction: segment.direction!,
  }));
}

/// Slice a set out of the physical sample buffer. Protocol time may be shifted
/// by skips before the set; the shift is snapshotted by the caller. Markers
/// beyond a partial manual/interruption stop are omitted rather than pretending
/// the athlete reached cadence boundaries that never occurred.
export function sliceReverseActionSet(
  samples: readonly TindeqSample[],
  timeline: readonly ReverseActionSegment[],
  set: number,
  physicalEndMs?: number,
  protocolShiftS = 0,
): ReverseActionSetSlice | null {
  const window = reverseActionSetWindow(timeline, set);
  if (!window) return null;
  const startMs = (window.startS - protocolShiftS) * 1_000;
  const plannedEndMs = (window.endS - protocolShiftS) * 1_000;
  const endMs = Math.min(physicalEndMs ?? plannedEndMs, plannedEndMs);
  if (endMs <= startMs) return null;
  const sliced = samples
    .filter(
      (sample) =>
        Number.isFinite(sample.t) &&
        Number.isFinite(sample.kg) &&
        sample.t >= startMs &&
        sample.t <= endMs,
    )
    .map((sample) => ({
      t: round(sample.t - startMs, 1),
      kg: sample.kg,
    }));
  if (sliced.length < 2) return null;
  const actualDurationMs = sliced[sliced.length - 1]!.t;
  return {
    samples: sliced,
    markers: cadenceMarkersForSet(timeline, set).filter(
      (marker) => marker.tMs <= actualDurationMs,
    ),
    plannedDurationMs: Math.round(window.durationS * 1_000),
  };
}

export function reverseActionTargetBand(
  targetKg: number | null,
  mode: ReverseActionToleranceMode,
  toleranceValue: number,
): ReverseActionTargetBand | null {
  if (targetKg === null || !Number.isFinite(targetKg) || targetKg <= 0) return null;
  const toleranceKg =
    mode === "percent" ? targetKg * (Math.max(0, toleranceValue) / 100) : Math.max(0, toleranceValue);
  return {
    kg: round(targetKg, 3),
    lowKg: round(Math.max(0, targetKg - toleranceKg), 3),
    highKg: round(targetKg + toleranceKg, 3),
  };
}

interface WeightedAccumulator {
  durationMs: number;
  forceMs: number;
  squareForceMs: number;
}

function addWeighted(acc: WeightedAccumulator, kg: number, durationMs: number): void {
  acc.durationMs += durationMs;
  acc.forceMs += kg * durationMs;
  acc.squareForceMs += kg * kg * durationMs;
}

function weightedMean(acc: WeightedAccumulator): number | null {
  return acc.durationMs > 0 ? acc.forceMs / acc.durationMs : null;
}

/// Compute set quality from the continuous raw trace. Force statistics are
/// time-weighted so irregular BLE sample intervals do not bias the answer.
/// "Loaded" defaults to >=1kg; cadence adherence is prescribed-clock coverage,
/// not observed motion, because v1 has no position sensor.
export function reverseActionSetMetrics(
  samples: readonly TindeqSample[],
  band: ReverseActionTargetBand | null,
  plannedDurationMs: number,
  loadedThresholdKg = 1,
): ReverseActionSetMetrics {
  const clean = samples
    .filter(
      (sample) =>
        Number.isFinite(sample.t) && Number.isFinite(sample.kg) && sample.t >= 0,
    )
    .slice()
    .sort((a, b) => a.t - b.t);
  const total: WeightedAccumulator = { durationMs: 0, forceMs: 0, squareForceMs: 0 };
  const early: WeightedAccumulator = { durationMs: 0, forceMs: 0, squareForceMs: 0 };
  const late: WeightedAccumulator = { durationMs: 0, forceMs: 0, squareForceMs: 0 };
  let inTargetMs = 0;
  const actualDurationMs = clean.length > 0 ? clean[clean.length - 1]!.t : 0;
  const comparisonDurationMs = Math.max(1, plannedDurationMs || actualDurationMs);
  const earlyEnd = comparisonDurationMs * 0.25;
  const lateStart = comparisonDurationMs * 0.75;

  for (let i = 1; i < clean.length; i += 1) {
    const previous = clean[i - 1]!;
    const current = clean[i]!;
    const durationMs = current.t - previous.t;
    if (durationMs <= 0) continue;
    const midpointT = previous.t + durationMs / 2;
    const midpointKg = (previous.kg + current.kg) / 2;
    if (midpointKg < loadedThresholdKg) continue;
    addWeighted(total, midpointKg, durationMs);
    if (midpointT <= earlyEnd) addWeighted(early, midpointKg, durationMs);
    if (midpointT >= lateStart) addWeighted(late, midpointKg, durationMs);
    if (band && midpointKg >= band.lowKg && midpointKg <= band.highKg) {
      inTargetMs += durationMs;
    }
  }

  const mean = weightedMean(total);
  const variance =
    mean === null
      ? null
      : Math.max(0, total.squareForceMs / total.durationMs - mean * mean);
  const earlyMean = weightedMean(early);
  const lateMean = weightedMean(late);
  return {
    meanKg: mean === null ? null : round(mean, 2),
    coefficientVariationPct:
      mean === null || mean <= 0 || variance === null
        ? null
        : round((Math.sqrt(variance) / mean) * 100, 1),
    inTargetPct:
      band === null || total.durationMs <= 0
        ? null
        : round((inTargetMs / total.durationMs) * 100, 1),
    timeUnderTensionMs: Math.round(total.durationMs),
    driftPct:
      earlyMean === null || lateMean === null || earlyMean <= 0
        ? null
        : round(((lateMean - earlyMean) / earlyMean) * 100, 1),
    cadenceAdherencePct: round(
      Math.min(1, Math.max(0, actualDurationMs / comparisonDurationMs)) * 100,
      1,
    ),
  };
}

export function buildReverseActionSetRecording(
  input: BuildReverseActionRecordingInput,
  // #487 (F2, review finding 3): stamp the capture moment on the object
  // itself at construction, same reasoning as ForceView.tsx's builders —
  // this is the ONE place both the live save (saveReverseActionSet) and the
  // sign-out salvage path (buildUnclaimedReverseActionSalvage) build a
  // recording, so it covers both. Injectable (matching recordingQueue.ts's
  // `now` convention) so callers stay deterministic in tests.
  now: () => string = () => new Date().toISOString(),
): (NewTindeqRecording & { id: string }) | null {
  const slice = sliceReverseActionSet(
    input.samples,
    input.timeline,
    input.set,
    input.physicalEndMs,
    input.protocolShiftS,
  );
  if (!slice) return null;
  const metrics = reverseActionSetMetrics(
    slice.samples,
    input.targetBand,
    slice.plannedDurationMs,
  );
  const kgs = slice.samples.map((sample) => sample.kg);
  const durationMs = Math.max(1, Math.round(slice.samples.at(-1)!.t));
  return {
    id: input.id,
    recordedAt: now(),
    durationMs,
    peakKg: Math.max(...kgs),
    avgKg: metrics.meanKg,
    ...input.base,
    setNo: input.set,
    samples: slice.samples,
    protocolMode: "reverse_action",
    targetKg: input.targetBand?.kg ?? null,
    targetLowKg: input.targetBand?.lowKg ?? null,
    targetHighKg: input.targetBand?.highKg ?? null,
    cadenceOutS: input.cadenceOutS,
    cadenceReturnS: input.cadenceReturnS,
    cadenceMarkers: slice.markers,
    setMetrics: metrics,
    setupNote: input.base.setupNote,
    capacityEvidence: input.base.capacityEvidence ?? null,
    plannedDurationMs: slice.plannedDurationMs,
    actualDurationMs: durationMs,
  };
}

export interface BuildReverseActionSalvageInput {
  samples: readonly TindeqSample[];
  timeline: readonly ReverseActionSegment[];
  sets: number;
  runId: string;
  claims: Set<string>;
  ids: Map<string, string>;
  createId: () => string;
  protocolShiftS: number;
  cadenceOutS: number;
  cadenceReturnS: number;
  targetBandForSet: (set: number) => ReverseActionTargetBand | null;
  baseForSet: (set: number) => BuildReverseActionRecordingInput["base"];
}

/// Synchronous unmount salvage for every started, not-yet-claimed set. This is
/// shared pure logic so the sign-out race is covered without mounting React:
/// a set already claimed by autosave/Stop is skipped, and every returned row
/// is claimed before control returns to the caller's persistence loop.
export function buildUnclaimedReverseActionSalvage(
  input: BuildReverseActionSalvageInput,
): (NewTindeqRecording & { id: string })[] {
  const lastPhysicalMs = input.samples.at(-1)?.t ?? 0;
  const rows: (NewTindeqRecording & { id: string })[] = [];
  for (let set = 1; set <= input.sets; set += 1) {
    const window = reverseActionSetWindow(input.timeline, set);
    if (!window) continue;
    const physicalStartMs = (window.startS - input.protocolShiftS) * 1_000;
    if (lastPhysicalMs - physicalStartMs < 1_000) continue;
    const key = reverseActionSetKey(input.runId, set);
    if (input.claims.has(key)) continue;
    const targetBand = input.targetBandForSet(set);
    let id = input.ids.get(key);
    if (!id) {
      id = input.createId();
      input.ids.set(key, id);
    }
    const row = buildReverseActionSetRecording({
      id,
      samples: input.samples,
      timeline: input.timeline,
      set,
      physicalEndMs: lastPhysicalMs,
      protocolShiftS: input.protocolShiftS,
      targetBand,
      cadenceOutS: input.cadenceOutS,
      cadenceReturnS: input.cadenceReturnS,
      base: input.baseForSet(set),
    });
    if (!row) continue;
    input.claims.add(key);
    rows.push(row);
  }
  return rows;
}

export function parseCadenceMarkers(value: unknown): CadenceMarker[] | null {
  if (!Array.isArray(value)) return null;
  const markers: CadenceMarker[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object") return null;
    const marker = item as Record<string, unknown>;
    if (
      typeof marker.tMs !== "number" ||
      !Number.isFinite(marker.tMs) ||
      marker.tMs < 0 ||
      typeof marker.rep !== "number" ||
      !Number.isInteger(marker.rep) ||
      marker.rep < 1 ||
      (marker.direction !== "out" && marker.direction !== "return")
    ) {
      return null;
    }
    markers.push({
      tMs: marker.tMs,
      rep: marker.rep,
      direction: marker.direction,
    });
  }
  return markers;
}

export function parseReverseActionSetMetrics(
  value: unknown,
): ReverseActionSetMetrics | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const metrics = value as Record<string, unknown>;
  const nullableFinite = (field: unknown) =>
    field === null || (typeof field === "number" && Number.isFinite(field));
  if (
    !nullableFinite(metrics.meanKg) ||
    !nullableFinite(metrics.coefficientVariationPct) ||
    !nullableFinite(metrics.inTargetPct) ||
    typeof metrics.timeUnderTensionMs !== "number" ||
    !Number.isFinite(metrics.timeUnderTensionMs) ||
    metrics.timeUnderTensionMs < 0 ||
    !nullableFinite(metrics.driftPct) ||
    typeof metrics.cadenceAdherencePct !== "number" ||
    !Number.isFinite(metrics.cadenceAdherencePct)
  ) {
    return null;
  }
  return {
    meanKg: metrics.meanKg as number | null,
    coefficientVariationPct: metrics.coefficientVariationPct as number | null,
    inTargetPct: metrics.inTargetPct as number | null,
    timeUnderTensionMs: metrics.timeUnderTensionMs,
    driftPct: metrics.driftPct as number | null,
    cadenceAdherencePct: metrics.cadenceAdherencePct,
  };
}

export function reverseActionSetKey(runId: string, set: number): string {
  return `${runId}:${set}`;
}

export type ReverseActionPersistOutcome =
  | "saved"
  | "already_claimed"
  | "lost";

/// Exactly-once persistence seam used by every full/partial set stop cause.
/// The claim is made synchronously before the first await. #613: `save` is the
/// durable-first save (see recordingSave.ts) — it persists locally, publishes
/// the pending row, inserts, and only reports "not-persisted" when NO durable
/// store would take the rep. A durable write (queued or confirmed) keeps the
/// claim; only total persistence failure releases it for retry.
export async function persistReverseActionSetOnce(
  key: string,
  claims: Set<string>,
  input: NewTindeqRecording & { id: string },
  save: (
    recording: NewTindeqRecording & { id: string },
  ) => Promise<RecordingSaveOutcome>,
): Promise<ReverseActionPersistOutcome> {
  if (claims.has(key)) return "already_claimed";
  claims.add(key);
  const outcome = await save(input);
  if (outcome === "not-persisted") {
    claims.delete(key);
    return "lost";
  }
  return "saved";
}
