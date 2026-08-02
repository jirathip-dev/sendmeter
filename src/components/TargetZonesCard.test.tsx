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

  it("shows the progressive Prehab dose without an intensity control", () => {
    const html = render(buildPrehabSelection(model, "FDP L"));
    expect(html).toContain("1m30s→1m→30s→30s · 1 hold/hand per set");
    expect(html).toContain("at least 20s recovery per hand");
    expect(html).toContain("about 7m21s");
    expect(html).toContain(
      "Progressive duration · alternates L/R · below critical force · excluded from training balance",
    );
    expect(html).toContain(
      "Alternating Prehab needs a usable force target for both hands.",
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
    expect(html).toContain("about 7m21s");
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
    expect(html).toContain("20s→15s→10s→10s · 1 pull/hand per set");
    expect(html).toContain("at least 1m recovery per hand");
    expect(html).toContain("30% → 40% → 50% → 60% PR");
    expect(html).toContain("L 12.0 → 24.0 kg · R 9.0 → 18.0 kg");
    expect(html).toMatch(/about\s+4m27s/);
    expect(html).toContain("do general movement and easy climbing first");
    expect(html).toContain("alternates L/R");
    expect(html).not.toContain('aria-label="Session intensity"');
  });

  it("allows selected-side maintenance while missing the other-hand reference", () => {
    const selected = buildWarmupSelection(model, "FDP L", 40, false)!;
    const html = render(selected, false);
    expect(html).toMatch(/type="checkbox"[^>]*disabled/);
    expect(html).not.toMatch(/type="checkbox"[^>]*checked/);
    expect(html).toContain("1 pull per set");
    expect(html).not.toContain("1 pull/hand per set");
    expect(html).toContain("selected side only");
    expect(html).toMatch(/about\s+3m55s/);
  });

  it("still allows turning alternation off when the other-hand reference is missing", () => {
    const selected = buildWarmupSelection(model, "FDP L")!;
    const html = render(selected, false);
    expect(html).toMatch(/type="checkbox"[^>]*checked/);
    expect(html).not.toMatch(/type="checkbox"[^>]*disabled/);
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
