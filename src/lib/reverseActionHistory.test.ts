import { describe, expect, it } from "vitest";
import {
  cadenceMarkerLabel,
  reverseActionMetricItems,
} from "./reverseActionHistory";

describe("Reverse Action History presentation", () => {
  it("formats all stored set metrics with peak kept secondary", () => {
    const items = reverseActionMetricItems(
      {
        meanKg: 20.25,
        coefficientVariationPct: 4.2,
        inTargetPct: 87.6,
        timeUnderTensionMs: 9_840,
        driftPct: -3.4,
        cadenceAdherencePct: 99.9,
      },
      23.44,
    );

    expect(items.map(({ label, value }) => ({ label, value }))).toEqual([
      { label: "Mean", value: "20.3 kg" },
      { label: "CV", value: "4.2%" },
      { label: "In target", value: "87.6%" },
      { label: "Tension", value: "9.8s" },
      { label: "Drift", value: "-3.4%" },
      { label: "Cadence", value: "99.9%" },
      { label: "Peak", value: "23.4 kg" },
    ]);
    expect(items.at(-1)?.explanation).toContain("secondary");
    expect(items.find((item) => item.label === "Cadence")?.explanation).toContain(
      "not motion detection",
    );
  });

  it("renders absent legacy values honestly and labels prescribed markers", () => {
    expect(reverseActionMetricItems(null, null).every((item) => item.value === "—")).toBe(true);
    expect(cadenceMarkerLabel({ tMs: 3_000, rep: 2, direction: "return" })).toBe(
      "2 RETURN",
    );
  });
});
