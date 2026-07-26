import { describe, it, expect } from "vitest";
import {
  hrRecoveryBpm,
  recentDailyRpe,
  workRestRatio,
} from "./workoutStats";
import type { WorkoutAttempt, WorkoutHrSample } from "../types";

const att = (
  startedAt: string,
  durationS: number,
  effortScore: number | null = null,
): WorkoutAttempt => ({
  startedAt,
  durationS,
  elevationGainM: 0,
  avgHr: null,
  peakHr: null,
  effortScore,
  source: "manual",
});

describe("workRestRatio (SL-99)", () => {
  it("is total climb time over total rest time", () => {
    // climbs 30 + 60 + 30 = 120s; rests 120 + 180 = 300s → 0.4
    const r = workRestRatio([
      att("2026-07-20T10:00:00Z", 30), // ends 10:00:30
      att("2026-07-20T10:02:30Z", 60), // gap 120s, ends 10:03:30
      att("2026-07-20T10:06:30Z", 30), // gap 180s
    ]);
    expect(r).toBeCloseTo(120 / 300, 5);
  });
  it("skips overlapping (non-positive) gaps and needs measurable rest", () => {
    // Two back-to-back attempts with no gap → no rest → null
    expect(
      workRestRatio([att("2026-07-20T10:00:00Z", 30), att("2026-07-20T10:00:30Z", 30)]),
    ).toBeNull();
  });
  it("needs at least two attempts", () => {
    expect(workRestRatio([att("t", 30)])).toBeNull();
    expect(workRestRatio([])).toBeNull();
  });
});

describe("hrRecoveryBpm (SL-85)", () => {
  it("averages HR-at-end minus the low within the window", () => {
    // Attempt ends at t=30 with HR 160; HR falls to 120 by t=80.
    const trace: WorkoutHrSample[] = [];
    for (let t = 0; t <= 120; t += 5) {
      const hr = t <= 30 ? 160 : Math.max(120, 160 - (t - 30));
      trace.push({ t, hr });
    }
    const drop = hrRecoveryBpm(trace, "2026-07-20T10:00:00Z", [
      att("2026-07-20T10:00:00Z", 30),
    ]);
    expect(drop).toBeCloseTo(40, 0); // 160 → 120
  });

  it("returns null with no usable HR", () => {
    expect(
      hrRecoveryBpm([], "2026-07-20T10:00:00Z", [att("2026-07-20T10:00:00Z", 30)]),
    ).toBeNull();
  });
});

/// A session as `recentDailyRpe` sees it. `typeLabel` defaults to the gym
/// session label so the older cases stay about RPE, not naming.
const sess = (
  date: string,
  rpe: number,
  rpeConfirmed = true,
  typeLabel = "Gym Session",
) => ({ date, rpe, rpeConfirmed, typeLabel });

describe("recentDailyRpe (#108)", () => {
  it("keeps decimal RPE — no rounding", () => {
    expect(recentDailyRpe([sess("2026-07-21", 5.5)], 8)).toEqual([
      { date: "2026-07-21", rpe: 5.5, confirmed: true, typeLabels: ["Gym Session"] },
    ]);
  });

  it("includes a manually-logged session with no attempts/workout row", () => {
    // A "Log a past workout" entry is just a `sessions` row — this reads it
    // straight off the session list, unlike the attempt-based stats above.
    const rows = recentDailyRpe(
      [
        sess("2026-07-19", 6),
        sess("2026-07-21", 7.5), // logged on the 21st
        sess("2026-07-23", 4),
      ],
      8,
    );
    expect(rows.map((r) => r.date)).toEqual([
      "2026-07-19",
      "2026-07-21",
      "2026-07-23",
    ]);
    expect(rows.find((r) => r.date === "2026-07-21")?.rpe).toBe(7.5);
  });

  it("averages same-day sessions", () => {
    const rows = recentDailyRpe(
      [sess("2026-07-21", 5), sess("2026-07-21", 8)],
      8,
    );
    expect(rows).toEqual([
      { date: "2026-07-21", rpe: 6.5, confirmed: true, typeLabels: ["Gym Session"] },
    ]);
  });

  it("keeps only the most recent `days` distinct dates, oldest → newest", () => {
    const sessions = ["07-17", "07-18", "07-19", "07-20", "07-21"].map((md) =>
      sess(`2026-${md}`, 5),
    );
    const rows = recentDailyRpe(sessions, 3);
    expect(rows.map((r) => r.date)).toEqual([
      "2026-07-19",
      "2026-07-20",
      "2026-07-21",
    ]);
  });

  it("is order-independent — sorts by date, not input order", () => {
    const rows = recentDailyRpe(
      [sess("2026-07-21", 7), sess("2026-07-19", 5), sess("2026-07-20", 6)],
      8,
    );
    expect(rows.map((r) => r.date)).toEqual([
      "2026-07-19",
      "2026-07-20",
      "2026-07-21",
    ]);
  });

  it("returns [] for no sessions", () => {
    expect(recentDailyRpe([], 8)).toEqual([]);
  });

  it("marks a day unconfirmed for an unreviewed phone auto-save (#114)", () => {
    const rows = recentDailyRpe([sess("2026-07-21", 6, false)], 8);
    expect(rows).toEqual([
      { date: "2026-07-21", rpe: 6, confirmed: false, typeLabels: ["Gym Session"] },
    ]);
  });

  it("mixed day: any unconfirmed session mutes the whole day's average (#114)", () => {
    const rows = recentDailyRpe(
      [
        sess("2026-07-21", 6, false), // unreviewed phone auto-save
        sess("2026-07-21", 8, true), // user-logged, same day
      ],
      8,
    );
    expect(rows).toEqual([
      { date: "2026-07-21", rpe: 7, confirmed: false, typeLabels: ["Gym Session"] },
    ]);
  });

  describe("type labels (#181)", () => {
    it("returns the day's own session label", () => {
      const rows = recentDailyRpe(
        [sess("2026-07-21", 6, true, "Fingerboard")],
        8,
      );
      expect(rows[0]!.typeLabels).toEqual(["Fingerboard"]);
    });

    it("lists a multi-session day's distinct labels in session order", () => {
      const rows = recentDailyRpe(
        [
          sess("2026-07-21", 6, true, "Gym Session"),
          sess("2026-07-21", 8, true, "Fingerboard"),
        ],
        8,
      );
      expect(rows[0]!.typeLabels).toEqual(["Gym Session", "Fingerboard"]);
    });

    it("dedupes repeated labels on the same day", () => {
      const rows = recentDailyRpe(
        [
          sess("2026-07-21", 6, true, "Gym Session"),
          sess("2026-07-21", 8, true, "Fingerboard"),
          sess("2026-07-21", 7, true, "Gym Session"),
        ],
        8,
      );
      expect(rows[0]!.typeLabels).toEqual(["Gym Session", "Fingerboard"]);
    });

    it("keeps each day's labels to its own sessions", () => {
      const rows = recentDailyRpe(
        [
          sess("2026-07-20", 6, true, "Fingerboard"),
          sess("2026-07-21", 8, true, "Gym Session"),
        ],
        8,
      );
      expect(rows.map((r) => r.typeLabels)).toEqual([
        ["Fingerboard"],
        ["Gym Session"],
      ]);
    });

    it("skips a blank label rather than listing an empty one", () => {
      const rows = recentDailyRpe(
        [sess("2026-07-21", 6, true, "  "), sess("2026-07-21", 8, true, "Gym Session")],
        8,
      );
      expect(rows[0]!.typeLabels).toEqual(["Gym Session"]);
      expect(rows[0]!.rpe).toBe(7); // still averaged in
    });

    it("Tindeq sessions still count — labelling only, no filtering (#181)", () => {
      // The scope decision: `computeAcwr` filters by date, never by type, so a
      // Force session's load already reaches the ACWR ratio, the weekly bars
      // and the load heatmap. This trend must agree with them.
      const rows = recentDailyRpe(
        [
          sess("2026-07-20", 4, true, "Fingerboard"), // Tindeq-only day
          sess("2026-07-21", 6, true, "Gym Session"),
          sess("2026-07-21", 8, true, "Fingerboard"), // mixed day
        ],
        8,
      );
      expect(rows).toEqual([
        {
          date: "2026-07-20",
          rpe: 4,
          confirmed: true,
          typeLabels: ["Fingerboard"],
        },
        {
          date: "2026-07-21",
          rpe: 7, // averaged over BOTH sessions
          confirmed: true,
          typeLabels: ["Gym Session", "Fingerboard"],
        },
      ]);
    });
  });
});
