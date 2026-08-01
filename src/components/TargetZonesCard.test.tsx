import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { ForceCurveModel } from "../lib/force-curve";
import {
  buildPrehabSelection,
  buildWarmupSelection,
  buildZoneSelection,
  type ZoneSelection,
} from "../lib/zoneSelection";
import {
  resolveAlternatingMaintenance,
  resolveAlternatingRecommendation,
  type AlternatingPrescription,
} from "../lib/alternatingProtocol";
import TargetZonesCard from "./TargetZonesCard";

const model: ForceCurveModel = {
  points: [],
  maxF: 40,
  cf: 20,
  wPrime: 300,
};

function render(
  selected: ZoneSelection | null = null,
  alternatingReady = true,
  alternatingPrescription: AlternatingPrescription | null = null,
  unarmedNotice: { quality: "endurance" | "power-endurance"; tag: string } | null = null,
) {
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
      alternatingReady={alternatingReady}
      alternatingPrescription={alternatingPrescription}
      onClear={() => undefined}
      unarmedNotice={unarmedNotice}
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
    expect(html).toContain("30s × 4/hand");
    expect(html).toContain("about 7m12s");
    expect(html).toContain(
      "Fixed dose · alternates L/R automatically · below critical force · excluded from training balance",
    );
    expect(html).toContain(
      "Prehab alternates automatically and needs a usable force target for both hands.",
    );
    expect(html).not.toContain('aria-label="Session intensity"');
  });

  it("shows Prehab's independently resolved targets for both hands", () => {
    const selected = buildPrehabSelection(model, "FDP")!;
    const prescription = resolveAlternatingMaintenance(selected.protocol, {
      left: { model, prKg: 40 },
      right: { model: { ...model, maxF: 32, cf: null }, prKg: 32 },
    })!;
    const html = render(selected, true, prescription);
    expect(html).toContain("L 14.0 kg · R 9.6 kg");
    expect(html).toContain("about 7m12s");
    expect(html).not.toContain("needs a usable force target for both hands");
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

  it("puts Warm-up beside Prehab and shows the progressive primer without an intensity control", () => {
    const selected = buildWarmupSelection(model, "FDP L")!;
    const prescription = resolveAlternatingMaintenance(selected.protocol, {
      left: { model, prKg: 40 },
      right: { model: { ...model, maxF: 30 }, prKg: 30 },
    })!;
    const html = render(selected, true, prescription);
    expect(html.indexOf("Warm-up")).toBeLessThan(html.indexOf("Prehab"));
    expect(html).toContain("5s→7s→10s holds × 2/hand");
    expect(html).toContain("40% → 55% → 70% PR");
    expect(html).toContain("L 16.0 → 28.0 kg · R 12.0 → 21.0 kg");
    expect(html).toMatch(/about\s+2m57s/);
    expect(html).toContain("do general movement and easy climbing first");
    expect(html).toContain("alternates L/R automatically");
    expect(html).not.toContain('aria-label="Session intensity"');
  });

  it("renders a persistent accessible post-fit unarm status (#333)", () => {
    const html = render(null, true, null, { quality: "endurance", tag: "FDP L" });
    expect(html).toContain('role="status"');
    expect(html).toContain('aria-live="polite"');
    expect(html).toContain(
      "Endurance unarmed — the updated curve no longer has a valid critical-force fit. Add an all-out 30–60s hold to restore it.",
    );
  });

  it("does not render a post-fit status belonging to another tag (#333)", () => {
    const html = render(null, true, null, {
      quality: "endurance",
      tag: "Open hand",
    });
    expect(html).not.toContain('role="status"');
    expect(html).not.toContain("Endurance unarmed");
  });

  it("renders the Power Endurance post-fit guidance (#333)", () => {
    const html = render(null, true, null, {
      quality: "power-endurance",
      tag: "FDP L",
    });
    expect(html).toContain('role="status"');
    expect(html).toContain(
      "Power Endurance unarmed — the updated curve no longer has a usable Hill capability fit. Add all-out holds at varied durations to restore it.",
    );
  });
});
