import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { ForceCurveModel } from "../lib/force-curve";
import { buildPrehabSelection } from "../lib/zoneSelection";
import TargetZonesCard from "./TargetZonesCard";

const model: ForceCurveModel = {
  points: [],
  maxF: 40,
  cf: 20,
  wPrime: 300,
};

function render(selected = null as ReturnType<typeof buildPrehabSelection>) {
  return renderToStaticMarkup(
    <TargetZonesCard
      tag="FDP L"
      model={model}
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
});
