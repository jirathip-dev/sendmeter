import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { ForceCurveModel } from "../lib/force-curve";
import { buildPrehabSelection, buildZoneSelection } from "../lib/zoneSelection";
import { resolveAlternatingRecommendation, type AlternatingPrescription } from "../lib/alternatingProtocol";
import TargetZonesCard from "./TargetZonesCard";

const model: ForceCurveModel = {
  points: [],
  maxF: 40,
  cf: 20,
  wPrime: 300,
};

function render(
  selected = null as ReturnType<typeof buildPrehabSelection>,
  alternatingReady = true,
  alternatingPrescription: AlternatingPrescription | null = null,
) {
  return renderToStaticMarkup(
    <TargetZonesCard
      tag="FDP L"
      model={model}
      selected={selected}
      onSelect={() => undefined}
      intensityPct={100}
      onIntensityChange={() => undefined}
      locked={false}
      alternatingReady={alternatingReady}
      alternatingPrescription={alternatingPrescription}
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

  it("explains why an alternating recommendation is unavailable (#331)", () => {
    const html = render(buildZoneSelection(model, "strength", "FDP", false), false);
    expect(html).toContain("Alternating needs a fit for both hands.");
    expect(html).toMatch(/type="checkbox"[^>]*disabled/);
  });

  it("shows both recommended targets and per-hand holds (#331)", () => {
    const right = { ...model, maxF: 30, cf: 12, wPrime: 180 };
    const prescription = resolveAlternatingRecommendation(
      { left: { model, prKg: 40 }, right: { model: right, prKg: 30 } },
      "strength",
      "FDP",
      80,
      2,
    )!;
    const html = render(
      buildZoneSelection(model, "strength", "FDP", true, 80),
      true,
      prescription,
    );
    expect(html).toContain(`L ${prescription.left.targets[0]!.kg.toFixed(1)} kg · R`);
    expect(html).toContain(`L hold ${prescription.left.targets[0]!.workS}s · R hold`);
  });
});
