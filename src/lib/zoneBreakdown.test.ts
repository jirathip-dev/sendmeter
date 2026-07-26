import { describe, expect, it } from "vitest";
import {
  bandFor,
  MIN_HOLD_S,
  ZONE_BANDS,
  zoneBreakdown,
  zoneBreakdownInWindow,
} from "./zoneBreakdown";
import { classifyZone, zoneSets, zoneTrainingSets } from "./zoneHistory";
import { ZONE_PROTOCOLS, QUALITIES } from "./force-curve";

function hold(recordedAt: string, durationS: number, id = recordedAt) {
  return { id, recordedAt, durationMs: durationS * 1000 };
}

describe("zoneBreakdown (#214)", () => {
  it("shows the division that produces each zone's set count", () => {
    // Strength band (8.5–20s): 10s × 5 reps = 50s per set.
    const recs = [
      hold("2026-07-20T10:00:00Z", 10),
      hold("2026-07-21T10:00:00Z", 12),
      hold("2026-07-22T10:00:00Z", 12),
    ];
    const { zones } = zoneBreakdown(recs);
    const s = zones.strength;
    expect(s.holds.map((h) => h.durationS)).toEqual([10, 12, 12]);
    expect(s.totalHoldS).toBe(34);
    expect(s.setDurationS).toBe(
      ZONE_PROTOCOLS.strength.holdS * ZONE_PROTOCOLS.strength.reps,
    );
    expect(s.setDurationS).toBe(50);
    expect(s.sets).toBeCloseTo(34 / 50, 10);
    // Every other zone is empty, and says so with a real zero, not a gap.
    expect(zones.power.holds).toEqual([]);
    expect(zones.power.totalHoldS).toBe(0);
    expect(zones.power.sets).toBe(0);
  });

  it("agrees with zoneSets bit-for-bit — it only keeps the intermediates", () => {
    const recs = [
      hold("2026-07-01T10:00:00Z", 4.4),
      hold("2026-07-02T10:00:00Z", 5.7),
      hold("2026-07-03T10:00:00Z", 7.3),
      hold("2026-07-04T10:00:00Z", 8.2),
      hold("2026-07-05T10:00:00Z", 9.9),
      hold("2026-07-06T10:00:00Z", 13.6),
      hold("2026-07-07T10:00:00Z", 31.4),
      hold("2026-07-08T10:00:00Z", 47.1),
      hold("2026-07-09T10:00:00Z", 0.4), // blip
    ];
    const { zones } = zoneBreakdown(recs);
    const sets = zoneSets(recs);
    for (const q of QUALITIES) {
      expect(zones[q.id].sets).toBe(sets[q.id]);
    }
  });

  it("keeps sub-1s blips visible instead of dropping them silently", () => {
    const blip = hold("2026-07-09T10:00:00Z", 0.4);
    const { zones, unclassified } = zoneBreakdown([
      hold("2026-07-08T10:00:00Z", 5),
      blip,
    ]);
    expect(unclassified.map((h) => h.rec)).toEqual([blip]);
    expect(unclassified[0]!.durationS).toBeCloseTo(0.4, 10);
    // …and they contribute to nothing.
    const total = QUALITIES.reduce((n, q) => n + zones[q.id].totalHoldS, 0);
    expect(total).toBe(5);
    expect(MIN_HOLD_S).toBe(1);
  });

  it("carries the original recording through so a figure traces to a hold", () => {
    const rec = { id: "abc", recordedAt: "2026-07-20T10:00:00Z", durationMs: 12_000, side: "left" };
    const { zones } = zoneBreakdown([rec]);
    expect(zones.strength.holds[0]!.rec).toBe(rec);
    expect(zones.strength.holds[0]!.rec.side).toBe("left");
  });

  it("preserves input order within a zone", () => {
    const { zones } = zoneBreakdown([
      hold("2026-07-22T10:00:00Z", 12, "c"),
      hold("2026-07-20T10:00:00Z", 10, "a"),
      hold("2026-07-21T10:00:00Z", 11, "b"),
    ]);
    expect(zones.strength.holds.map((h) => h.rec.id)).toEqual(["c", "a", "b"]);
  });
});

describe("zoneBreakdownInWindow (#214)", () => {
  const now = new Date("2026-07-26T12:00:00Z");
  const recs = [
    hold("2026-07-25T10:00:00Z", 10), // in window
    hold("2026-07-01T10:00:00Z", 12), // in window (25 days back)
    hold("2026-06-01T10:00:00Z", 30), // outside 28 days
    { id: "bad", recordedAt: "not-a-date", durationMs: 9_000 },
  ];

  it("matches zoneTrainingSets' window filter exactly", () => {
    const { zones } = zoneBreakdownInWindow(recs, now, 28);
    const sets = zoneTrainingSets(recs, now, 28);
    for (const q of QUALITIES) {
      expect(zones[q.id].sets).toBe(sets[q.id]);
    }
  });

  it("excludes holds older than the window and unparseable timestamps", () => {
    const { zones } = zoneBreakdownInWindow(recs, now, 28);
    expect(zones.strength.holds.map((h) => h.durationS)).toEqual([10, 12]);
    expect(zones.endurance.holds).toEqual([]);
  });
});

describe("band explanation (#214)", () => {
  it("labels the band a hold fell in", () => {
    expect(bandFor(5)).toEqual({ zone: "power", band: "1–6s" });
    expect(bandFor(7)).toEqual({ zone: "power-endurance", band: "6–8.5s" });
    expect(bandFor(12)).toEqual({ zone: "strength", band: "8.5–20s" });
    expect(bandFor(45)).toEqual({ zone: "endurance", band: "over 20s" });
    expect(bandFor(0.5)).toBeNull();
  });

  // The labels are prose, so they could quietly stop describing the rule they
  // claim to. Pin each label to a numeric range and sweep every 0.1s across
  // all four boundaries: the band a hold is SHOWN is the band it was actually
  // classified into.
  it("never drifts from classifyZone — swept across every band boundary", () => {
    const RANGES: { band: string; loS: number; hiS: number }[] = [
      { band: "1–6s", loS: 1, hiS: 6 },
      { band: "6–8.5s", loS: 6, hiS: 8.5 },
      { band: "8.5–20s", loS: 8.5, hiS: 20 },
      { band: "over 20s", loS: 20, hiS: Infinity },
    ];
    for (let step = 0; step <= 600; step++) {
      const durationS = Math.round(step) / 10;
      const shown = bandFor(durationS);
      if (durationS < 1) {
        expect(shown).toBeNull();
        expect(classifyZone(durationS)).toBeNull();
        continue;
      }
      // Bands are upper-inclusive, matching classifyZone's `<=` boundaries.
      const expected = RANGES.find(
        (r) => durationS > r.loS - (r.loS === 1 ? 1 : 0) && durationS <= r.hiS,
      )!;
      expect(shown).not.toBeNull();
      expect(shown!.band).toBe(expected.band);
      expect(shown!.zone).toBe(classifyZone(durationS));
    }
  });

  it("quotes each zone's own anchor hold from ZONE_PROTOCOLS", () => {
    for (const b of ZONE_BANDS) {
      expect(b.anchorS).toBe(ZONE_PROTOCOLS[b.zone].holdS);
    }
    expect(ZONE_BANDS.map((b) => b.zone)).toEqual([
      "power",
      "strength",
      "power-endurance",
      "endurance",
    ]);
  });
});
