import { describe, it, expect } from "vitest";
import { nextLockedGaugeInputs, type GaugeInputs } from "./gaugeInputLock";

function inputs(over: Partial<GaugeInputs> = {}): GaugeInputs {
  return {
    tag: "FDP",
    chartSide: null,
    zoneSel: null,
    preset: null,
    intensityPct: 100,
    pendingTag: "FDP",
    pendingSide: "",
    prKg: 40,
    ...over,
  };
}

describe("nextLockedGaugeInputs (#298 round 5)", () => {
  it("tracks a live change while not measuring", () => {
    const live = inputs({ tag: "FDP" });
    const locked = inputs({ tag: "stale" });
    expect(nextLockedGaugeInputs(false, live, locked)).toBe(live);
  });

  it("returns the same locked reference when live already matches (no update needed)", () => {
    const locked = inputs({ tag: "FDP" });
    const live = inputs({ tag: "FDP" }); // same values, different object
    expect(nextLockedGaugeInputs(false, live, locked)).toBe(locked);
  });

  it("a tag/side/intensity change mid-run does not change the plan the recorder and the display walk", () => {
    // Rising edge: measuring starts with the locked snapshot already synced
    // to what was live a moment before (ForceView's render-time sync).
    let locked = inputs({ tag: "FDP", chartSide: "right", intensityPct: 100 });

    // A brand-new tag typed mid-run, then joining allTags and flipping
    // effectiveTag; a side re-pick; an intensity nudge — none of it may
    // reach the running plan.
    locked = nextLockedGaugeInputs(true, inputs({ tag: "hip rotation" }), locked);
    locked = nextLockedGaugeInputs(true, inputs({ chartSide: "left" }), locked);
    locked = nextLockedGaugeInputs(true, inputs({ intensityPct: 70 }), locked);

    expect(locked).toEqual(inputs({ tag: "FDP", chartSide: "right", intensityPct: 100 }));
  });

  it("locks the armed zone/preset selection too, not just tag/side", () => {
    const zoneA = { target: {}, protocol: { id: "zone:strength" } } as unknown as GaugeInputs["zoneSel"];
    const zoneB = { target: {}, protocol: { id: "zone:power" } } as unknown as GaugeInputs["zoneSel"];
    let locked = inputs({ zoneSel: zoneA });
    // Minimized, a different zone tapped mid-run — the run must keep
    // walking zoneA's timeline, not silently re-arm to zoneB.
    locked = nextLockedGaugeInputs(true, inputs({ zoneSel: zoneB }), locked);
    expect(locked.zoneSel).toBe(zoneA);
  });

  it("re-syncs to the new live value the instant measuring ends", () => {
    const locked = inputs({ tag: "FDP" });
    const liveAfterStop = inputs({ tag: "hip rotation" });
    expect(nextLockedGaugeInputs(false, liveAfterStop, locked)).toBe(liveAfterStop);
  });

  it("locks the raw pendingTag/pendingSide too, separate from the resolved tag", () => {
    let locked = inputs({ pendingTag: "FDP", pendingSide: "left" });
    // A tag change mid-run (e.g. via the tab's TagSideEditor) must not reach
    // reps already filed under the old tag's zone.
    locked = nextLockedGaugeInputs(
      true,
      inputs({ pendingTag: "hip rotation", pendingSide: "right" }),
      locked,
    );
    expect(locked.pendingTag).toBe("FDP");
    expect(locked.pendingSide).toBe("left");
  });

  it("locks prKg, so a new PR set mid-run doesn't move a later rep's target", () => {
    let locked = inputs({ prKg: 40 });
    // Rep 1 sets a new PR — `recordings` (and so `curveRecordings`) grows —
    // but the %-of-PR target for the rest of this run must not move.
    locked = nextLockedGaugeInputs(true, inputs({ prKg: 45 }), locked);
    expect(locked.prKg).toBe(40);
  });

  it("keeps holding across a disconnect gap even after measuring itself reads false", () => {
    // #298 round 5 (finding 1): a mid-run BLE drop sets `measuring` false in
    // the SAME render it claims the interruption — the caller is expected to
    // pass `measuring || pendingInterruption`, so simulate that combined
    // value staying true here even though "measuring" alone would not.
    let locked = inputs({ tag: "FDP", preset: null });
    const midRunPreset = { id: "custom:1" } as unknown as GaugeInputs["preset"];
    locked = nextLockedGaugeInputs(true, inputs({ tag: "FDP", preset: midRunPreset }), locked);
    // Drop fires: a naive caller passing bare `measuring` would unlock here.
    // The combined runActive flag must not.
    locked = nextLockedGaugeInputs(
      true, // measuring || pendingInterruption
      inputs({ tag: "cleared to something else", preset: null }),
      locked,
    );
    expect(locked.tag).toBe("FDP");
    expect(locked.preset).toBe(null);
    // Only once the caller passes false (pendingInterruption cleared inside
    // tindeq.stop(), the run genuinely over) does it re-sync.
    const liveAfterStop = inputs({ tag: "next tag" });
    locked = nextLockedGaugeInputs(false, liveAfterStop, locked);
    expect(locked).toBe(liveAfterStop);
  });

  it("locks onto whatever is live at the NEXT Start, not the previous run's snapshot", () => {
    const runA = inputs({ tag: "FDP" });
    let locked = nextLockedGaugeInputs(true, inputs({ tag: "ignored" }), runA);
    expect(locked).toBe(runA);

    // Falling edge, then idle tracking right up to the next Start.
    locked = nextLockedGaugeInputs(false, inputs({ tag: "hip rotation" }), locked);
    const runBLive = inputs({ tag: "hip rotation", intensityPct: 90 });
    locked = nextLockedGaugeInputs(false, runBLive, locked);

    // Next rising edge: holds exactly the snapshot live right before it.
    locked = nextLockedGaugeInputs(true, inputs({ tag: "ignored again" }), locked);
    expect(locked).toBe(runBLive);
  });
});
