import { describe, expect, it } from "vitest";
import {
  CONCENTRIC_LABEL,
  ECCENTRIC_LABEL,
  MOVEMENT_LABEL,
  MOVEMENT_PROTOCOL_LABELS,
  MOVEMENT_STARTER_PRESET,
  RESISTED_MOVEMENT_LABEL,
  protocolSummary,
} from "./movementProtocol";

describe("movement protocol", () => {
  it("keeps the user-facing movement labels exact", () => {
    expect(RESISTED_MOVEMENT_LABEL).toBe("Resisted movement");
    expect(MOVEMENT_LABEL).toBe("MOVEMENT");
    expect(CONCENTRIC_LABEL).toBe("Concentric");
    expect(ECCENTRIC_LABEL).toBe("Eccentric");
    expect(MOVEMENT_PROTOCOL_LABELS).toEqual({
      setup: "Resisted movement",
      modality: "MOVEMENT",
      concentric: "Concentric",
      eccentric: "Eccentric",
    });
    expect(Object.isFrozen(MOVEMENT_PROTOCOL_LABELS)).toBe(true);
  });

  it("prescribes the Movement Starter values exactly", () => {
    expect(MOVEMENT_STARTER_PRESET).toEqual({
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
      setupNote: "Resisted movement",
      capacityEvidence: false,
    });
  });

  it("summarizes the Movement Starter cadence and rest", () => {
    expect(protocolSummary(MOVEMENT_STARTER_PRESET)).toBe(
      "3s concentric · 1s eccentric · 10 reps × 3 sets · 60s rest",
    );
  });

  it("keeps hold protocols readable", () => {
    expect(
      protocolSummary({
        ...MOVEMENT_STARTER_PRESET,
        protocolMode: "hold",
        holdS: 7,
        reps: 5,
        sets: 1,
      }),
    ).toBe("7s hold · 5 reps × 1 set");
  });
});
