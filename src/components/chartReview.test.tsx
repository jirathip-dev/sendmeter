// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import ForceCurveCard from "./ForceCurveCard";
import ForceGauge from "./ForceGauge";
import ContributionHeatmap from "./ContributionHeatmap";
import ForceTrendChart from "./ForceTrendChart";
import TrainingLoadSheet from "./TrainingLoadSheet";
import WorkoutEffortChart from "./WorkoutEffortChart";
import WorkoutHrChart from "./WorkoutHrChart";
import RecoveryStatsCard from "./RecoveryStatsCard";
import { useChartHover } from "../hooks/useChartHover";
import { dateStr, today } from "../lib/dates";
import { CURVE_PERIOD_STYLES } from "../lib/chartPeriodStyles";
import { WORKOUT_CHART_PAD } from "../lib/workoutChartAxis";
import type { ForceCurveModel, PeriodCurve } from "../lib/force-curve";
import type { TindeqRecordingMeta, TindeqSample, WorkoutAttempt } from "../types";
import * as repo from "../lib/repo";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const storage = new Map<string, string>();
vi.stubGlobal("localStorage", {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => void storage.set(key, value),
  removeItem: (key: string) => void storage.delete(key),
  clear: () => storage.clear(),
});

const curveModel: ForceCurveModel = {
  points: [
    { windowS: 1, kg: 40 },
    { windowS: 3, kg: 36 },
    { windowS: 10, kg: 30 },
    { windowS: 30, kg: 24 },
    { windowS: 120, kg: 21 },
  ],
  maxF: 40,
  cf: 20,
  wPrime: 120,
};

const periods: PeriodCurve[] = Object.keys(CURVE_PERIOD_STYLES).map((label, i) => ({
  label,
  days: [30, 90, 180, 365, 730, 1095][i]!,
  model: curveModel,
}));

const attempt: WorkoutAttempt = {
  startedAt: "2026-08-08T10:00:00.000Z",
  durationS: 2,
  elevationGainM: 4,
  avgHr: 145,
  peakHr: 160,
  effortScore: 7,
  source: "auto",
};

// Local constructors keep these fixtures Gregorian and independent of the
// machine's current weekday; the component's explicit `today` prop freezes
// the same local-day boundary in every render.
const HEATMAP_SUNDAY = new Date(2026, 7, 2, 12);
const HEATMAP_MIDWEEK = new Date(2026, 7, 5, 12);
const HEATMAP_SATURDAY = new Date(2026, 7, 8, 12);

function trendRecording(id: string, recordedAt: string, peakKg: number): TindeqRecordingMeta {
  return {
    id,
    recordedAt,
    durationMs: 10_000,
    peakKg,
    avgKg: peakKg * 0.9,
    sampleCount: 100,
    note: "",
    tag: "FDP",
    side: "left",
    groupId: null,
    protocolRunId: null,
    setNo: null,
    zone: null,
    source: "dynamometer",
  };
}

function mount(container: HTMLDivElement, element: React.ReactNode): Root {
  const root = createRoot(container);
  act(() => root.render(element));
  return root;
}

function parse(html: string): HTMLDivElement {
  const host = document.createElement("div");
  host.innerHTML = html;
  return host;
}

function SurfaceProbe({ axis = "x" }: { axis?: "x" | "y" }) {
  const [hovered, , , surfaceProps] = useChartHover<number>();
  return (
    <div
      data-testid="surface-probe"
      role="button"
      tabIndex={0}
      aria-label={hovered === null ? "none" : String(hovered)}
      {...surfaceProps([10, 20, 30], 3, (i) => i + 0.5, axis)}
    />
  );
}

function pointerEvent(type: string, init: { pointerType: string; clientX?: number; clientY?: number }) {
  const event = new Event(type, { bubbles: true });
  Object.defineProperty(event, "pointerType", { value: init.pointerType });
  Object.defineProperty(event, "clientX", { value: init.clientX ?? 0 });
  Object.defineProperty(event, "clientY", { value: init.clientY ?? 0 });
  Object.defineProperty(event, "pointerId", { value: 1 });
  return event;
}

describe("#516 chart review regressions", () => {
  let container: HTMLDivElement;
  let mountedRoot: Root | null = null;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    if (mountedRoot) {
      act(() => mountedRoot?.unmount());
      mountedRoot = null;
    }
    container.remove();
    document.documentElement.removeAttribute("data-theme");
    document.documentElement.removeAttribute("style");
  });

  it("renders independent SVG definition ids for simultaneously mounted curves", () => {
    const html = renderToStaticMarkup(
      <>
        <ForceCurveCard
          tag="FDP"
          model={curveModel}
          periods={periods}
          computing={false}
          error={null}
          modality="static"
        />
        <ForceCurveCard
          tag="FDP"
          model={curveModel}
          periods={periods}
          computing={false}
          error={null}
          modality="static"
        />
      </>,
    );
    const root = parse(html);
    const ids = Array.from(root.querySelectorAll("[id]"), (node) => node.id);
    expect(ids.length).toBeGreaterThan(0);
    expect(new Set(ids).size).toBe(ids.length);
    expect(root.querySelectorAll('svg[role="group"]').length).toBe(2);
    expect(root.querySelectorAll('[data-chart-hit-surface="force-curve"]')).toHaveLength(2);
    expect(root.querySelectorAll('svg[role="group"] [role="button"][tabindex="0"]')).toHaveLength(2);
    expect(root.querySelectorAll('circle[role="button"]')).toHaveLength(0);
  });

  it("keeps every active curve window distinct with semantic colour and dash cues", () => {
    mountedRoot = mount(
      container,
      <ForceCurveCard
        tag="FDP"
        model={curveModel}
        periods={periods}
        computing={false}
        error={null}
        modality="static"
      />,
    );
    for (const label of Object.keys(CURVE_PERIOD_STYLES)) {
      const button = Array.from(container.querySelectorAll("button")).find((candidate) =>
        candidate.textContent?.startsWith(label),
      );
      expect(button).toBeDefined();
      act(() => button?.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    }
    const activeChip = container.querySelector(".chart-period-chip") as HTMLButtonElement;
    expect(activeChip.style.color).toMatch(/^var\(--chart-on-/);
    expect(activeChip.style.minHeight).toBe("44px");
    const overlays = Array.from(container.querySelectorAll("polyline[stroke-dasharray]"));
    expect(overlays).toHaveLength(Object.keys(CURVE_PERIOD_STYLES).length);
    expect(new Set(overlays.map((line) => line.getAttribute("stroke-dasharray"))).size).toBe(
      overlays.length,
    );
    expect(new Set(overlays.map((line) => line.getAttribute("stroke"))).size).toBe(overlays.length);
  });

  it("keeps effort scrubbing on one transparent chart surface", () => {
    const html = renderToStaticMarkup(
      <WorkoutEffortChart
        startedAt="2026-08-08T10:00:00.000Z"
        attempts={[attempt]}
        tMax={120}
        width={300}
        showTimeAxis={false}
      />,
    );
    const root = parse(html);
    const hit = root.querySelector('rect[role="button"]');
    expect(hit).not.toBeNull();
    expect(Number(hit?.getAttribute("width"))).toBeGreaterThanOrEqual(44);
    expect(hit?.getAttribute("tabindex")).toBe("0");
    expect(hit?.getAttribute("fill")).toBe("transparent");
  });

  it("assigns a dense curve pointer to the nearest datum, independent of DOM order", async () => {
    mountedRoot = mount(
      container,
      <ForceCurveCard
        tag="FDP"
        model={curveModel}
        periods={[]}
        computing={false}
        error={null}
        modality="static"
      />,
    );
    const surface = container.querySelector('[data-chart-hit-surface="force-curve"]') as SVGRectElement;
    const svg = surface.ownerSVGElement!;
    vi.spyOn(svg, "getBoundingClientRect").mockReturnValue({
      left: 0,
      top: 0,
      width: 300,
      height: 130,
      right: 300,
      bottom: 130,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });
    const move = new Event("pointermove", { bubbles: true });
    Object.defineProperty(move, "clientX", { value: 162 });
    Object.defineProperty(move, "pointerType", { value: "mouse" });
    await act(async () => surface.dispatchEvent(move));
    expect(container.querySelector('[role="status"]')?.textContent).toContain("10s");
    expect(container.querySelectorAll('[data-chart-hit-surface="force-curve"]').length).toBe(1);
  });

  it("keeps pointer capture scrub state correct across move, up, and cancel", async () => {
    mountedRoot = mount(container, <SurfaceProbe />);
    const surface = container.querySelector('[data-testid="surface-probe"]') as HTMLDivElement;
    vi.spyOn(surface, "getBoundingClientRect").mockReturnValue({
      left: 0,
      top: 0,
      width: 300,
      height: 100,
      right: 300,
      bottom: 100,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });
    Object.defineProperty(surface, "setPointerCapture", { value: () => undefined, configurable: true });
    Object.defineProperty(surface, "releasePointerCapture", { value: () => undefined, configurable: true });
    const capture = vi.spyOn(surface, "setPointerCapture").mockImplementation(() => undefined);
    const release = vi.spyOn(surface, "releasePointerCapture").mockImplementation(() => undefined);
    await act(async () => surface.dispatchEvent(pointerEvent("pointerdown", { pointerType: "touch", clientX: 5 })));
    expect(surface.getAttribute("aria-label")).toBe("10");
    expect(capture).toHaveBeenCalledWith(1);
    await act(async () => surface.dispatchEvent(pointerEvent("pointermove", { pointerType: "touch", clientX: 295 })));
    expect(surface.getAttribute("aria-label")).toBe("30");
    await act(async () => surface.dispatchEvent(pointerEvent("pointerup", { pointerType: "touch", clientX: 295 })));
    expect(release).toHaveBeenCalledWith(1);
    await act(async () => surface.dispatchEvent(pointerEvent("pointermove", { pointerType: "touch", clientX: 5 })));
    expect(surface.getAttribute("aria-label")).toBe("30");
    await act(async () => surface.dispatchEvent(pointerEvent("pointerdown", { pointerType: "touch", clientX: 150 })));
    await act(async () => surface.dispatchEvent(pointerEvent("pointercancel", { pointerType: "touch", clientX: 150 })));
    await act(async () => surface.dispatchEvent(pointerEvent("pointermove", { pointerType: "touch", clientX: 5 })));
    expect(surface.getAttribute("aria-label")).toBe("20");
  });

  it("uses clientY and upper/lower arrow directions for vertical chart rows", async () => {
    mountedRoot = mount(container, <SurfaceProbe axis="y" />);
    const surface = container.querySelector('[data-testid="surface-probe"]') as HTMLDivElement;
    vi.spyOn(surface, "getBoundingClientRect").mockReturnValue({
      left: 0,
      top: 0,
      width: 100,
      height: 300,
      right: 100,
      bottom: 300,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });
    await act(async () => surface.dispatchEvent(pointerEvent("pointermove", { pointerType: "mouse", clientY: 295 })));
    expect(surface.getAttribute("aria-label")).toBe("30");
    await act(async () => surface.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true })));
    expect(surface.getAttribute("aria-label")).toBe("20");
    await act(async () => surface.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })));
    expect(surface.getAttribute("aria-label")).toBe("30");
  });

  it("maps a downsampled HR surface back to nonuniform source timestamps", async () => {
    const samples = Array.from({ length: 101 }, (_, i) => ({
      t: i < 50 ? i * 2 : i === 50 ? 137 : 137 + (i - 50) * 3,
      hr: 120 + (i % 20),
    }));
    mountedRoot = mount(
      container,
      <WorkoutHrChart
        startedAt="2026-08-08T10:00:00.000Z"
        attempts={[]}
        samples={samples}
        tMax={300}
        width={300}
        showTimeAxis={false}
        source="watch"
      />,
    );
    const surface = container.querySelector('[data-chart-hit-surface="workout-heart-rate"]') as SVGRectElement;
    const svg = surface.ownerSVGElement!;
    vi.spyOn(svg, "getBoundingClientRect").mockReturnValue({
      left: 0,
      top: 0,
      width: 300,
      height: 90,
      right: 300,
      bottom: 90,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });
    const clientX = WORKOUT_CHART_PAD.left + (137 / 300) * (300 - WORKOUT_CHART_PAD.left - WORKOUT_CHART_PAD.right);
    await act(async () => surface.dispatchEvent(pointerEvent("pointermove", { pointerType: "mouse", clientX })));
    expect(container.querySelector('[role="status"]')?.textContent).toContain("2:17");
  });

  it("keeps force-trend boxes visible without overlapping point targets", () => {
    const root = parse(
      renderToStaticMarkup(
        <ForceTrendChart
          recordings={[
            trendRecording("r1", "2026-08-01T10:00:00.000Z", 40),
            trendRecording("r2", "2026-08-04T10:00:00.000Z", 39),
            trendRecording("r3", "2026-08-08T10:00:00.000Z", 42),
          ]}
          selectedTag="FDP"
          selectedSide="left"
          modality="static"
        />,
      ),
    );
    const hit = root.querySelector('rect[role="button"]');
    expect(hit).not.toBeNull();
    expect(hit?.getAttribute("data-chart-hit-surface")).toBe("force-trend");
    expect(Number(hit?.getAttribute("width"))).toBeGreaterThanOrEqual(44);
    const boxes = Array.from(root.querySelectorAll('rect[fill^="url("]'));
    expect(boxes.length).toBeGreaterThanOrEqual(2);
    expect(boxes.every((box) => box.getAttribute("fill-opacity") === null)).toBe(true);
    expect(boxes.every((box) => Number(box.getAttribute("opacity")) >= 0.8)).toBe(true);
  });

  it("renders recovery row surfaces at a genuine 44 CSS-pixel target height", async () => {
    const fetchHealth = vi.spyOn(repo, "fetchHealthMetrics").mockResolvedValue([
      {
        date: today(),
        readiness: 80,
        zone: "push",
        computedAt: new Date().toISOString(),
        hrvSdnnMs: 50,
        restingHr: 55,
        sleepHours: 8,
        sleepDeepHours: 2,
        sleepRemHours: 2,
        bodyMassKg: 70,
        respRateBpm: 14,
      },
    ]);
    mountedRoot = mount(container, <RecoveryStatsCard />);
    await act(async () => await Promise.resolve());
    const surfaces = container.querySelectorAll('[data-chart-hit-surface^="recovery-"]');
    expect(surfaces.length).toBeGreaterThan(0);
    expect(Array.from(surfaces).every((node) => {
      const svg = node.closest("svg") as SVGElement | null;
      return svg?.getAttribute("preserveAspectRatio") === "none" &&
        svg?.style.height === "44px" &&
        svg?.style.minHeight === "44px";
    })).toBe(true);
    fetchHealth.mockRestore();
  });

  it("exposes heatmap days and weekly load as keyboard-operable data points", async () => {
    const values = new Map([[dateStr(HEATMAP_MIDWEEK), { total: 100, type: "board" }]]);
    const heatmap = parse(
      renderToStaticMarkup(<ContributionHeatmap values={values} weeks={1} today={HEATMAP_MIDWEEK} />),
    );
    const heatmapDescription = heatmap.querySelector('[role="group"]')?.getAttribute("aria-describedby");
    expect(heatmapDescription).toMatch(/^contribution-summary-/);
    expect(heatmapDescription && heatmap.querySelector(`#${heatmapDescription}`)).not.toBeNull();
    const grid = heatmap.querySelector('[role="grid"]');
    expect(grid?.getAttribute("tabindex")).toBe("0");
    expect(grid?.getAttribute("aria-rowcount")).toBe("7");
    expect(grid?.getAttribute("aria-colcount")).toBe("1");
    expect(heatmap.querySelectorAll('[role="gridcell"]').length).toBe(7);
    expect(heatmap.querySelectorAll("button[aria-label]").length).toBe(0);
    expect(heatmap.querySelectorAll('[role="img"]').length).toBe(0);

    mountedRoot = mount(
      container,
      <ContributionHeatmap values={values} weeks={1} today={HEATMAP_MIDWEEK} />,
    );
    const heatmapDay = container.querySelector('[role="grid"]') as HTMLDivElement;
    expect(heatmapDay).toBeTruthy();
    await act(async () => {
      heatmapDay.focus();
      heatmapDay.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    });
    expect(container.querySelector('[role="status"]')).not.toBeNull();

    act(() => mountedRoot?.unmount());
    mountedRoot = null;
    container.replaceChildren();
    mountedRoot = mount(
      container,
      <TrainingLoadSheet
        weeklyLoads={[{ label: "W1", total: 100 }, { label: "W2", total: 140 }]}
        sessions={[]}
        onClose={() => {}}
      />,
    );
    const weekly = container.querySelector('[aria-describedby^="weekly-load-summary-"]');
    const weeklyDescription = weekly?.getAttribute("aria-describedby");
    expect(weeklyDescription).toMatch(/^weekly-load-summary-/);
    expect(weeklyDescription && container.querySelector(`#${weeklyDescription}`)).not.toBeNull();
    const weekSurface = weekly as HTMLElement;
    expect(weekSurface?.getAttribute("role")).toBe("button");
    await act(async () => {
      weekSurface.focus();
      weekSurface.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    });
    expect(container.querySelector('[role="status"]')).not.toBeNull();
  });

  it("owns heatmap pointer selection at the grid and navigates visual weeks/weekday rows", async () => {
    const values = new Map([[dateStr(HEATMAP_MIDWEEK), { total: 100, type: "board" }]]);
    mountedRoot = mount(
      container,
      <ContributionHeatmap values={values} weeks={2} today={HEATMAP_MIDWEEK} />,
    );
    const grid = container.querySelector('[data-chart-hit-surface="contribution-heatmap"]') as HTMLDivElement;
    expect(grid.getAttribute("role")).toBe("grid");
    expect(grid.getAttribute("tabindex")).toBe("0");
    expect(grid.querySelectorAll('[role="row"]').length).toBe(7);
    expect(grid.querySelectorAll('[role="gridcell"]').length).toBe(14);
    expect(grid.querySelectorAll('[role="gridcell"][tabindex]').length).toBe(0);
    vi.spyOn(grid, "getBoundingClientRect").mockReturnValue({
      left: 0,
      top: 0,
      width: 200,
      height: 700,
      right: 200,
      bottom: 700,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });
    // Midweek layout: the second (current) week has Thu–Sat disabled.
    await act(async () => grid.dispatchEvent(pointerEvent("pointermove", { pointerType: "mouse", clientX: 50, clientY: 350 })));
    const selectedAfterPointer = grid.querySelector('[role="gridcell"][aria-selected="true"]');
    expect(selectedAfterPointer).not.toBeNull();
    expect(grid.getAttribute("aria-activedescendant")).toBe(selectedAfterPointer?.id);
    expect(selectedAfterPointer?.getAttribute("aria-label")).toContain("2026-07-29");
    // End chooses the same weekday's last available week; Home returns to its first.
    await act(async () => grid.dispatchEvent(new KeyboardEvent("keydown", { key: "End", bubbles: true })));
    expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')?.getAttribute("aria-label")).toContain("2026-08-05");
    await act(async () => grid.dispatchEvent(new KeyboardEvent("keydown", { key: "Home", bubbles: true })));
    expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')?.getAttribute("aria-label")).toContain("2026-07-29");
    // Down into the future row clamps at the last available cell in this week.
    await act(async () => grid.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })));
    await act(async () => grid.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })));
    expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')?.getAttribute("aria-label")).toContain("2026-08-05");

    // Saturday's current-week cell is the last available same-row datum.
    await act(async () => grid.dispatchEvent(pointerEvent("pointermove", { pointerType: "mouse", clientX: 50, clientY: 650 })));
    const selectedAtWeekEdge = grid.querySelector('[role="gridcell"][aria-selected="true"]');
    const edgeKey = selectedAtWeekEdge?.getAttribute("aria-label");
    await act(async () => grid.dispatchEvent(new KeyboardEvent("keydown", { key: "End", bubbles: true })));
    expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')?.getAttribute("aria-label")).toBe(edgeKey);
    await act(async () => grid.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })));
    expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')?.getAttribute("aria-label")).toBe(edgeKey);

    // The future cell owns this geometry but clears selection/status rather
    // than falling back to the previous week's Saturday.
    await act(async () => grid.dispatchEvent(pointerEvent("pointermove", { pointerType: "mouse", clientX: 150, clientY: 650 })));
    expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')).toBeNull();
    expect(grid.getAttribute("aria-activedescendant")).toBeNull();
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(Array.from(grid.querySelectorAll('[role="gridcell"]')).some((cell) =>
      cell.getAttribute("aria-label") === "2026-08-08: unavailable (future)",
    )).toBe(true);
    await act(async () => grid.dispatchEvent(pointerEvent("pointerdown", { pointerType: "touch", clientX: 150, clientY: 650 })));
    await act(async () => grid.dispatchEvent(pointerEvent("pointermove", { pointerType: "touch", clientX: 150, clientY: 650 })));
    await act(async () => grid.dispatchEvent(pointerEvent("pointerup", { pointerType: "touch", clientX: 150, clientY: 650 })));
    expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')).toBeNull();
  });

  it("freezes one-week Sunday, midweek, and Saturday layouts independent of the clock", () => {
    for (const [date, futureCount] of [
      [HEATMAP_SUNDAY, 6],
      [HEATMAP_MIDWEEK, 3],
      [HEATMAP_SATURDAY, 0],
    ] as const) {
      const values = new Map([[dateStr(date), { total: 100, type: "board" }]]);
      const root = parse(
        renderToStaticMarkup(<ContributionHeatmap values={values} weeks={1} today={date} />),
      );
      const grid = root.querySelector('[role="grid"]');
      expect(grid?.getAttribute("aria-colcount")).toBe("1");
      expect(grid?.querySelectorAll('[role="gridcell"][aria-disabled="true"]').length).toBe(futureCount);
      expect(grid?.querySelector(`[aria-label^="${dateStr(date)}:"]`)).not.toBeNull();
    }
  });

  it("moves one visual week for Sunday, midweek, and Saturday regardless of today", async () => {
    const cases = [
      { date: HEATMAP_SUNDAY, weekday: 0, previous: "2026-07-26", current: "2026-08-02" },
      { date: HEATMAP_MIDWEEK, weekday: 3, previous: "2026-07-29", current: "2026-08-05" },
      { date: HEATMAP_SATURDAY, weekday: 6, previous: "2026-08-01", current: "2026-08-08" },
    ] as const;

    for (const { date, weekday, previous, current } of cases) {
      mountedRoot = mount(
        container,
        <ContributionHeatmap values={new Map()} weeks={2} today={date} />,
      );
      const grid = container.querySelector('[data-chart-hit-surface="contribution-heatmap"]') as HTMLDivElement;
      vi.spyOn(grid, "getBoundingClientRect").mockReturnValue({
        left: 0,
        top: 0,
        width: 200,
        height: 700,
        right: 200,
        bottom: 700,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      });
      await act(async () => grid.dispatchEvent(pointerEvent("pointermove", {
        pointerType: "mouse",
        clientX: 50,
        clientY: ((weekday + 0.5) / 7) * 700,
      })));
      expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')?.getAttribute("aria-label"))
        .toContain(previous);
      await act(async () => grid.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })));
      expect(grid.querySelector('[role="gridcell"][aria-selected="true"]')?.getAttribute("aria-label"))
        .toContain(current);

      act(() => mountedRoot?.unmount());
      mountedRoot = null;
      container.replaceChildren();
    }
  });

  it("switches chart tokens with explicit themes and keeps ForceGauge canvas palette reactive", async () => {
    const style = document.createElement("style");
    style.textContent = readFileSync("src/index.css", "utf8");
    document.head.appendChild(style);
    document.documentElement.dataset.theme = "light";
    expect(getComputedStyle(document.documentElement).getPropertyValue("--chart-grid").trim()).toBe(
      "#E2E2E6",
    );
    document.documentElement.dataset.theme = "dark";
    expect(getComputedStyle(document.documentElement).getPropertyValue("--chart-grid").trim()).toBe(
      "#3E3E44",
    );

    const mediaListeners = new Map<string, Set<(event: MediaQueryListEvent) => void>>();
    const mediaStates = new Map<string, { matches: boolean; dispatch: () => void }>();
    const makeMedia = (query: string) => {
      const listeners = new Set<(event: MediaQueryListEvent) => void>();
      mediaListeners.set(query, listeners);
      const state = {
        matches: false,
        dispatch: () => {
          const event = {
            type: "change",
            media: query,
            matches: state.matches,
          } as MediaQueryListEvent;
          for (const listener of listeners) listener(event);
        },
      };
      mediaStates.set(query, state);
      return {
        get matches() {
          return state.matches;
        },
        media: query,
        addEventListener: (_type: string, listener: (event: MediaQueryListEvent) => void) => {
          listeners.add(listener);
        },
        removeEventListener: (_type: string, listener: (event: MediaQueryListEvent) => void) => {
          listeners.delete(listener);
        },
        addListener: (listener: (event: MediaQueryListEvent) => void) => listeners.add(listener),
        removeListener: (listener: (event: MediaQueryListEvent) => void) => listeners.delete(listener),
      } as unknown as MediaQueryList;
    };
    vi.stubGlobal("matchMedia", (query: string) => makeMedia(query));

    const strokeStyles: string[] = [];
    let currentStroke = "";
    const context = {
      setTransform: vi.fn(),
      clearRect: vi.fn(),
      beginPath: vi.fn(),
      moveTo: vi.fn(),
      lineTo: vi.fn(),
      stroke: vi.fn(),
      fillRect: vi.fn(),
      setLineDash: vi.fn(),
      lineWidth: 1,
      lineJoin: "round",
      globalAlpha: 1,
      get strokeStyle() {
        return currentStroke;
      },
      set strokeStyle(value: string) {
        currentStroke = value;
        strokeStyles.push(value);
      },
      fillStyle: "",
    } as unknown as CanvasRenderingContext2D;
    const getContext = vi
      .spyOn(HTMLCanvasElement.prototype, "getContext")
      .mockReturnValue(context);
    document.documentElement.style.setProperty("--chart-grid", "#101010");
    document.documentElement.style.setProperty("--chart-focus", "#202020");
    document.documentElement.style.setProperty("--chart-optimal", "#303030");
    const samples: TindeqSample[] = [
      { t: 0, kg: 10 },
      { t: 100, kg: 12 },
    ];
    mountedRoot = mount(
      container,
      <ForceGauge
        current={12}
        peak={12}
        elapsedMs={100}
        samplesRef={{ current: samples }}
        live={false}
      />,
    );
    expect(mediaListeners.get("(prefers-color-scheme: dark)")?.size).toBe(1);
    expect(mediaListeners.get("(prefers-contrast: more)")?.size).toBe(1);
    expect(strokeStyles).toContain("#101010");
    expect(strokeStyles).toContain("#202020");

    document.documentElement.style.setProperty("--chart-grid", "#404040");
    document.documentElement.style.setProperty("--chart-focus", "#505050");
    await act(async () => {
      document.documentElement.dataset.theme = "light";
      const state = mediaStates.get("(prefers-color-scheme: dark)")!;
      state.matches = false;
      state.dispatch();
    });
    expect(strokeStyles).toContain("#404040");
    expect(strokeStyles).toContain("#505050");
    document.documentElement.style.setProperty("--chart-grid", "#606060");
    document.documentElement.style.setProperty("--chart-focus", "#707070");
    await act(async () => {
      const state = mediaStates.get("(prefers-contrast: more)")!;
      state.matches = true;
      state.dispatch();
    });
    expect(strokeStyles).toContain("#606060");
    expect(strokeStyles).toContain("#707070");
    getContext.mockRestore();
    style.remove();
    vi.unstubAllGlobals();
  });
});
