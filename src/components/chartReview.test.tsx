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
    expect(root.querySelectorAll('circle[role="button"][tabindex="0"]')).toHaveLength(
      curveModel.points.length * 2,
    );
    expect(
      Array.from(root.querySelectorAll('circle[role="button"]'), (node) => Number(node.getAttribute("r"))),
    ).toEqual(curveModel.points.flatMap(() => [22, 22]));
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
    const overlays = Array.from(container.querySelectorAll("polyline[stroke-dasharray]"));
    expect(overlays).toHaveLength(Object.keys(CURVE_PERIOD_STYLES).length);
    expect(new Set(overlays.map((line) => line.getAttribute("stroke-dasharray"))).size).toBe(
      overlays.length,
    );
    expect(new Set(overlays.map((line) => line.getAttribute("stroke"))).size).toBe(overlays.length);
  });

  it("keeps effort scrubbing on a transparent 44-unit target", () => {
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

  it("keeps force-trend boxes visible and their day targets at 44 units", () => {
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
    expect(Number(hit?.getAttribute("width"))).toBeGreaterThanOrEqual(44);
    const boxes = Array.from(root.querySelectorAll('rect[fill^="url("]'));
    expect(boxes.length).toBeGreaterThanOrEqual(2);
    expect(boxes.every((box) => Number(box.getAttribute("fill-opacity")) >= 0.8)).toBe(true);
  });

  it("exposes heatmap days and weekly load as keyboard-operable data points", async () => {
    const values = new Map([[today(), { total: 100, type: "board" }]]);
    const heatmap = parse(
      renderToStaticMarkup(<ContributionHeatmap values={values} weeks={1} />),
    );
    const heatmapDescription = heatmap.querySelector('[role="group"]')?.getAttribute("aria-describedby");
    expect(heatmapDescription).toMatch(/^contribution-summary-/);
    expect(heatmapDescription && heatmap.querySelector(`#${heatmapDescription}`)).not.toBeNull();
    expect(heatmap.querySelectorAll("button[aria-label]").length).toBe(7);
    expect(heatmap.querySelectorAll('[role="img"]').length).toBe(0);

    mountedRoot = mount(
      container,
      <ContributionHeatmap values={values} weeks={1} />,
    );
    const heatmapDay = container.querySelector("button:not([disabled])") as HTMLButtonElement;
    expect(heatmapDay).toBeTruthy();
    await act(async () => {
      heatmapDay.focus();
      heatmapDay.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
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
    const weekly = container.querySelector('[aria-label="Weekly training load bars"]');
    const weeklyDescription = weekly?.getAttribute("aria-describedby");
    expect(weeklyDescription).toMatch(/^weekly-load-summary-/);
    expect(weeklyDescription && container.querySelector(`#${weeklyDescription}`)).not.toBeNull();
    const weekButton = weekly?.querySelector("button") as HTMLButtonElement;
    expect(weekButton?.getAttribute("aria-label")).toContain("W1");
    await act(async () => {
      weekButton.focus();
      weekButton.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true }));
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

    const mediaListeners = new Set<(event: MediaQueryListEvent) => void>();
    const media = {
      matches: false,
      media: "(prefers-color-scheme: dark)",
      addEventListener: (_type: string, listener: (event: MediaQueryListEvent) => void) => {
        mediaListeners.add(listener);
      },
      removeEventListener: (_type: string, listener: (event: MediaQueryListEvent) => void) => {
        mediaListeners.delete(listener);
      },
      addListener: (listener: (event: MediaQueryListEvent) => void) => mediaListeners.add(listener),
      removeListener: (listener: (event: MediaQueryListEvent) => void) => mediaListeners.delete(listener),
    } as unknown as MediaQueryList;
    vi.stubGlobal("matchMedia", () => media);

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
      for (const listener of mediaListeners) listener({} as MediaQueryListEvent);
    });
    expect(strokeStyles).toContain("#404040");
    expect(strokeStyles).toContain("#505050");
    getContext.mockRestore();
    style.remove();
    vi.unstubAllGlobals();
  });
});
