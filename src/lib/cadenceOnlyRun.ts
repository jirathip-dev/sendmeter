import type { NewTindeqRecording, TindeqPreset, TindeqSide } from "../types";
import {
  buildReverseActionTimeline,
  cadenceMarkersForSet,
  reverseActionSetWindow,
  type ReverseActionSegment,
} from "./reverseAction";
import { normalizeMovementPreset } from "./movementProtocol";

export interface CadenceOnlyRunState {
  version: 1;
  preset: TindeqPreset;
  userId: string;
  tag: string;
  side: TindeqSide;
  groupId: string;
  runId: string;
  sessionId: string;
  setRecordingIds: string[];
  startedMs: number;
  /// Persisted before any partial/completion writes. A refresh on the outcome
  /// screen must not resume the clock and relabel a partial run as complete.
  endedMs?: number;
}

export interface CadenceOnlyPosition {
  elapsedS: number;
  index: number;
  segment: ReverseActionSegment | null;
  remainingS: number;
  finished: boolean;
}

const KEY = "sendmeter:reverse-action-cadence-run";

export function cadenceOnlyTimeline(state: CadenceOnlyRunState): ReverseActionSegment[] {
  const preset = normalizeMovementPreset(state.preset);
  return buildReverseActionTimeline({
    reps: preset.reps,
    sets: preset.sets,
    cadenceOutS: preset.cadenceOutS ?? 3,
    cadenceReturnS: preset.cadenceReturnS ?? 3,
    restSetsS: preset.restSetsS,
    prepareS: preset.prepareS ?? 5,
  });
}

export function cadenceOnlyPlannedEndMs(state: CadenceOnlyRunState): number {
  const last = cadenceOnlyTimeline(state).at(-1);
  return state.startedMs + Math.round((last ? last.startS + last.durS : 0) * 1_000);
}

export function cadenceOnlyPlannedDurationMs(state: CadenceOnlyRunState): number {
  return Math.max(0, cadenceOnlyPlannedEndMs(state) - state.startedMs);
}

export function cadenceOnlyRunComplete(
  state: CadenceOnlyRunState,
  elapsedMs: number,
): boolean {
  return elapsedMs >= cadenceOnlyPlannedDurationMs(state);
}

export function cadenceOnlyPosition(
  state: CadenceOnlyRunState,
  nowMs: number,
): CadenceOnlyPosition {
  const timeline = cadenceOnlyTimeline(state);
  const elapsedS = Math.max(0, (nowMs - state.startedMs) / 1_000);
  const index = timeline.findIndex(
    (segment) => elapsedS < segment.startS + segment.durS,
  );
  const segment = index < 0 ? null : timeline[index]!;
  return {
    elapsedS,
    index,
    segment,
    remainingS: segment
      ? Math.max(0, segment.startS + segment.durS - elapsedS)
      : 0,
    finished: index < 0,
  };
}

function completedRepsAt(
  state: CadenceOnlyRunState,
  actualDurationMs: number,
): number {
  const preset = normalizeMovementPreset(state.preset);
  const repMs = ((preset.cadenceOutS ?? 3) + (preset.cadenceReturnS ?? 3)) * 1_000;
  return Math.min(preset.reps, Math.floor(actualDurationMs / repMs));
}

export function buildCadenceOnlySetRecording(
  state: CadenceOnlyRunState,
  set: number,
  nowMs: number,
  includePartial: boolean,
): (NewTindeqRecording & { id: string }) | null {
  const preset = normalizeMovementPreset(state.preset);
  const timeline = cadenceOnlyTimeline(state);
  const window = reverseActionSetWindow(timeline, set);
  const id = state.setRecordingIds[set - 1];
  if (!window || !id) return null;
  const elapsedMs = Math.max(0, nowMs - state.startedMs);
  const startMs = window.startS * 1_000;
  const plannedDurationMs = Math.round(window.durationS * 1_000);
  if (elapsedMs <= startMs) return null;
  const availableMs = Math.min(plannedDurationMs, Math.round(elapsedMs - startMs));
  const complete = availableMs >= plannedDurationMs;
  if (!complete && (!includePartial || availableMs < 1_000)) return null;
  return {
    id,
    // #487 (F2, review finding 3): `nowMs` is already this function's own
    // wall-clock anchor (every duration below is derived from it), so
    // reusing it keeps the function pure/deterministic instead of reaching
    // for `Date.now()` — same "stamp at construction, not at whichever
    // request path eventually inserts" reasoning as ForceView.tsx's builders.
    recordedAt: new Date(nowMs).toISOString(),
    source: "manual",
    durationMs: Math.max(1, availableMs),
    peakKg: null,
    avgKg: null,
    note: "Clock-guided cadence only — movement was not detected",
    tag: state.tag,
    side: state.side,
    groupId: state.groupId,
    protocolRunId: state.runId,
    setNo: set,
    zone: null,
    plannedDurationMs,
    actualDurationMs: Math.max(1, availableMs),
    protocolMode: "reverse_action",
    cadenceOutS: preset.cadenceOutS ?? 3,
    cadenceReturnS: preset.cadenceReturnS ?? 3,
    cadenceMarkers: cadenceMarkersForSet(timeline, set).filter(
      (marker) => marker.tMs <= availableMs,
    ),
    capacityEvidence: false,
    completedReps: completedRepsAt(state, availableMs),
    completionStatus: complete ? "complete" : "partial",
    setupNote: preset.setupNote ?? "",
    samples: [],
  };
}

/// Claims every due row synchronously before returning. The caller can then
/// await persistence without a timer tick, background event, or Stop racing
/// to manufacture a second row for the same set. Stable per-set ids make the
/// same operation idempotent after a full page reload.
export function claimCadenceOnlyRows(
  state: CadenceOnlyRunState,
  nowMs: number,
  includePartial: boolean,
  claims: Set<number>,
): (NewTindeqRecording & { id: string })[] {
  const rows: (NewTindeqRecording & { id: string })[] = [];
  for (let set = 1; set <= state.preset.sets; set += 1) {
    if (claims.has(set)) continue;
    const row = buildCadenceOnlySetRecording(state, set, nowMs, includePartial);
    if (!row) continue;
    claims.add(set);
    rows.push(row);
  }
  return rows;
}

export function loadCadenceOnlyRun(): CadenceOnlyRunState | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const value = JSON.parse(raw) as Partial<CadenceOnlyRunState>;
    if (
      value.version !== 1 ||
      value.preset?.protocolMode !== "reverse_action" ||
      typeof value.tag !== "string" ||
      typeof value.userId !== "string" ||
      typeof value.groupId !== "string" ||
      typeof value.runId !== "string" ||
      typeof value.sessionId !== "string" ||
      !Array.isArray(value.setRecordingIds) ||
      value.setRecordingIds.length !== value.preset.sets ||
      typeof value.startedMs !== "number"
    ) return null;
    const restored = {
      ...(value as CadenceOnlyRunState),
      preset: normalizeMovementPreset(value.preset as TindeqPreset),
    };
    if (
      restored.endedMs !== undefined &&
      (!Number.isFinite(restored.endedMs) ||
        restored.endedMs < restored.startedMs ||
        restored.endedMs > cadenceOnlyPlannedEndMs(restored))
    ) return null;
    return restored;
  } catch {
    return null;
  }
}

export function saveCadenceOnlyRun(state: CadenceOnlyRunState): void {
  try { localStorage.setItem(KEY, JSON.stringify(state)); } catch { /* best effort */ }
}

export function clearCadenceOnlyRun(): void {
  try { localStorage.removeItem(KEY); } catch { /* ignore */ }
}
