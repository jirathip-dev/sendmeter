import { describe, expect, it } from "vitest";
import {
  appendReadinessSample,
  canConfirmForceSetup,
  claimForceSetupAction,
  emptyForceReadiness,
  emptyForceSetupMemory,
  forceSetupContextKey,
  forceSetupValidityKey,
  forceMeasurementMode,
  forceProtocolMode,
  isForceSetupConfirmed,
  markReadinessZeroed,
  markForceSetupSeen,
  parseForceSetupMemory,
  rememberForceSetup,
  shouldAutoShowForceSetup,
  tareDecision,
  type ForceSetupInputs,
} from "./forceSetup";

const caps = { tare: true, lowBatteryWarning: true, deviceInfo: true };
const noTare = { ...caps, tare: false };
const setup: ForceSetupInputs = {
  mode: "static",
  exercise: "20 mm Edge",
  side: "left",
  equipment: "Portable board",
  preload: "",
  attachment: "Door anchor",
  position: "Feet on mark 2",
};

describe("force setup visibility and validity", () => {
  it("maps plain-language setup choices onto the runtime protocol seam", () => {
    expect(forceProtocolMode("static")).toBe("hold");
    expect(forceProtocolMode("movement")).toBe("reverse_action");
    expect(forceMeasurementMode("hold")).toBe("static");
    expect(forceMeasurementMode("reverse_action")).toBe("movement");
  });

  it("auto-shows once per mode, unless the user disables automatic guides", () => {
    const fresh = emptyForceSetupMemory();
    expect(shouldAutoShowForceSetup(fresh, "static")).toBe(true);
    const seen = markForceSetupSeen(fresh, "static");
    expect(shouldAutoShowForceSetup(seen, "static")).toBe(false);
    expect(shouldAutoShowForceSetup(seen, "movement")).toBe(true);
    expect(shouldAutoShowForceSetup({ ...fresh, autoShow: false }, "static")).toBe(false);
  });

  it("invalidates on mode, exercise, side, or equipment without erasing metadata", () => {
    const remembered = rememberForceSetup(emptyForceSetupMemory(), setup, "2026-08-02T00:00:00Z");
    expect(isForceSetupConfirmed(remembered, setup)).toBe(true);
    for (const changed of [
      { ...setup, mode: "movement" as const },
      { ...setup, exercise: "30 mm Edge" },
      { ...setup, side: "right" as const },
      { ...setup, equipment: "Blue spring" },
    ]) {
      expect(forceSetupValidityKey(changed)).not.toBe(forceSetupValidityKey(setup));
      expect(isForceSetupConfirmed(remembered, changed)).toBe(false);
    }
    expect(remembered.metadataByContext[forceSetupContextKey(setup)]).toEqual({
      equipment: "Portable board",
      preload: "",
      attachment: "Door anchor",
      position: "Feet on mark 2",
    });
    expect(remembered.sideByContext[forceSetupContextKey(setup)]).toBe("left");
  });

  it("keeps confirmation valid when descriptive notes change", () => {
    expect(forceSetupValidityKey({ ...setup, position: "Seat mark 3" })).toBe(
      forceSetupValidityKey(setup),
    );
  });

  it("keeps legacy sensor keys stable and separates cadence-only equipment", () => {
    expect(forceSetupContextKey(setup)).toBe('["static","20 mm edge"]');
    expect(forceSetupValidityKey(setup)).toBe('["static","20 mm edge","left","portable board"]');
    expect(forceSetupContextKey({ ...setup, executionMethod: "cadence_only" })).not.toBe(
      forceSetupContextKey(setup),
    );
  });

  it("recovers safely from missing, malformed, or future storage", () => {
    expect(parseForceSetupMemory(null)).toEqual(emptyForceSetupMemory());
    expect(parseForceSetupMemory("not json")).toEqual(emptyForceSetupMemory());
    expect(parseForceSetupMemory('{"version":2}')).toEqual(emptyForceSetupMemory());
    expect(
      parseForceSetupMemory(
        '{"version":1,"metadataByContext":{"x":{"equipment":7}},"sideByContext":{"x":"up"}}',
      ),
    ).toMatchObject({
      metadataByContext: { x: { equipment: "", preload: "", attachment: "", position: "" } },
      sideByContext: {},
    });
  });
});

describe("force readiness decisions", () => {
  it("latches an unloaded stable window, gradual test load, and target reach", () => {
    let state = emptyForceReadiness(true);
    for (let atMs = 0; atMs <= 1_000; atMs += 100) {
      state = appendReadinessSample(state, { atMs, kg: atMs % 200 ? 0.04 : -0.03 }, 3);
    }
    expect(state.unloadedStable).toBe(true);
    expect(state.signalStableNow).toBe(true);
    state = appendReadinessSample(state, { atMs: 1_100, kg: 2.1 }, 3);
    expect(state.testLoadSeen).toBe(true);
    expect(state.targetReached).toBe(false);
    state = appendReadinessSample(state, { atMs: 1_200, kg: 3.2 }, 3);
    expect(state.targetReached).toBe(true);
  });

  it("prevents tare while loaded, unstable, disconnected, or already claimed", () => {
    expect(tareDecision({ capabilities: caps, connected: true, unloadedStable: true, currentKg: 4, inFlight: false })).toMatchObject({ allowed: false, reason: "Unload the system before taring." });
    expect(tareDecision({ capabilities: caps, connected: true, unloadedStable: false, currentKg: 0, inFlight: false }).allowed).toBe(false);
    expect(tareDecision({ capabilities: caps, connected: false, unloadedStable: true, currentKg: 0, inFlight: false }).allowed).toBe(false);
    expect(tareDecision({ capabilities: caps, connected: true, unloadedStable: true, currentKg: 0, inFlight: true }).allowed).toBe(false);
    expect(tareDecision({ capabilities: caps, connected: true, unloadedStable: true, currentKg: 0, inFlight: false }).allowed).toBe(true);
  });

  it("requires the gradual test load after the zero step", () => {
    const loadedFirst = { ...emptyForceReadiness(true), unloadedStable: true, testLoadSeen: true, peakKg: 4 };
    const tared = markReadinessZeroed(loadedFirst, "tare");
    expect(tared).toMatchObject({ tareComplete: true, testLoadSeen: false, peakKg: 0 });
    const testedAfterTare = appendReadinessSample(tared, { atMs: 2_000, kg: 2.2 }, null);
    expect(testedAfterTare.testLoadSeen).toBe(true);
  });

  it("hides unsupported tare and accepts an explicit honest alternative", () => {
    expect(tareDecision({ capabilities: noTare, connected: true, unloadedStable: true, currentKg: 0, inFlight: false })).toEqual({ visible: false, allowed: false, reason: null });
    const readiness = {
      ...emptyForceReadiness(true),
      unloadedStable: true,
      noTareAcknowledged: true,
      testLoadSeen: true,
    };
    expect(canConfirmForceSetup({ capabilities: noTare, readiness, equipmentConfirmed: true, positionConfirmed: true })).toBe(true);
    expect(canConfirmForceSetup({ capabilities: caps, readiness, equipmentConfirmed: true, positionConfirmed: true })).toBe(false);
  });

  it("confirms cadence-only equipment without requiring sensor readiness", () => {
    expect(canConfirmForceSetup({
      capabilities: caps,
      readiness: emptyForceReadiness(false),
      equipmentConfirmed: true,
      positionConfirmed: true,
      sensor: false,
    })).toBe(true);
  });

  it("deduplicates async actions when the claim is taken before awaiting", () => {
    const claimed = new Set<string>();
    expect(claimForceSetupAction(claimed, "tare")).toBe(true);
    expect(claimForceSetupAction(claimed, "tare")).toBe(false);
    claimed.delete("tare");
    expect(claimForceSetupAction(claimed, "tare")).toBe(true);
  });
});
