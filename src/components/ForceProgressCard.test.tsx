import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { TindeqRecordingMeta } from "../types";
import ForceProgressCard from "./ForceProgressCard";

function recording(overrides: Partial<TindeqRecordingMeta>): TindeqRecordingMeta {
  return {
    id: crypto.randomUUID(),
    recordedAt: "2026-08-09T00:00:00.000Z",
    durationMs: 10_000,
    peakKg: 30,
    avgKg: 25,
    sampleCount: 20,
    note: "",
    tag: "FDP",
    side: "left",
    groupId: null,
    protocolRunId: null,
    setNo: null,
    zone: "strength",
    source: "dynamometer",
    ...overrides,
  };
}

describe("Force progress previews", () => {
  it("shows Static capacity and movement execution quality together", () => {
    const html = renderToStaticMarkup(
      <ForceProgressCard
        recordings={[
          recording({ id: "static", protocolMode: "hold", peakKg: 31, avgKg: 26 }),
          recording({
            id: "movement",
            protocolMode: "reverse_action",
            peakKg: 20,
            avgKg: 15,
            setMetrics: {
              meanKg: 15,
              coefficientVariationPct: 4.2,
              inTargetPct: null,
              timeUnderTensionMs: 40_000,
              driftPct: -3,
              cadenceAdherencePct: 100,
            },
          }),
        ]}
        selectedTag="FDP"
        selectedSide="left"
        model={null}
        periods={[]}
        computing={false}
        error={null}
      />,
    );
    expect(html).toContain("Static capacity · FDP");
    expect(html).toContain("Resisted movement · FDP");
    expect(html).toContain("31.0");
    expect(html).toContain("100.0%");
    expect(html).toContain("4.2%");
  });

  it("keeps both empty states honest", () => {
    const html = renderToStaticMarkup(
      <ForceProgressCard
        recordings={[]}
        selectedTag="FDP"
        selectedSide="left"
        model={null}
        periods={[]}
        computing={false}
        error={null}
      />,
    );
    expect(html).toContain("Complete a measured Static hold");
    expect(html).toContain("Complete a measured movement set");
  });
});
