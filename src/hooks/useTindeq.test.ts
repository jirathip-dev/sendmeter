import { describe, it, expect } from "vitest";
import {
  interruptionNote,
  shouldSalvageOnUnmount,
  summarize,
} from "./useTindeq";

describe("shouldSalvageOnUnmount", () => {
  // #106: this exact gate was shipped INVERTED once (`!sessionAliveRef`
  // instead of the right condition) — a single case like each of these would
  // have caught it immediately.
  it("salvages when measuring, no stop in flight, and enough samples", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: true,
        pendingInterruption: false,
        stopInFlight: false,
        sampleCount: 2,
      }),
    ).toBe(true);
  });

  it("does not salvage when not measuring", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: false,
        pendingInterruption: false,
        stopInFlight: false,
        sampleCount: 50,
      }),
    ).toBe(false);
  });

  it("does not salvage while a Stop is already in flight — the normal path owns it", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: true,
        pendingInterruption: false,
        stopInFlight: true,
        sampleCount: 50,
      }),
    ).toBe(false);
  });

  it("does not salvage a near-empty buffer (fewer than 2 samples)", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: true,
        pendingInterruption: false,
        stopInFlight: false,
        sampleCount: 1,
      }),
    ).toBe(false);
    expect(
      shouldSalvageOnUnmount({
        measuring: true,
        pendingInterruption: false,
        stopInFlight: false,
        sampleCount: 0,
      }),
    ).toBe(false);
  });

  it("requires ALL three conditions at once, not any single one", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: false,
        pendingInterruption: false,
        stopInFlight: true,
        sampleCount: 0,
      }),
    ).toBe(false);
  });

  it("salvages on a pending interruption even though the disconnect callback already cleared measuring (#113 race)", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: false,
        pendingInterruption: true,
        stopInFlight: false,
        sampleCount: 2,
      }),
    ).toBe(true);
  });

  it("pending interruption still defers to a Stop in flight — that path owns the data", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: false,
        pendingInterruption: true,
        stopInFlight: true,
        sampleCount: 50,
      }),
    ).toBe(false);
  });

  it("pending interruption still requires at least 2 samples", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: false,
        pendingInterruption: true,
        stopInFlight: false,
        sampleCount: 1,
      }),
    ).toBe(false);
    expect(
      shouldSalvageOnUnmount({
        measuring: false,
        pendingInterruption: true,
        stopInFlight: false,
        sampleCount: 0,
      }),
    ).toBe(false);
  });

  it("no salvage once the interruption was handled (flag cleared) — the dup guard", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: false,
        pendingInterruption: false,
        stopInFlight: false,
        sampleCount: 50,
      }),
    ).toBe(false);
  });

  it("measuring and pendingInterruption are OR-ed, not AND-ed", () => {
    expect(
      shouldSalvageOnUnmount({
        measuring: true,
        pendingInterruption: true,
        stopInFlight: false,
        sampleCount: 2,
      }),
    ).toBe(true);
  });
});

describe("interruptionNote", () => {
  // #117: a drop that fired while ForceView was unmounted is recovered on
  // remount as a raw whole-buffer save that may overlap per-rep rows — it
  // must carry a label (mirroring salvage's "Recovered after sign-out") so
  // it can't masquerade as a clean pull.
  it("labels a remount recovery (this instance never observed measuring)", () => {
    expect(interruptionNote(false)).toBe("Recovered after connection loss");
  });

  it("leaves a mounted interruption unlabeled — it's the normal stop path", () => {
    expect(interruptionNote(true)).toBe("");
  });
});

describe("summarize", () => {
  it("returns null for an empty buffer", () => {
    expect(summarize([])).toBe(null);
  });

  it("computes duration/peak/avg from the last sample and rounds kg to 2dp", () => {
    const result = summarize([
      { t: 0, kg: 10.001 },
      { t: 500.4, kg: 30.005 },
      { t: 1000.6, kg: 20 },
    ]);
    expect(result).not.toBeNull();
    expect(result!.durationMs).toBe(1001); // last sample's t, rounded
    expect(result!.peakKg).toBe(30.01); // rounded from 30.005
    expect(result!.avgKg).toBe(20); // (10 + 30.01 + 20) / 3, rounded to 2dp
    expect(result!.samples).toHaveLength(3);
  });
});
