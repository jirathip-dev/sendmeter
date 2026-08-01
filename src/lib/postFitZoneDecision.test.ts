import { describe, expect, it } from "vitest";
import type { ForceCurveModel } from "./force-curve";
import { buildZoneSelection, type ZoneSelection } from "./zoneSelection";
import { postFitZoneDecision } from "./postFitZoneDecision";

const usable: ForceCurveModel = {
  points: [],
  maxF: 40,
  cf: 20,
  wPrime: 300,
  capabilityFit: { family: "hill", cf: 20, maxF: 40, tau: 10, p: 1, sse: 1 },
};
const noCf: ForceCurveModel = { ...usable, cf: null, wPrime: null };
const noHill: ForceCurveModel = { ...usable, capabilityFit: undefined };

function armed(quality: "endurance" | "power-endurance" | "strength") {
  return buildZoneSelection(usable, quality, "Half crimp", false)!;
}

describe("postFitZoneDecision (#333)", () => {
  const decide = (
    state: Omit<Parameters<typeof postFitZoneDecision>[0], "revision">,
    model: ForceCurveModel | null,
    tag = "Half crimp",
  ) => postFitZoneDecision({ ...state, revision: 3 }, model, tag, 100, 3);

  it("unarms Endurance and atomically attaches its typed notice", () => {
    expect(
      decide({ selection: armed("endurance"), notice: null }, noCf),
    ).toEqual({
      selection: null,
      notice: { quality: "endurance", tag: "Half crimp" },
      revision: 3,
    });
  });

  it("unarms Power Endurance only when its Hill fit is unusable", () => {
    expect(
      decide(
        { selection: armed("power-endurance"), notice: null },
        noHill,
      ),
    ).toEqual({
      selection: null,
      notice: { quality: "power-endurance", tag: "Half crimp" },
      revision: 3,
    });
  });

  it("keeps a valid selection and clears an older notice", () => {
    const selection = armed("endurance");
    expect(
      decide(
        { selection, notice: { quality: "endurance", tag: "Half crimp" } },
        usable,
      ),
    ).toEqual({ selection, notice: null, revision: 3 });
  });

  it("preserves #298 absent-fit behavior", () => {
    const state = { selection: armed("endurance"), notice: null, revision: 3 };
    expect(postFitZoneDecision(state, null, "Half crimp", 100, 3)).toBe(state);
  });

  it("does not notice a custom preset, null selection, or unrelated settled fit", () => {
    const custom = { ...armed("strength"), protocol: { ...armed("strength").protocol, id: "custom" } } as ZoneSelection;
    expect(decide({ selection: custom, notice: null }, noCf))
      .toEqual({ selection: custom, notice: null, revision: 3 });
    expect(decide({ selection: null, notice: null }, noCf))
      .toEqual({ selection: null, notice: null, revision: 3 });
    const newer = armed("endurance");
    expect(decide({ selection: newer, notice: null }, noCf, "Open hand"))
      .toEqual({ selection: newer, notice: null, revision: 3 });
  });

  it("clears a persistent notice when a later fit restores that zone", () => {
    expect(
      decide(
        { selection: null, notice: { quality: "power-endurance", tag: "Half crimp" } },
        usable,
      ),
    ).toEqual({ selection: null, notice: null, revision: 3 });
  });

  it("ignores an older fit after a newer selection, even for the same tag", () => {
    const newer = { selection: armed("endurance"), notice: null, revision: 4 };
    expect(postFitZoneDecision(newer, noCf, "Half crimp", 100, 3)).toBe(newer);
  });
});
