import { describe, it, expect } from "vitest";
import {
  interruptionNote,
  recoveredTagSide,
  samplesThrough,
  shouldDiscardHandsFreeSalvage,
  shouldSalvageOnUnmount,
  snapshotInterruption,
  summarize,
} from "./useTindeq";
import type { SalvageContext } from "./useTindeq";
import type { TindeqSide } from "../types";

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

describe("shouldDiscardHandsFreeSalvage", () => {
  // #682 follow-up (reviewer blocking finding): the unmount-salvage cleanup is
  // a persist boundary, so a trivial hands-free-started rep must be dropped
  // there — it never enters the recording queue and is never reported queued.
  it("discards a below-min-peak hands-free salvage rep", () => {
    expect(
      shouldDiscardHandsFreeSalvage({
        wasHandsFree: true,
        isSpecialized: false,
        peakKg: 2.9,
        durationMs: 10_000,
      }),
    ).toBe(true);
  });

  it("discards a below-min-duration hands-free salvage rep", () => {
    expect(
      shouldDiscardHandsFreeSalvage({
        wasHandsFree: true,
        isSpecialized: false,
        peakKg: 4,
        durationMs: 1_400,
      }),
    ).toBe(true);
  });

  it("does not discard a qualifying hands-free salvage rep", () => {
    expect(
      shouldDiscardHandsFreeSalvage({
        wasHandsFree: true,
        isSpecialized: false,
        peakKg: 3.1,
        durationMs: 1_600,
      }),
    ).toBe(false);
  });

  it("never gates a manual (hands-free opted-out) salvage rep", () => {
    expect(
      shouldDiscardHandsFreeSalvage({
        wasHandsFree: false,
        isSpecialized: false,
        peakKg: 0.5,
        durationMs: 200,
      }),
    ).toBe(false);
  });

  it("never gates a specialized (guided/protocol) salvage rep", () => {
    expect(
      shouldDiscardHandsFreeSalvage({
        wasHandsFree: true,
        isSpecialized: true,
        peakKg: 0.5,
        durationMs: 200,
      }),
    ).toBe(false);
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

describe("#119 remount-recovery label", () => {
  function ctx(tag: string, side: TindeqSide): SalvageContext {
    return {
      tag,
      side,
      groupId: null,
      userId: "u1",
      stopInFlight: false,
      wasHandsFree: false,
    };
  }
  const EMPTY = { tag: "", side: "" as TindeqSide };

  // The whole bug is an ordering problem, so this replays the real lifecycle:
  // TindeqProvider (salvageContextRef + the sample buffer) outlives ForceView,
  // which unmounts and remounts on every tab switch — the registered context
  // is mutable shared state, and WHEN it is read decides what gets saved.
  it("saves the pre-Start tag/side when the drop fired while ForceView was unmounted", () => {
    // 1. ForceView mounted: user sets Half crimp / left, then presses Start.
    let registered: SalvageContext | null = ctx("Half crimp", "left");

    // 2. User switches tabs. ForceView unmounts; the provider keeps measuring
    //    and the context ref is deliberately NOT cleared.

    // 3. The Progressor drops mid-measurement. The claim — and the label
    //    snapshot with it — is taken here, at drop time.
    const snapshot = snapshotInterruption(registered);

    // 4. ForceView remounts to recover. Its own setSalvageContext effect runs
    //    first and re-registers a fresh, still-empty context; the async
    //    fetchRecordings tag seeding has not landed yet either.
    registered = ctx("", "");

    // 5. The 0 ms-deferred handleStop finally runs, with empty view state.
    expect(recoveredTagSide(EMPTY, snapshot)).toEqual({
      tag: "Half crimp",
      side: "left",
    });
    // The note is unchanged by the relabel — a recovered pull must still be
    // distinguishable from a clean one.
    expect(interruptionNote(false)).toBe("Recovered after connection loss");

    // And this is why the snapshot is load-bearing: reading the ref at THIS
    // point instead (what the recovery path effectively did before #119) is
    // deterministically empty, because step 4 already clobbered it.
    expect(recoveredTagSide(EMPTY, snapshotInterruption(registered))).toEqual(
      EMPTY,
    );
  });

  it("lets a remount that DID seed its own tag/side win — the snapshot is a fallback, not an override", () => {
    const snapshot = snapshotInterruption(ctx("Half crimp", "left"));
    expect(
      recoveredTagSide({ tag: "Open hand", side: "right" }, snapshot),
    ).toEqual({ tag: "Open hand", side: "right" });
  });

  it("falls back per field, so a half-seeded remount keeps what it has", () => {
    const snapshot = snapshotInterruption(ctx("Half crimp", "left"));
    expect(recoveredTagSide({ tag: "Open hand", side: "" }, snapshot)).toEqual({
      tag: "Open hand",
      side: "left",
    });
    expect(recoveredTagSide({ tag: "", side: "right" }, snapshot)).toEqual({
      tag: "Half crimp",
      side: "right",
    });
  });

  it("stays empty when no context was ever registered — same fallback the sign-out salvage takes", () => {
    expect(snapshotInterruption(null)).toBe(null);
    expect(snapshotInterruption(undefined)).toBe(null);
    expect(recoveredTagSide(EMPTY, null)).toEqual(EMPTY);
  });

  it("keeps only the label fields — a recovery blob never inherits the session group", () => {
    expect(snapshotInterruption(ctx("Half crimp", "left"))).toEqual({
      tag: "Half crimp",
      side: "left",
    });
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

  it("#462: floors a single-sample buffer's duration at 1ms — the sample's t is always 0", () => {
    const result = summarize([{ t: 0, kg: 12.5 }]);
    expect(result).not.toBeNull();
    expect(result!.durationMs).toBe(1);
  });
});

describe("samplesThrough (#400)", () => {
  const samples = [
    { t: 0, kg: 10 },
    { t: 500, kg: 10 },
    { t: 1_000, kg: 0.5 },
    { t: 2_500, kg: 0 },
  ];

  it("removes the release grace tail at the first low sample", () => {
    expect(samplesThrough(samples, 1_000)).toEqual(samples.slice(0, 3));
  });

  it("preserves normal manual-stop samples when no boundary is supplied", () => {
    expect(samplesThrough(samples, undefined)).toBe(samples);
  });
});
