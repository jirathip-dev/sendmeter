import { describe, expect, it } from "vitest";
import type { TindeqPreset } from "../types";
import {
  buildCadenceOnlySetRecording,
  cadenceOnlyPlannedEndMs,
  cadenceOnlyPosition,
  claimCadenceOnlyRows,
  type CadenceOnlyRunState,
} from "./cadenceOnlyRun";

const preset: TindeqPreset = {
  id: "preset", name: "Spring", holdS: 6, holdsS: null, reps: 2, sets: 2,
  restRepsS: 0, restSetsS: 10, targetKg: null, targetPct: null,
  pctBasis: "pr", pctStep: 0, targetCurve: false, alternateSides: false,
  protocolMode: "reverse_action", cadenceOutS: 3, cadenceReturnS: 2,
  toleranceMode: "percent", toleranceValue: 10, prepareS: 5,
  setupNote: "red spring", capacityEvidence: false,
};
const state: CadenceOnlyRunState = {
  version: 1, preset, userId: "user", tag: "Crimp", side: "left", groupId: "group",
  runId: "run", sessionId: "session", setRecordingIds: ["one", "two"],
  startedMs: 1_000,
};

describe("cadence-only Reverse Action run (#422)", () => {
  it("uses the shared wall-clock timeline through background time", () => {
    expect(cadenceOnlyPosition(state, 7_000).segment).toMatchObject({
      phase: "move", direction: "out", set: 1, rep: 1,
    });
    expect(cadenceOnlyPosition(state, 28_000).segment).toMatchObject({
      phase: "move", direction: "out", set: 2, rep: 1,
    });
    expect(cadenceOnlyPlannedEndMs(state)).toBe(36_000);
  });

  it("builds provenance without inventing force or detected movement", () => {
    const row = buildCadenceOnlySetRecording(state, 1, 16_000, false);
    expect(row).toMatchObject({
      id: "one", source: "manual", protocolMode: "reverse_action",
      peakKg: null, avgKg: null, completedReps: 2,
      completionStatus: "complete", plannedDurationMs: 10_000,
      actualDurationMs: 10_000, setupNote: "red spring", capacityEvidence: false,
    });
    expect(row).not.toHaveProperty("targetKg");
  });

  it("saves a partial set honestly", () => {
    expect(buildCadenceOnlySetRecording(state, 2, 29_500, true)).toMatchObject({
      id: "two", completedReps: 0, completionStatus: "partial",
      actualDurationMs: 3_500,
    });
  });

  it("claims before persistence so concurrent runtime paths return one row", () => {
    const claims = new Set<number>();
    expect(claimCadenceOnlyRows(state, 16_000, false, claims)).toHaveLength(1);
    expect(claimCadenceOnlyRows(state, 16_000, false, claims)).toHaveLength(0);
    expect(claims).toEqual(new Set([1]));
  });
});
