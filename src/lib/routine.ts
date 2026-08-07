import type { RoutineStep } from "../types";

/// Lead-in "get ready" seconds before a guided routine starts (SL-83). Shared
/// by RoutineFullscreen (the running timeline) and routineRun's resume/
/// abandonment math (#483) — both must expand the same total from the same
/// steps, or a resumed run's total disagrees with the live one.
export const ROUTINE_PREPARE_S = 5;

/// Expanded, flat runtime segments for a guided routine (SL-83): each step
/// can repeat ×reps with a rest between repetitions — the runner and the
/// progress bar both walk this list, mirroring the Force protocol timeline.
export interface RoutineSegment {
  kind: "prepare" | "work" | "rest";
  label: string;
  detail?: string;
  /// 1-based step + repetition this segment belongs to (prepare = step 0).
  stepIndex: number;
  rep: number;
  reps: number;
  startS: number;
  durS: number;
}

export function expandRoutine(
  steps: RoutineStep[],
  opts: { prepareS?: number } = {},
): RoutineSegment[] {
  const prepareS = opts.prepareS ?? 0;
  const segs: RoutineSegment[] = [];
  let t = 0;
  const push = (seg: Omit<RoutineSegment, "startS">) => {
    if (seg.durS <= 0) return;
    segs.push({ ...seg, startS: t });
    t += seg.durS;
  };

  if (prepareS > 0) {
    push({
      kind: "prepare",
      label: "Get ready",
      stepIndex: 0,
      rep: 1,
      reps: 1,
      durS: prepareS,
    });
  }

  steps.forEach((st, i) => {
    const reps = Math.max(1, st.reps ?? 1);
    const restS = Math.max(0, st.restS ?? 0);
    for (let rep = 1; rep <= reps; rep++) {
      push({
        kind: "work",
        label: st.label,
        detail: st.detail,
        stepIndex: i + 1,
        rep,
        reps,
        durS: st.s,
      });
      // Rest between repetitions of the same step only — the next step
      // starts immediately (its own pacing is its own business).
      if (rep < reps) {
        push({
          kind: "rest",
          label: "Rest",
          stepIndex: i + 1,
          rep,
          reps,
          durS: restS,
        });
      }
    }
  });
  return segs;
}

export function routineDurationS(segs: RoutineSegment[]): number {
  const last = segs[segs.length - 1];
  return last ? last.startS + last.durS : 0;
}
