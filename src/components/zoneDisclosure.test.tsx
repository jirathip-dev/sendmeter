import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import ZoneBreakdownPanel from "./ZoneBreakdownPanel";
import ZoneFocusCard from "./ZoneFocusCard";
import { zoneTrainingSets } from "../lib/zoneHistory";
import { holdOrigin } from "../lib/zoneBreakdown";
import type { TindeqRecordingMeta } from "../types";

/// #214 — the disclosure this change is FOR: the card has to name its scope,
/// and the breakdown has to show the division rather than assert the result.
/// Static markup is the same trick `acwrProjectionCard.test.tsx` uses; hover
/// and page transitions can't be judged here.

function rec(
  recordedAt: string,
  durationS: number,
  over: Partial<TindeqRecordingMeta> = {},
): TindeqRecordingMeta {
  return {
    id: `r-${recordedAt}-${durationS}`,
    recordedAt,
    durationMs: durationS * 1000,
    peakKg: 40,
    avgKg: 35,
    sampleCount: 100,
    note: "",
    tag: "FDP",
    side: "left",
    groupId: null,
    protocolRunId: null,
    setNo: null,
    // Default: a pre-#259 recording, with no zone stored — the shape every
    // existing row has, so these tests keep asserting the inferred path
    // unless a case opts into a recorded zone.
    zone: null,
    ...over,
  };
}

// Text-only view of the markup, with entities decoded so "÷" and "·" match.
function text(html: string): string {
  return html
    .replace(/<[^>]*>/g, " ")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ");
}

describe("ZoneBreakdownPanel (#214)", () => {
  const holds = [
    rec("2026-07-20T10:00:00Z", 10),
    rec("2026-07-20T10:05:00Z", 12),
    rec("2026-07-20T10:10:00Z", 12),
    rec("2026-07-20T10:15:00Z", 0.4), // blip — counts toward nothing
  ];

  it("shows the arithmetic, not just the answer", () => {
    const t = text(renderToStaticMarkup(<ZoneBreakdownPanel recs={holds} />));
    // 34s of strength holds ÷ (10s × 5 reps) = 0.7 sets.
    expect(t).toContain("34.0s of holds ÷ 50s per set (10s × 5 reps) = 0.7");
  });

  it("says how many holds fed each zone, and admits the ones that fed none", () => {
    const t = text(renderToStaticMarkup(<ZoneBreakdownPanel recs={holds} />));
    expect(t).toContain("3 holds");
    expect(t).toContain("1 hold under 1s counted toward nothing");
    expect(t).toContain("No holds in this band"); // the three empty zones
  });

  it("prints the classification bands with the code's own fuzziness caveat", () => {
    const t = text(renderToStaticMarkup(<ZoneBreakdownPanel recs={holds} />));
    expect(t).toContain("1–6s");
    expect(t).toContain("6–8.5s");
    expect(t).toContain("8.5–20s");
    expect(t).toContain("over 20s");
    expect(t).toContain("anchor hold 5s");
    expect(t).toContain("inherently fuzzy");
    // #259 split the caveat in two: recorded holds use the zone they were
    // performed under, everything else is still inferred from hold length.
    expect(t).toContain("stores the zone it was performed under");
    expect(t).toContain("has its zone inferred from how long the hold lasted");
  });

  // #259 — the distinction the column exists to make, on screen.
  describe("recorded vs inferred (#259)", () => {
    const mixed = [
      rec("2026-07-20T10:00:00Z", 10, { zone: "strength" }),
      rec("2026-07-20T10:05:00Z", 12, { zone: "strength" }),
      rec("2026-07-20T10:10:00Z", 12), // pre-#259 row — inferred
    ];

    it("says how many of a zone's holds were recorded and how many were guessed", () => {
      const t = text(renderToStaticMarkup(<ZoneBreakdownPanel recs={mixed} />));
      expect(t).toContain("2 recorded as Strength · 1 inferred from hold length");
    });

    it("says nothing about sources when every hold is a pre-#259 row", () => {
      const t = text(
        renderToStaticMarkup(
          <ZoneBreakdownPanel recs={[rec("2026-07-20T10:00:00Z", 10)]} />,
        ),
      );
      expect(t).not.toContain("recorded as");
      expect(t).not.toContain("inferred from hold length");
    });

    it("labels each hold in the expanded list with its own source", () => {
      // The list is behind a disclosure button, so render the holds directly
      // through the same helper the row uses.
      expect(holdOrigin(mixed[0]!).short).toBe("recorded");
      expect(holdOrigin(mixed[2]!).short).toBe("8.5–20s");
      expect(holdOrigin(mixed[2]!).long).toBe("inferred from a 12s hold");
    });

    it("keeps a recorded hold in the zone it was recorded under, not its duration band", () => {
      // A 12s hold recorded as Power: the panel must show it under Power,
      // with power's own divisor — the whole point of storing it.
      const t = text(
        renderToStaticMarkup(
          <ZoneBreakdownPanel
            recs={[rec("2026-07-20T10:00:00Z", 12, { zone: "power" })]}
          />,
        ),
      );
      expect(t).toContain("12.0s of holds ÷ 30s per set (5s × 6 reps) = 0.4");
      expect(t).toContain("1 recorded as Power");
    });
  });
});

describe("ZoneFocusCard title (#214)", () => {
  const now = new Date();
  const iso = (daysBack: number) =>
    new Date(now.getTime() - daysBack * 86_400_000).toISOString();
  const recordings = [
    rec(iso(1), 5),
    rec(iso(2), 5),
    rec(iso(3), 12),
    rec(iso(40), 30), // outside the 28-day window
  ];

  const html = renderToStaticMarkup(
    <ZoneFocusCard
      recordings={recordings}
      exercise="FDP"
      model={null}
      onPick={() => {}}
    />,
  );

  it("names the exercise and the window on the card itself", () => {
    const t = text(html);
    expect(t).toContain("Training balance · FDP");
    expect(t).toContain("Last 4 weeks · this exercise only · sets, not sessions");
  });

  it("offers the explainer", () => {
    expect(html).toContain("About: What Training balance counts");
  });

  it("shows the same set counts the windowed maths produces", () => {
    // Two 5s power holds ÷ (6 × 5s) = 0.3 sets; the 40-day-old hold is out.
    const sets = zoneTrainingSets(recordings, now, 28);
    expect(Math.round(sets.power * 10) / 10).toBe(0.3);
    expect(sets.endurance).toBe(0);
    const t = text(html);
    expect(t).toContain("0.3 sets");
    expect(t).toContain("0 sets");
  });
});
