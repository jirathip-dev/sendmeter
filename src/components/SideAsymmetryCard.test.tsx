import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import SideAsymmetryCard from "./SideAsymmetryCard";
import type { TindeqRecordingMeta } from "../types";

function rec(
  peakKg: number,
  side: "left" | "right",
  over: Partial<TindeqRecordingMeta> = {},
): TindeqRecordingMeta {
  return {
    id: `r-${side}-${peakKg}-${Math.random()}`,
    recordedAt: "2026-07-20T10:00:00Z",
    durationMs: 5_000,
    peakKg,
    avgKg: peakKg * 0.9,
    sampleCount: 100,
    note: "",
    tag: "FDP",
    side,
    groupId: null,
    protocolRunId: null,
    setNo: null,
    zone: null,
    ...over,
  };
}

// #325 — a Prehab hold is submax by construction (30s at 0.70×CF); the card
// must never let it stand in for a side's max effort.
describe("SideAsymmetryCard (#325)", () => {
  it("reports asymmetry from real efforts, unaffected by a same-side Prehab hold", () => {
    const html = renderToStaticMarkup(
      <SideAsymmetryCard
        recordings={[
          rec(40, "left"),
          rec(38, "right"),
          rec(11.6, "left", { zone: "prehab", durationMs: 30_000 }),
        ]}
      />,
    );
    expect(html).toContain("40.0");
    expect(html).toContain("38.0");
  });

  it("does not fabricate an asymmetry from a lone Prehab hold on one side", () => {
    // No real effort recorded on the right at all — only a submax Prehab
    // hold. A naive best-peak read would crown it "right's max" and render
    // a ~70% asymmetry with the risk flag off a hold that was never a
    // maximal-intent effort.
    const html = renderToStaticMarkup(
      <SideAsymmetryCard
        recordings={[
          rec(40, "left"),
          rec(11.6, "right", { zone: "prehab", durationMs: 30_000 }),
        ]}
      />,
    );
    // Only one side has an effort recording — the card must not render at
    // all (it renders only when both sides have EFFORT data).
    expect(html).toBe("");
  });

  it("does not fabricate an asymmetry from a lone Warm-up hold on one side", () => {
    const html = renderToStaticMarkup(
      <SideAsymmetryCard
        recordings={[
          rec(40, "left"),
          rec(28, "right", { zone: "warmup", durationMs: 10_000 }),
        ]}
      />,
    );
    expect(html).toBe("");
  });

  it("still flags a real asymmetry between two effort recordings", () => {
    const html = renderToStaticMarkup(
      <SideAsymmetryCard recordings={[rec(50, "left"), rec(40, "right")]} />,
    );
    expect(html).toContain("worth rebalancing");
  });
});
