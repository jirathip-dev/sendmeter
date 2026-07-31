import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { ForceCurveModel } from "../lib/force-curve";
import {
  buildPrehabSelection,
  buildWarmupSelection,
  type ZoneSelection,
} from "../lib/zoneSelection";
import TargetZonesCard from "./TargetZonesCard";

const model: ForceCurveModel = {
  points: [],
  maxF: 40,
  cf: 20,
  wPrime: 300,
};

function render(selected: ZoneSelection | null = null) {
  return renderToStaticMarkup(
    <TargetZonesCard
      tag="FDP L"
      model={model}
      prKg={40}
      selected={selected}
      onSelect={() => undefined}
      intensityPct={100}
      onIntensityChange={() => undefined}
      locked={false}
      onClear={() => undefined}
    />,
  );
}

describe("TargetZonesCard (#344)", () => {
  it("renders Training and Maintenance as two groups in one card", () => {
    const html = render();
    expect(html).toContain("Training");
    expect(html).toContain("Maintenance");
    expect(html).toContain("Power");
    expect(html).toContain("Warm-up");
    expect(html).toContain("Prehab");
    expect(html).toContain('aria-label="Session intensity"');
  });

  it("shows the compact fixed Prehab dose without an intensity control", () => {
    const html = render(buildPrehabSelection(model, "FDP L"));
    expect(html).toContain("30s × 4");
    expect(html).toContain(
      "Fixed dose · below critical force · excluded from training balance",
    );
    expect(html).not.toContain('aria-label="Session intensity"');
  });

  it("puts Warm-up beside Prehab and shows the progressive primer without an intensity control", () => {
    const html = render(buildWarmupSelection(model, "FDP L"));
    expect(html.indexOf("Warm-up")).toBeLessThan(html.indexOf("Prehab"));
    expect(html).toContain("5s→7s→10s holds × 2 reps");
    expect(html).toContain("40% → 55% → 70% PR");
    expect(html).toContain("do general movement and easy climbing first");
    expect(html).not.toContain('aria-label="Session intensity"');
  });
});
