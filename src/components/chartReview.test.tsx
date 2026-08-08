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
import { today } from "../lib/dates";
import { CURVE_PERIOD_STYLES } from "../lib/chartPeriodStyles";
import type { ForceCurveModel, PeriodCurve } from "../lib/force-curve";
import type { TindeqRecordingMeta, TindeqSample, WorkoutAttempt } from "../types";

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

  it("exposes heatmap days and weekly load as keyboard-operable data points", async () => {
    const values = new Map([[today(), { total: 100, type: "board" }]]);
    const heatmap = parse(
      renderToStaticMarkup(<ContributionHeatmap values={values} weeks={1} />),
    );
    const heatmapDescription = heatmap.querySelector('[role="group"]')?.getAttribute("aria-describedby");
    expect(heatmapDescription).toMatch(/^contribution-summary-/);
    expect(heatmapDescription && heatmap.querySelector(`#${heatmapDescription}`)).not.toBeNull();
    const grid = heatmap.querySelector('[role="grid"]');
    expect(grid?.getAttribute("tabindex")).toBe("0");
    expect(heatmap.querySelectorAll('[role="gridcell"]').length).toBe(7);
    expect(heatmap.querySelectorAll("button[aria-label]").length).toBe(0);
    expect(heatmap.querySelectorAll('[role="img"]').length).toBe(0);

    mountedRoot = mount(
      container,
      <ContributionHeatmap values={values} weeks={1} />,
    );
    const heatmapDay = container.querySelector('[role="grid"]') as HTMLDivElement;
    expect(heatmapDay).toBeTruthy();
    await act(async () => {
      heatmapDay.focus();
      heatmapDay.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
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
    const makeMedia = (query: string) => {
      const listeners = new Set<(event: MediaQueryListEvent) => void>();
      mediaListeners.set(query, listeners);
      return {
      matches: false,
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
    expect(strokeStyles).toContain("#101010");
    expect(strokeStyles).toContain("#202020");

    document.documentElement.style.setProperty("--chart-grid", "#404040");
    document.documentElement.style.setProperty("--chart-focus", "#505050");
    await act(async () => {
      document.documentElement.dataset.theme = "light";
      for (const listener of mediaListeners.get("(prefers-color-scheme: dark)") ?? []) {
        listener({} as MediaQueryListEvent);
      }
    });
    expect(strokeStyles).toContain("#404040");
    expect(strokeStyles).toContain("#505050");
    document.documentElement.style.setProperty("--chart-grid", "#606060");
    document.documentElement.style.setProperty("--chart-focus", "#707070");
    await act(async () => {
      for (const listener of mediaListeners.get("(prefers-contrast: more)") ?? []) {
        listener({} as MediaQueryListEvent);
      }
    });
    expect(strokeStyles).toContain("#606060");
    expect(strokeStyles).toContain("#707070");
    getContext.mockRestore();
    style.remove();
    vi.unstubAllGlobals();
  });
});
