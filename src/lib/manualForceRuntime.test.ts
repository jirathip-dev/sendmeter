import { describe, expect, it } from "vitest";
import { buildTimeline } from "./protocol";
import { canFailManualHold, confirmManualHold, failManualHold, manualRunDurationMs, startManualRun, tickManualRun } from "./manualForceRuntime";

const timeline = buildTimeline({ id: "p", name: "Lifts", holdS: 10, holdsS: null, reps: 2, sets: 1, restRepsS: 5, restSetsS: 0, targetKg: 20, targetPct: null, pctBasis: "pr", pctStep: 0, targetCurve: false, alternateSides: false });

describe("manual force timer", () => {
  it("captures early failure and starts recovery at the tap", () => {
    const state = failManualHold(startManualRun(1000), timeline, 4250);
    expect(state).toMatchObject({ status: "running", index: 1, startedMs: 4250, pending: { index: 0, actualDurationMs: 3250 } });
  });
  it("confirmation during rest does not restart or delay the rest", () => {
    const pending = tickManualRun(startManualRun(0), timeline, 12_000);
    expect(pending).toMatchObject({ index: 1, startedMs: 10_000, pending: { index: 0 } });
    expect(confirmManualHold(pending, timeline, 12_000)).toMatchObject({ index: 1, startedMs: 10_000, pending: null });
  });
  it("late confirmation gates at the next hold and starts it fresh", () => {
    const gated = tickManualRun(startManualRun(0), timeline, 30_000);
    expect(gated).toMatchObject({ index: 2, startedMs: 15_000, pending: { index: 0 } });
    expect(canFailManualHold(gated, timeline)).toBe(false);
    expect(confirmManualHold(gated, timeline, 30_000)).toMatchObject({ index: 2, startedMs: 30_000, pending: null });
  });
  it("captures completion time independently of the later RPE submit", () => {
    let state = tickManualRun(startManualRun(1_000), timeline, 11_000);
    state = confirmManualHold(state, timeline, 11_000);
    state = tickManualRun(state, timeline, 26_000);
    expect(state).toMatchObject({ completedMs: 26_000 });
    expect(manualRunDurationMs(1_000, state)).toBe(25_000);
  });
});
