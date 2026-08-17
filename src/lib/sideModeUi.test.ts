import { describe, expect, it } from "vitest";
import type { TindeqSide } from "../types";
import {
  DEFAULT_SIDE_MODE,
  isSideAllowed,
  type ExerciseSideMode,
} from "./sideMode";
import {
  selectionSide,
  sideLabel,
  sideModeForTag,
  SIDE_MODE_OPTIONS,
  sideOptionsFor,
  sideSummaryVisible,
} from "./sideModeUi";

const ALL_SIDES: TindeqSide[] = ["", "left", "right", "both"];
const ALL_MODES: ExerciseSideMode[] = [
  "unilateral_or_bilateral",
  "unilateral_only",
  "bilateral_only",
  "not_applicable",
];

describe("sideOptionsFor (per-mode chip rendering policy)", () => {
  it("keeps the legacy four-chip selector byte-for-byte for the default mode", () => {
    expect(sideOptionsFor(DEFAULT_SIDE_MODE)).toEqual([
      { value: "", label: "—" },
      { value: "left", label: "Left" },
      { value: "right", label: "Right" },
      { value: "both", label: "Both" },
    ]);
  });

  it("offers Left/Right only for unilateral_only", () => {
    expect(sideOptionsFor("unilateral_only")).toEqual([
      { value: "left", label: "Left" },
      { value: "right", label: "Right" },
    ]);
  });

  it("offers no chips for the no-choice modes", () => {
    expect(sideOptionsFor("bilateral_only")).toEqual([]);
    expect(sideOptionsFor("not_applicable")).toEqual([]);
  });

  it("every offered chip is an allowed side under its mode", () => {
    for (const mode of ALL_MODES) {
      for (const option of sideOptionsFor(mode)) {
        expect(isSideAllowed(mode, option.value)).toBe(true);
      }
    }
  });
});

describe("selectionSide (deterministic fallback)", () => {
  it("keeps an already-valid selection unchanged under the default mode", () => {
    for (const side of ALL_SIDES) {
      expect(selectionSide("unilateral_or_bilateral", side)).toBe(side);
    }
  });

  it("falls back left/right → both for a bilateral_only exercise", () => {
    expect(selectionSide("bilateral_only", "left")).toBe("both");
    expect(selectionSide("bilateral_only", "right")).toBe("both");
  });

  it("auto-sets a fresh selection to both for a bilateral_only exercise", () => {
    // The mode defines the side — a bilateral exercise with no choice must
    // never record an unspecified side, and that is NOT a reinterpretation
    // of historical data (slice-1's normalizeSide "" → "" still stands).
    expect(selectionSide("bilateral_only", "")).toBe("both");
    expect(selectionSide("bilateral_only", "both")).toBe("both");
  });

  it("resolves every input to the canonical no-side for not_applicable", () => {
    for (const side of ALL_SIDES) {
      expect(selectionSide("not_applicable", side)).toBe("");
    }
  });

  it("resolves both → the unspecified selection for unilateral_only", () => {
    expect(selectionSide("unilateral_only", "both")).toBe("");
    expect(selectionSide("unilateral_only", "left")).toBe("left");
  });

  it("never writes a side invalid under the mode", () => {
    for (const mode of ALL_MODES) {
      for (const side of ALL_SIDES) {
        expect(isSideAllowed(mode, selectionSide(mode, side))).toBe(true);
      }
    }
  });

  it("legacy empty selections stay untouched under the unilateral modes", () => {
    expect(selectionSide("unilateral_or_bilateral", "")).toBe("");
    expect(selectionSide("unilateral_only", "")).toBe("");
  });
});

describe("sideSummaryVisible / sideLabel", () => {
  it("omits the side summary entirely for not_applicable", () => {
    expect(sideSummaryVisible("not_applicable")).toBe(false);
    for (const mode of ALL_MODES) {
      if (mode !== "not_applicable")
        expect(sideSummaryVisible(mode)).toBe(true);
    }
  });

  it("labels every side exactly like the legacy selector", () => {
    expect(sideLabel("")).toBe("—");
    expect(sideLabel("left")).toBe("Left");
    expect(sideLabel("right")).toBe("Right");
    expect(sideLabel("both")).toBe("Both");
  });
});

describe("SIDE_MODE_OPTIONS", () => {
  it("offers all four modes", () => {
    expect(SIDE_MODE_OPTIONS.map((o) => o.value)).toEqual(ALL_MODES);
  });
});

describe("sideModeForTag", () => {
  const registry = [{ name: "FDP", sideMode: "bilateral_only" as const }];

  it("reads a configured mode from the registry", () => {
    expect(sideModeForTag("FDP", registry)).toBe("bilateral_only");
  });

  it("defaults an unconfigured tag to the legacy mode", () => {
    expect(sideModeForTag("Crimps", registry)).toBe(DEFAULT_SIDE_MODE);
    expect(sideModeForTag("", registry)).toBe(DEFAULT_SIDE_MODE);
  });

  it("normalizes an unknown mode string to the default", () => {
    const bad = [
      { name: "FDP", sideMode: "some_future_mode" as ExerciseSideMode },
    ];
    expect(sideModeForTag("FDP", bad)).toBe(DEFAULT_SIDE_MODE);
  });
});
