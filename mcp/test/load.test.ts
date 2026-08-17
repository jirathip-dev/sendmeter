/// The MCP server's training-load math must mirror the web app's exactly —
/// the ACWR shown to the agent has to be the ACWR the user sees. The web's
/// implementation (src/lib/metrics.ts + dates.ts, both pure) is imported
/// here as an oracle: the same inputs must produce the same outputs. Plus
/// hand-computed vectors for the recurrence itself, so the oracle can't
/// simply reproduce a shared bug.

import { describe, expect, it } from "vitest";
import {
  ewma,
  ewmaLoadState,
  computeAcwr,
  computeWeeklyLoads,
  ACUTE_SPAN_DAYS,
  CHRONIC_SPAN_DAYS,
  type LoadSession,
} from "../src/load.js";
import { today } from "../src/dates.js";
import * as webMetrics from "../../src/lib/metrics.js";
import type { Session } from "../../src/types.js";

function asWebSessions(sessions: LoadSession[]): Session[] {
  return sessions as unknown as Session[];
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Deterministic pseudo-random session sets over the last 90 days.
function randomSessions(rng: () => number, count: number): LoadSession[] {
  const out: LoadSession[] = [];
  for (let i = 0; i < count; i++) {
    const daysBack = Math.floor(rng() * 90);
    const load = Math.round((rng() * 800 + 50) * 10) / 10;
    out.push({ date: webDatesDaysAgo(daysBack), load });
  }
  return out;
}

// Local date arithmetic equivalent to the web's daysAgo (needed because the
// oracle's own daysAgo is what we're cross-checking against — build dates
// independently).
function webDatesDaysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${day}`;
}

describe("ewma", () => {
  it("matches the hand-computed recurrence", () => {
    // span 7 → lambda = 2/8 = 0.25; seeds at first non-null
    expect(ewma([1, 2, 3], 7)).toEqual([1, 1.25, 1.6875]);
    // span 2 → lambda = 2/3
    const out = ewma([null, null, 5, 6], 2);
    expect(out[0]).toBeNull();
    expect(out[1]).toBeNull();
    expect(out[2]).toBe(5);
    expect(out[3]).toBeCloseTo(6 * (2 / 3) + 5 * (1 / 3), 10);
  });

  it("carries interior nulls forward unchanged", () => {
    expect(ewma([10, null, 20], 3)).toEqual([10, 10, 20 * 0.5 + 10 * 0.5]);
  });

  it("matches the web's ewma on random series", () => {
    const rng = mulberry32(42);
    for (let trial = 0; trial < 50; trial++) {
      const values = Array.from(
        { length: 90 },
        () => (rng() < 0.2 ? null : Math.round(rng() * 500) / 10),
      );
      expect(ewma(values, ACUTE_SPAN_DAYS)).toEqual(
        webMetrics.ewma(values, ACUTE_SPAN_DAYS),
      );
      expect(ewma(values, CHRONIC_SPAN_DAYS)).toEqual(
        webMetrics.ewma(values, CHRONIC_SPAN_DAYS),
      );
    }
  });
});

describe("ewmaLoadState", () => {
  it("is null when there is no load at all", () => {
    expect(ewmaLoadState([], today())).toBeNull();
    expect(ewmaLoadState([{ date: today(), load: 0 }], today())).toBeNull();
  });

  it("matches the web's ewmaLoadState on random session sets", () => {
    const rng = mulberry32(7);
    for (let trial = 0; trial < 30; trial++) {
      const sessions = randomSessions(rng, Math.floor(rng() * 40));
      const mine = ewmaLoadState(sessions, today());
      const web = webMetrics.ewmaLoadState(asWebSessions(sessions));
      expect(mine).toEqual(web);
    }
  });
});

describe("computeAcwr", () => {
  it("computes rolling acute/chronic sums like the web", () => {
    const rng = mulberry32(99);
    const sessions = randomSessions(rng, 30);
    const mine = computeAcwr(sessions, today());
    const web = webMetrics.computeAcwr(asWebSessions(sessions));
    expect(mine.acute).toEqual(web.acute);
    expect(mine.chronic).toEqual(web.chronic);
    expect(mine.acwr).toEqual(web.acwr);
  });

  it("produces an acute spike when recent load is much higher than chronic", () => {
    const sessions: LoadSession[] = [
      { date: today(), load: 800 },
      { date: today(), load: 800 },
      { date: today(), load: 800 },
    ];
    const result = computeAcwr(sessions, today());
    expect(result.acute).toBe(2400);
    expect(result.acwr).toBeGreaterThan(2);
  });
});

describe("ACWR window independence (#644 review F3)", () => {
  /// The dead-constant-700 regression: a synthetic store with the SAME
  /// constant 700 load on every day of the last 200 days. The true ACWR is
  /// exactly 1.00 (what the web app shows), and it must read ~1.00 no matter
  /// what `days` the caller passes. Before the fix, `days < 90` zero-filled
  /// days 90..days inside the EWMA and reported 1.13@30, 1.55@14 ("Danger"),
  /// 2.2@7 — a fabricated injury warning.
  function constantLoadStore(): LoadSession[] {
    const rows: { date: string; load: number }[] = [];
    for (let i = 0; i < 200; i++) rows.push({ date: webDatesDaysAgo(i), load: 700 });
    return rows;
  }

  function sessionsInWindow(
    rows: { date: string; load: number }[],
    from: string,
    to: string,
  ) {
    return rows.filter((r) => r.date >= from && r.date <= to);
  }

  /// A minimal DataStore built from the constant-load rows: sessions are
  /// window-filtered, health/phase are empty but still window-filtered so no
  /// parameter goes unused.
  function constantStore(rows: { date: string; load: number }[]) {
    return {
      async sessions(from: string, to: string) {
        return sessionsInWindow(rows, from, to);
      },
      async healthMetrics(from: string, to: string) {
        return rows
          .filter((r) => r.date >= from && r.date <= to)
          .map((r) => ({ date: r.date, readiness: 70, zone: "maintain" }));
      },
      async phasePeriods() {
        return [];
      },
    };
  }

  it("get_acwr reports ~1.00 for every allowed days value", async () => {
    // Drive the queries.ts layer (which decides how much history to fetch),
    // not computeAcwr directly — the bug lived in the fetch window.
    const { getAcwr } = await import("../src/queries.js");
    const store = constantStore(constantLoadStore());
    for (const days of [28, 45, 60, 90]) {
      const out = await getAcwr({ days }, store as never);
      expect(out.acwr, `days=${days}`).not.toBeNull();
      expect(out.acwr!, `days=${days}`).toBeCloseTo(1.0, 1);
      expect(out.status).toBe("Optimal");
    }
  });

  it("analyze_training_load reports ~1.00 for every allowed days value", async () => {
    const { analyzeTrainingLoad } = await import("../src/queries.js");
    const store = constantStore(constantLoadStore());
    for (const days of [7, 14, 30, 90]) {
      const out = await analyzeTrainingLoad(
        { weeks: 4, days },
        store as never,
      );
      expect(out.acwr.acwr, `days=${days}`).not.toBeNull();
      expect(out.acwr.acwr!, `days=${days}`).toBeCloseTo(1.0, 1);
      expect(out.acwr.status, `days=${days}`).toBe("Optimal");
      expect(out.notes, `days=${days}`).not.toContain("ACWR is in the danger zone");
    }
  });
});

describe("computeWeeklyLoads", () => {
  it("matches the web's 4-week buckets exactly (order and windows)", () => {
    const rng = mulberry32(1234);
    const sessions = randomSessions(rng, 25);
    const mine = computeWeeklyLoads(sessions, today(), 4);
    const web = webMetrics.computeWeeklyLoads(asWebSessions(sessions));
    expect(mine.map((w) => w.total)).toEqual(web.map((w) => w.total));
    // Oldest-first, same window arithmetic as the web: oldest bucket starts
    // daysAgo(27), the "Now" bucket (index 3) ends today.
    expect(mine[0]!.start).toBe(webDatesDaysAgo(27));
    expect(mine[3]!.end).toBe(today());
  });

  it("buckets by the web's window convention (start = daysAgo(wb*7+6))", () => {
    const sessions: LoadSession[] = [
      { date: webDatesDaysAgo(6), load: 100 },
      { date: webDatesDaysAgo(7), load: 200 },
      { date: webDatesDaysAgo(13), load: 300 },
      { date: webDatesDaysAgo(14), load: 400 },
    ];
    const weeks = computeWeeklyLoads(sessions, today(), 2);
    // oldest first: index 0 = "1w" bucket (daysAgo(13)..daysAgo(7))
    expect(weeks[0]!.total).toBe(500);
    // index 1 = "Now" bucket (daysAgo(6)..today)
    expect(weeks[1]!.total).toBe(100);
  });
});
