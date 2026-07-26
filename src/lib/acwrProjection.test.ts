import { afterEach, describe, expect, it, vi } from "vitest";
import {
  LAMBDA_ACUTE,
  LAMBDA_CHRONIC,
  PROJECTION_DAYS,
  REST_DAY_ACWR_DECAY,
  SUGGESTION_RPE,
  acwrOf,
  loadForRatio,
  projectAcwr,
  stepEwmaLoad,
} from "./acwrProjection";
import { daysAgo, today } from "./dates";
import { computeAcwr, ewma, ewmaLoadState } from "./metrics";
import type { EwmaLoadState } from "./metrics";
import type { Session } from "../types";

function session(date: string, load: number): Session {
  return {
    id: `s-${date}-${load}`,
    date,
    type: "board",
    typeLabel: "Board",
    duration: 60,
    rpe: 5,
    rpeConfirmed: true,
    load,
    note: "",
    phase: "capacity",
    groupId: null,
    workoutSource: null,
  };
}

// A deterministic 60-day history. Kept inside 60 days on purpose: the EWMA
// lookback is 90 days, so nothing falls out of the window when the clock
// advances a day in the parity test below.
function history(): Session[] {
  return Array.from({ length: 60 }, (_, i) => session(daysAgo(i), 100 + ((i * 37) % 210)));
}

const CAPACITY_BAND = { low: 0.9, high: 1.1 };

afterEach(() => {
  vi.useRealTimers();
});

describe("decay constants", () => {
  it("derives lambdas from the 7/28-day EWMA spans", () => {
    expect(LAMBDA_ACUTE).toBe(0.25); // 2/8
    expect(LAMBDA_CHRONIC).toBeCloseTo(0.0689655, 7); // 2/29
  });

  it("a rest day multiplies ACWR by ~0.806, whatever the starting ratio", () => {
    expect(REST_DAY_ACWR_DECAY).toBeCloseTo(0.8055556, 7);
    for (const start of [
      { acute: 300, chronic: 300 }, // 1.00
      { acute: 90, chronic: 300 }, // 0.30
      { acute: 700, chronic: 300 }, // 2.33
    ]) {
      const before = acwrOf(start)!;
      const after = acwrOf(stepEwmaLoad(start, 0))!;
      expect(after / before).toBeCloseTo(REST_DAY_ACWR_DECAY, 12);
    }
  });

  it("the ~19.4%/day slide takes 1.20 under 0.80 in two rest days", () => {
    const day1 = 1.2 * REST_DAY_ACWR_DECAY;
    const day2 = day1 * REST_DAY_ACWR_DECAY;
    expect(day1).toBeGreaterThan(0.8);
    expect(day2).toBeLessThan(0.8);
  });
});

describe("stepEwmaLoad", () => {
  it("is exactly the recurrence ewma() applies, for any load", () => {
    const series = [80, 0, 240, 300, 0, 0, 155];
    const state: EwmaLoadState = {
      acute: ewma(series, 7)[series.length - 1]!,
      chronic: ewma(series, 28)[series.length - 1]!,
    };
    for (const load of [0, 420]) {
      const extended = [...series, load];
      const stepped = stepEwmaLoad(state, load);
      expect(stepped.acute).toBeCloseTo(ewma(extended, 7)[extended.length - 1]!, 12);
      expect(stepped.chronic).toBeCloseTo(ewma(extended, 28)[extended.length - 1]!, 12);
    }
  });
});

describe("projectAcwr", () => {
  it("day 0 IS today's ratio — the same number the ACWR card shows", () => {
    const sessions = history();
    const p = projectAcwr(ewmaLoadState(sessions), CAPACITY_BAND)!;
    expect(p.days[0]!.dayOffset).toBe(0);
    expect(p.days[0]!.date).toBe(today());
    expect(p.days[0]!.acwr).toBe(computeAcwr(sessions).acwr);
  });

  it("projects PROJECTION_DAYS days past today", () => {
    const p = projectAcwr(ewmaLoadState(history()), CAPACITY_BAND)!;
    expect(PROJECTION_DAYS).toBe(7);
    expect(p.days).toHaveLength(PROJECTION_DAYS + 1);
    expect(p.days.map((d) => d.dayOffset)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
  });

  it("a projected zero-load day reproduces what ewmaAcwr computes the next day", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 2, 15, 12, 0, 0));
    const sessions = history();
    const projected = projectAcwr(ewmaLoadState(sessions), null)!.days[1]!.acwr;

    // One day later, nothing logged: the real computation should land where
    // the projection said it would. Not bit-identical — the 90-day window
    // slides, so the mean seed decays one step less than a pure forward step
    // assumes. That residual is ~1e-4 of the ratio and shrinks with history.
    vi.setSystemTime(new Date(2026, 2, 16, 12, 0, 0));
    expect(computeAcwr(sessions).acwr!).toBeCloseTo(projected, 3);
  });

  it("returns null with no session history and with a zero chronic term", () => {
    expect(projectAcwr(ewmaLoadState([]), CAPACITY_BAND)).toBeNull();
    expect(projectAcwr({ acute: 100, chronic: 0 }, CAPACITY_BAND)).toBeNull();
  });

  it("still projects the curve with no phase band, but says nothing about fit", () => {
    const p = projectAcwr({ acute: 300, chronic: 300 }, null)!;
    expect(p.days).toHaveLength(8);
    expect(p.days.every((d) => d.fit === null)).toBe(true);
    expect(p.band).toBeNull();
    expect(p.fallsBelow).toBeNull();
    expect(p.entersBand).toBeNull();
    expect(p.keepInBand).toBeNull();
  });
});

describe("band crossing", () => {
  it("reports the first day the curve drops under the band floor", () => {
    // 1.00 today, capacity floor 0.90: 0.806 on day 1 is already under.
    const p = projectAcwr({ acute: 300, chronic: 300 }, CAPACITY_BAND)!;
    expect(p.days[0]!.fit).toBe("on");
    expect(p.fallsBelow!.dayOffset).toBe(1);
    expect(p.entersBand).toBeNull();
  });

  it("never crosses inside the horizon → null", () => {
    // Floor at 0.10 with a 1.00 start: 0.806^7 ≈ 0.196, still above.
    const p = projectAcwr({ acute: 300, chronic: 300 }, { low: 0.1, high: 1.5 })!;
    expect(p.fallsBelow).toBeNull();
    expect(p.keepInBand).toBeNull();
  });

  it("already below the band: the very first projected day is below too", () => {
    const p = projectAcwr({ acute: 150, chronic: 300 }, CAPACITY_BAND)!; // 0.50
    expect(p.days[0]!.fit).toBe("below");
    expect(p.fallsBelow!.dayOffset).toBe(1);
    expect(p.entersBand).toBeNull();
  });

  it("already above the band: reports when the decay brings it back in, then out", () => {
    const p = projectAcwr({ acute: 600, chronic: 300 }, CAPACITY_BAND)!; // 2.00
    expect(p.days[0]!.fit).toBe("above");
    // 2.00 → 1.611 → 1.298 → 1.046 (in band) → 0.843 (below)
    expect(p.entersBand!.dayOffset).toBe(3);
    expect(p.entersBand!.fit).toBe("on");
    expect(p.fallsBelow!.dayOffset).toBe(4);
  });
});

describe("loadForRatio", () => {
  it("round-trips: the load it returns lands exactly on the ratio asked for", () => {
    const states: EwmaLoadState[] = [
      { acute: 300, chronic: 300 },
      { acute: 40, chronic: 620 },
      { acute: 900, chronic: 310 },
    ];
    for (const state of states) {
      for (const target of [0.7, 0.9, 1.1, 1.5]) {
        const load = loadForRatio(state, target)!;
        expect(acwrOf(stepEwmaLoad(state, load))!).toBeCloseTo(target, 12);
      }
    }
  });

  it("is negative when a rest day alone already overshoots the target", () => {
    // 2.00 today, aiming for 1.10 — even zero load only decays to 1.61.
    expect(loadForRatio({ acute: 600, chronic: 300 }, 1.1)!).toBeLessThan(0);
  });

  it("is null where no load can reach the target (λa/λc ≈ 3.63) or chronic is 0", () => {
    expect(loadForRatio({ acute: 300, chronic: 300 }, 4)).toBeNull();
    expect(loadForRatio({ acute: 300, chronic: 300 }, LAMBDA_ACUTE / LAMBDA_CHRONIC)).toBeNull();
    expect(loadForRatio({ acute: 300, chronic: 0 }, 1)).toBeNull();
  });
});

describe("keepInBand", () => {
  it("prices the band floor as a session on the day the curve would drop out", () => {
    const p = projectAcwr({ acute: 300, chronic: 300 }, CAPACITY_BAND)!;
    const s = p.keepInBand!;
    expect(s.dayOffset).toBe(p.fallsBelow!.dayOffset);
    expect(s.date).toBe(p.fallsBelow!.date);
    expect(s.rpe).toBe(SUGGESTION_RPE);
    // The AU it quotes really does land on the floor, from the state on the
    // day BEFORE the session (i.e. resting until then).
    expect(acwrOf(stepEwmaLoad({ acute: 300, chronic: 300 }, s.load))!).toBeCloseTo(
      CAPACITY_BAND.low,
      12,
    );
    // …and the minutes it renders are that load at the quoted RPE, rounded
    // to a loggable 5-minute block.
    expect(s.durationMin % 5).toBe(0);
    expect(Math.abs(s.durationMin * s.rpe - s.load)).toBeLessThanOrEqual((5 * s.rpe) / 2);
  });

  it("prices a later day off the rested-until-then state, not today's", () => {
    const state = { acute: 600, chronic: 300 }; // 2.00 — falls below on day 4
    const p = projectAcwr(state, CAPACITY_BAND)!;
    const s = p.keepInBand!;
    expect(s.dayOffset).toBe(4);
    let rested = state;
    for (let i = 0; i < 3; i++) rested = stepEwmaLoad(rested, 0);
    expect(acwrOf(stepEwmaLoad(rested, s.load))!).toBeCloseTo(CAPACITY_BAND.low, 12);
  });

  it("is null when the curve never leaves the band", () => {
    expect(projectAcwr({ acute: 300, chronic: 300 }, { low: 0.1, high: 1.5 })!.keepInBand).toBeNull();
  });
});
