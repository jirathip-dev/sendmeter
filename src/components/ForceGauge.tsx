import { useEffect, useRef } from "react";
import type { RefObject } from "react";
import type { TindeqSample } from "../types";

const WINDOW_MS = 10_000;

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
  elapsedMs: number;
  samplesRef: RefObject<TindeqSample[]>;
  live: boolean;
  target?: GaugeTargetZone | null;
}

function drawTrace(
  canvas: HTMLCanvasElement,
  samples: TindeqSample[],
  nowT: number,
  target?: GaugeTargetZone | null,
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
  ctx.strokeStyle = "rgba(136,136,142,0.3)";
  ctx.lineWidth = 1;
  for (let i = 1; i < 4; i++) {
    const y = (h / 4) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }

  // target zone band + line
  if (target) {
    const yLow = h - (target.lowKg / maxKg) * h;
    const yHigh = h - (target.highKg / maxKg) * h;
    ctx.fillStyle = "rgba(52,199,89,0.10)";
    ctx.fillRect(0, yHigh, w, yLow - yHigh);
    const yTarget = h - (target.kg / maxKg) * h;
    ctx.strokeStyle = "rgba(52,199,89,0.6)";
    ctx.setLineDash([5, 4]);
    ctx.beginPath();
    ctx.moveTo(0, yTarget);
    ctx.lineTo(w, yTarget);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  if (visible.length < 2) return;
  ctx.strokeStyle = "#5B5FC7";
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
  elapsedMs,
  samplesRef,
  live,
  target,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    if (!live) {
      // one final draw of whatever is in the buffer
      const samples = samplesRef.current;
      drawTrace(canvas, samples, samples[samples.length - 1]?.t ?? 0, target);
      return;
    }
    let raf = 0;
    const tick = () => {
      const samples = samplesRef.current;
      drawTrace(canvas, samples, samples[samples.length - 1]?.t ?? 0, target);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [live, samplesRef, target]);

  const inZone =
    target && live && current >= target.lowKg && current <= target.highKg;
  const workDone = target && elapsedMs >= target.workS * 1000;

  return (
    <div className="card">
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "flex-end",
          marginBottom: 12,
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
            <span style={{ fontSize: 16, color: "var(--ink-muted)", marginLeft: 4 }}>
              kg
            </span>
          </div>
        </div>
        <div style={{ textAlign: "right" }}>
          <div style={{ fontSize: 11, color: "var(--ink-muted)" }}>
            peak{" "}
            <span
              style={{
                color: "var(--success)",
                fontFamily: "Inter, sans-serif",
                fontWeight: 800,
                fontSize: 15,
              }}
            >
              {peak.toFixed(1)}
            </span>{" "}
            kg
          </div>
          <div
            style={{
              fontSize: 11,
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
        style={{ width: "100%", height: 140, display: "block" }}
      />
      {target && (
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            fontSize: 10,
            color: "var(--ink-muted)",
            marginTop: 6,
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
