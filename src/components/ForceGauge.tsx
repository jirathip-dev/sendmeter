import { useEffect, useRef } from "react";
import type { RefObject } from "react";
import { CHART_MIN_PX } from "../lib/fullscreenLayout";
import type { TindeqSample } from "../types";

const WINDOW_MS = 10_000;

interface TracePalette {
  grid: string;
  optimal: string;
  focus: string;
}

function cssChartColor(canvas: HTMLCanvasElement, name: string, fallback: string): string {
  return getComputedStyle(canvas).getPropertyValue(name).trim() || fallback;
}

export interface GaugeTargetZone {
  kg: number;
  lowKg: number;
  highKg: number;
  workS: number;
  label: string;
}

interface Props {
  current: number;
  peak: number;
  /// Running mean of the current pull (0 while idle).
  avg?: number;
  elapsedMs: number;
  samplesRef: RefObject<TindeqSample[]>;
  live: boolean;
  target?: GaugeTargetZone | null;
  /// Trace height in px. Ignored when `fill` is set.
  chartHeight?: number;
  /// Fill the parent's height instead of sizing to `chartHeight` (#221): the
  /// card becomes a flex column and the trace absorbs whatever vertical space
  /// the fullscreen overlay has left over, down to a readable floor. That is
  /// what keeps START/STOP on-screen on a 375×667 phone.
  fill?: boolean;
}

function drawTrace(
  canvas: HTMLCanvasElement,
  samples: TindeqSample[],
  nowT: number,
  target?: GaugeTargetZone | null,
  palette: TracePalette = { grid: "#8E8E93", optimal: "#2E96F0", focus: "#5B5FC7" },
) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
    canvas.width = w * dpr;
    canvas.height = h * dpr;
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  const t1 = Math.max(nowT, WINDOW_MS);
  const t0 = t1 - WINDOW_MS;
  const visible = samples.filter((s) => s.t >= t0);
  const maxKg =
    Math.max(10, target ? target.highKg : 0, ...visible.map((s) => s.kg)) *
    1.15;

  // gridlines
  ctx.strokeStyle = palette.grid;
  ctx.globalAlpha = 0.3;
  ctx.lineWidth = 1;
  for (let i = 1; i < 4; i++) {
    const y = (h / 4) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;

  // target zone band + line
  if (target) {
    const yLow = h - (target.lowKg / maxKg) * h;
    const yHigh = h - (target.highKg / maxKg) * h;
    ctx.fillStyle = palette.optimal;
    ctx.globalAlpha = 0.1;
    ctx.fillRect(0, yHigh, w, yLow - yHigh);
    const yTarget = h - (target.kg / maxKg) * h;
    ctx.strokeStyle = palette.optimal;
    ctx.globalAlpha = 0.6;
    ctx.setLineDash([5, 4]);
    ctx.beginPath();
    ctx.moveTo(0, yTarget);
    ctx.lineTo(w, yTarget);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;
  }

  if (visible.length < 2) return;
  ctx.strokeStyle = palette.focus;
  ctx.lineWidth = 2;
  ctx.lineJoin = "round";
  ctx.beginPath();
  for (let i = 0; i < visible.length; i++) {
    const s = visible[i]!;
    const x = ((s.t - t0) / WINDOW_MS) * w;
    const y = h - (s.kg / maxKg) * h;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();
}

export default function ForceGauge({
  current,
  peak,
  avg = 0,
  elapsedMs,
  samplesRef,
  live,
  target,
  chartHeight = 140,
  fill = false,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const readPalette = (): TracePalette => ({
      grid: cssChartColor(canvas, "--chart-grid", "#8E8E93"),
      optimal: cssChartColor(canvas, "--chart-optimal", "#2E96F0"),
      focus: cssChartColor(canvas, "--chart-focus", "#5B5FC7"),
    });
    let palette = readPalette();
    const drawCurrent = () => {
      // Computed styles are read only at mount or when a theme signal changes;
      // the live RAF below reuses this palette for every trace frame.
      palette = readPalette();
      const samples = samplesRef.current;
      drawTrace(canvas, samples, samples[samples.length - 1]?.t ?? 0, target, palette);
    };
    // Theme changes are rare compared with trace frames. Observe the root
    // instead of reading computed styles in the animation loop, keeping the
    // live canvas cheap while still adapting immediately to explicit and
    // system light/dark mode.
    const themeObserver = new MutationObserver(() => {
      drawCurrent();
    });
    themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });
    const preferences = [
      window.matchMedia("(prefers-color-scheme: dark)"),
      window.matchMedia("(prefers-contrast: more)"),
    ];
    const onPreferenceChange = () => drawCurrent();
    for (const preference of preferences) {
      if (typeof preference.addEventListener === "function") {
        preference.addEventListener("change", onPreferenceChange);
      } else {
        preference.addListener(onPreferenceChange);
      }
    }
    const removePreferenceListeners = () => {
      for (const preference of preferences) {
        if (typeof preference.removeEventListener === "function") {
          preference.removeEventListener("change", onPreferenceChange);
        } else {
          preference.removeListener(onPreferenceChange);
        }
      }
    };
    if (!live) {
      drawCurrent();
      return () => {
        themeObserver.disconnect();
        removePreferenceListeners();
      };
    }
    let raf = 0;
    const tick = () => {
      const samples = samplesRef.current;
      drawTrace(canvas, samples, samples[samples.length - 1]?.t ?? 0, target, palette);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      themeObserver.disconnect();
      removePreferenceListeners();
    };
  }, [live, samplesRef, target]);

  const inZone =
    target && live && current >= target.lowKg && current <= target.highKg;
  const workDone = target && elapsedMs >= target.workS * 1000;

  return (
    <div
      className="card"
      style={
        fill
          ? {
              display: "flex",
              flexDirection: "column",
              height: "100%",
              minHeight: 0,
              boxSizing: "border-box",
            }
          : undefined
      }
    >
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "flex-end",
          marginBottom: 12,
          flexShrink: 0,
        }}
      >
        <div>
          <div className="label-eyebrow" style={{ marginBottom: 4 }}>
            Force
          </div>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 44,
              fontWeight: 800,
              lineHeight: 1,
              color: inZone ? "var(--success)" : "var(--ink)",
              letterSpacing: "-0.04em",
            }}
          >
            {current.toFixed(1)}
            <span style={{ fontSize: "var(--t-md)", color: "var(--ink-muted)", marginLeft: 4 }}>
              kg
            </span>
          </div>
        </div>
        <div style={{ textAlign: "right" }}>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
            peak{" "}
            <span
              style={{
                color: "var(--success)",
                fontFamily: "Inter, sans-serif",
                fontWeight: 800,
                fontSize: "var(--t-md)",
              }}
            >
              {peak.toFixed(1)}
            </span>{" "}
            kg
          </div>
          {avg > 0 && (
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 2 }}>
              avg{" "}
              <span
                style={{
                  color: "var(--ink)",
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 700,
                  fontSize: "var(--t-base)",
                }}
              >
                {avg.toFixed(1)}
              </span>{" "}
              kg
            </div>
          )}
          <div
            style={{
              fontSize: "var(--t-xs)",
              color: workDone ? "var(--success)" : "var(--ink-muted)",
              marginTop: 2,
            }}
          >
            {(elapsedMs / 1000).toFixed(1)}s
            {target && (
              <span style={{ color: "var(--ink-faint)" }}> / {target.workS}s</span>
            )}
          </div>
        </div>
      </div>
      <canvas
        ref={canvasRef}
        style={
          fill
            ? { width: "100%", flex: 1, minHeight: CHART_MIN_PX, display: "block" }
            : { width: "100%", height: chartHeight, display: "block" }
        }
      />
      {target && (
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            fontSize: "var(--t-2xs)",
            color: "var(--ink-muted)",
            marginTop: 6,
            flexShrink: 0,
          }}
        >
          <span>
            target{" "}
            <span style={{ color: "var(--success)" }}>{target.kg.toFixed(1)} kg</span>{" "}
            ({target.lowKg.toFixed(1)}–{target.highKg.toFixed(1)}) ·{" "}
            {target.workS}s
          </span>
          <span style={{ color: "var(--ink-faint)" }}>{target.label}</span>
        </div>
      )}
    </div>
  );
}
