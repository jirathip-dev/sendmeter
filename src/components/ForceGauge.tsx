import { useEffect, useRef } from "react";
import type { RefObject } from "react";
import type { TindeqSample } from "../types";

const WINDOW_MS = 10_000;

interface Props {
  current: number;
  peak: number;
  elapsedMs: number;
  samplesRef: RefObject<TindeqSample[]>;
  live: boolean;
}

function drawTrace(
  canvas: HTMLCanvasElement,
  samples: TindeqSample[],
  nowT: number,
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
  const maxKg = Math.max(10, ...visible.map((s) => s.kg)) * 1.15;

  // gridlines
  ctx.strokeStyle = "#1a2030";
  ctx.lineWidth = 1;
  for (let i = 1; i < 4; i++) {
    const y = (h / 4) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }

  if (visible.length < 2) return;
  ctx.strokeStyle = "#4ade80";
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
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    if (!live) {
      // one final draw of whatever is in the buffer
      const samples = samplesRef.current;
      drawTrace(canvas, samples, samples[samples.length - 1]?.t ?? 0);
      return;
    }
    let raf = 0;
    const tick = () => {
      const samples = samplesRef.current;
      drawTrace(canvas, samples, samples[samples.length - 1]?.t ?? 0);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [live, samplesRef]);

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
          <div
            style={{
              fontSize: 9,
              color: "#4a5a70",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 4,
            }}
          >
            Force
          </div>
          <div
            style={{
              fontFamily: "'Syne', sans-serif",
              fontSize: 44,
              fontWeight: 800,
              lineHeight: 1,
              color: "#e2e8f0",
              letterSpacing: "-0.04em",
            }}
          >
            {current.toFixed(1)}
            <span style={{ fontSize: 16, color: "#4a5a70", marginLeft: 4 }}>
              kg
            </span>
          </div>
        </div>
        <div style={{ textAlign: "right" }}>
          <div style={{ fontSize: 11, color: "#7a8a9a" }}>
            peak{" "}
            <span
              style={{
                color: "#4ade80",
                fontFamily: "'Syne', sans-serif",
                fontWeight: 800,
                fontSize: 15,
              }}
            >
              {peak.toFixed(1)}
            </span>{" "}
            kg
          </div>
          <div style={{ fontSize: 11, color: "#4a5a70", marginTop: 2 }}>
            {(elapsedMs / 1000).toFixed(1)}s
          </div>
        </div>
      </div>
      <canvas
        ref={canvasRef}
        style={{ width: "100%", height: 140, display: "block" }}
      />
    </div>
  );
}
