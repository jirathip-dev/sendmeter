import { describe, expect, it } from "vitest";
import type { TindeqSide } from "../types";
import {
  allowedSides,
  DEFAULT_SIDE_MODE,
  type ExerciseSideMode,
  isSideAllowed,
  normalizeSide,
  normalizeSideMode,
} from "./sideMode";

const ALL_SIDES: TindeqSide[] = ["", "left", "right", "both"];
const ALL_MODES: ExerciseSideMode[] = [
  "unilateral_or_bilateral",
  "unilateral_only",
  "bilateral_only",
  "not_applicable",
];

describe("allowedSides", () => {
  it("returns the policy table for all four modes", () => {
    expect(allowedSides("unilateral_or_bilateral")).toEqual(["", "left", "right", "both"]);
    expect(allowedSides("unilateral_only")).toEqual(["", "left", "right"]);
    expect(allowedSides("bilateral_only")).toEqual(["", "both"]);
    expect(allowedSides("not_applicable")).toEqual([""]);
  });

  it("always includes \"\" (unspecified)", () => {
    for (const mode of ALL_MODES) {
      expect(allowedSides(mode)).toContain("");
    }
  });
});

describe("isSideAllowed", () => {
  it("matches allowedSides for every mode/side combination", () => {
    for (const mode of ALL_MODES) {
      for (const side of ALL_SIDES) {
        expect(isSideAllowed(mode, side)).toBe(allowedSides(mode).includes(side));
      }
    }
  });

  it("never treats \"\" as equivalent to \"both\"", () => {
    expect(isSideAllowed("bilateral_only", "")).toBe(true);
    expect(isSideAllowed("bilateral_only", "both")).toBe(true);
    expect(isSideAllowed("not_applicable", "both")).toBe(false);
    expect(isSideAllowed("not_applicable", "")).toBe(true);
  });
});

describe("normalizeSide", () => {
  it("keeps an already-valid side unchanged", () => {
    expect(normalizeSide("unilateral_or_bilateral", "left")).toBe("left");
    expect(normalizeSide("unilateral_or_bilateral", "both")).toBe("both");
    expect(normalizeSide("unilateral_or_bilateral", "")).toBe("");
    expect(normalizeSide("unilateral_only", "right")).toBe("right");
    expect(normalizeSide("bilateral_only", "both")).toBe("both");
    expect(normalizeSide("not_applicable", "")).toBe("");
  });

  it("falls back bilateral_only -> both for a no-longer-valid side", () => {
    expect(normalizeSide("bilateral_only", "left")).toBe("both");
    expect(normalizeSide("bilateral_only", "right")).toBe("both");
  });

  it("falls back not_applicable -> \"\" for a no-longer-valid side", () => {
    expect(normalizeSide("not_applicable", "left")).toBe("");
    expect(normalizeSide("not_applicable", "right")).toBe("");
    expect(normalizeSide("not_applicable", "both")).toBe("");
  });

  it("falls back unilateral_only -> \"\" for a side it can't disambiguate", () => {
    expect(normalizeSide("unilateral_only", "both")).toBe("");
  });

  it("never reinterprets historical \"\" as \"both\"", () => {
    for (const mode of ALL_MODES) {
      expect(normalizeSide(mode, "")).toBe("");
    }
  });
});

describe("normalizeSideMode", () => {
  it("passes through every known mode", () => {
    for (const mode of ALL_MODES) {
      expect(normalizeSideMode(mode)).toBe(mode);
    }
  });

  it("defaults an unknown/legacy mode string to unilateral_or_bilateral", () => {
    expect(normalizeSideMode("some_future_mode")).toBe(DEFAULT_SIDE_MODE);
    expect(normalizeSideMode("")).toBe(DEFAULT_SIDE_MODE);
  });

  it("defaults a missing registry row (null/undefined) to unilateral_or_bilateral", () => {
    expect(normalizeSideMode(null)).toBe(DEFAULT_SIDE_MODE);
    expect(normalizeSideMode(undefined)).toBe(DEFAULT_SIDE_MODE);
  });
});
