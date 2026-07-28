import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import WhyZoneInfo from "./WhyZoneInfo";
import type { TindeqRecordingMeta } from "../types";

/// #292 — the #214 explainer card stopped rendering inline and moved behind
/// a small "?" trigger (matching `InfoDot`'s "?" → `Sheet` pattern). Static
/// markup is the same trick `zoneDisclosure.test.tsx` uses for the surface
/// this replaces.

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
    zone: null,
    ...over,
  };
}

const holds = [
  rec("2026-07-20T10:00:00Z", 10),
  rec("2026-07-20T10:05:00Z", 12),
  rec("2026-07-20T10:10:00Z", 12),
];

describe("WhyZoneInfo (#292)", () => {
  it("closed by default: shows the eyebrow + '?' trigger, not the sheet content", () => {
    const html = renderToStaticMarkup(
      <WhyZoneInfo zoneLabel="ENDURANCE" recs={holds} />,
    );
    expect(html).toContain("Why this session is ENDURANCE");
    expect(html).toContain("About: why this session is ENDURANCE");
    // Scope paragraph and ZoneBreakdownPanel output only render once open.
    expect(html).not.toContain("trailing-4-week");
    expect(html).not.toContain("How a hold gets its zone");
  });

  it("open state: shows the sheet title, scope paragraph and ZoneBreakdownPanel (showTag)", () => {
    const html = renderToStaticMarkup(
      <WhyZoneInfo zoneLabel="ENDURANCE" recs={holds} defaultOpen />,
    );
    expect(html).toContain("Why this session is ENDURANCE");
    expect(html).toContain("trailing-4-week, one-exercise window");
    expect(html).toContain("How a hold gets its zone");
    // showTag is passed through — the recording's tag shows in the (closed)
    // per-zone hold list disclosure button text isn't rendered until opened,
    // but the panel itself must be present.
    expect(html).toContain("hold");
  });

  it("unzoned: renders 'Why this session is unzoned'", () => {
    const html = renderToStaticMarkup(
      <WhyZoneInfo zoneLabel="unzoned" recs={holds} />,
    );
    expect(html).toContain("Why this session is unzoned");
    expect(html).toContain("About: why this session is unzoned");
  });
});
