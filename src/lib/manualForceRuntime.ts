import type { ProtocolSegment } from "./protocol";

export type ManualOutcome = "too_easy" | "good" | "failed";
export interface PendingManualHold {
  index: number;
  actualDurationMs: number;
  endedMs: number;
}
export type ManualRunState =
  | {
      status: "running";
      index: number;
      startedMs: number;
      pending: PendingManualHold | null;
      completedMs: number | null;
    }
  | { status: "finished"; completedMs: number };

export function startManualRun(nowMs: number): ManualRunState {
  return { status: "running", index: 0, startedMs: nowMs, pending: null, completedMs: null };
}

// A completed/failed hold starts the following rest or switch immediately.
// Confirmation can happen during that recovery, but an unconfirmed attempt
// gates at the next hold. Late confirmation starts that hold fresh.
export function tickManualRun(
  state: ManualRunState,
  timeline: ProtocolSegment[],
  nowMs: number,
): ManualRunState {
  if (state.status !== "running" || state.completedMs !== null) return state;
  let next = state;
  while (next.index < timeline.length) {
    const seg = timeline[next.index]!;
    if (seg.phase === "hold" && next.pending) return next;
    const elapsed = Math.max(0, nowMs - next.startedMs);
    if (elapsed < seg.durS * 1000) return next;
    const endedMs = next.startedMs + seg.durS * 1000;
    const pending = seg.phase === "hold"
      ? { index: next.index, actualDurationMs: seg.durS * 1000, endedMs }
      : next.pending;
    next = { ...next, index: next.index + 1, startedMs: endedMs, pending };
  }
  return { ...next, completedMs: next.startedMs };
}

export function failManualHold(
  state: ManualRunState,
  timeline: ProtocolSegment[],
  nowMs: number,
): ManualRunState {
  if (state.status !== "running" || state.pending) return state;
  const seg = timeline[state.index];
  if (!seg || seg.phase !== "hold") return state;
  const actualDurationMs = Math.max(1, Math.min(seg.durS * 1000, nowMs - state.startedMs));
  return tickManualRun(
    {
      ...state,
      index: state.index + 1,
      startedMs: nowMs,
      pending: { index: state.index, actualDurationMs, endedMs: nowMs },
    },
    timeline,
    nowMs,
  );
}

export function canFailManualHold(
  state: ManualRunState,
  timeline: ProtocolSegment[],
): boolean {
  return state.status === "running" && state.pending === null && timeline[state.index]?.phase === "hold";
}

export function confirmManualHold(
  state: ManualRunState,
  timeline: ProtocolSegment[],
  nowMs: number,
): ManualRunState {
  if (state.status !== "running" || !state.pending) return state;
  if (state.completedMs !== null) return { status: "finished", completedMs: state.completedMs };
  const gatedAtHold = timeline[state.index]?.phase === "hold";
  return tickManualRun(
    { ...state, pending: null, startedMs: gatedAtHold ? nowMs : state.startedMs },
    timeline,
    nowMs,
  );
}

export function currentManualSegment(state: ManualRunState, timeline: ProtocolSegment[]) {
  return state.status === "finished" || state.index >= timeline.length
    ? null
    : timeline[state.index]!;
}

export function manualRunDurationMs(startedMs: number, state: ManualRunState): number | null {
  const completedMs = state.completedMs;
  return completedMs === null ? null : Math.max(0, completedMs - startedMs);
}
