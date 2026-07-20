import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import type { LiveHrPoint } from "../hooks/useLiveWorkout";
import type { LiveWorkout } from "../types";

interface Props {
  live: LiveWorkout;
  /// Client-accumulated heartbeat HR (SL-90) — one point per ~5s beat since
  /// this mirror mounted. Realtime chart, not the durable trace.
  hrSeries: LiveHrPoint[];
  onMinimize: () => void;
}

function fmt(sec: number): string {
  const s = Math.max(0, Math.round(sec));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

const SPARK_W = 300;
const SPARK_H = 56;

/// Live HR sparkline — draws once ≥2 beats have arrived. Plain polyline in a
/// fixed viewBox; the y-domain pads the observed range so the line breathes.
function HrSparkline({ pts }: { pts: LiveHrPoint[] }) {
  if (pts.length < 2) return null;
  const tMin = pts[0]!.t;
  const tMax = Math.max(pts[pts.length - 1]!.t, tMin + 1);
  const hrs = pts.map((p) => p.hr);
  const yMin = Math.min(...hrs) - 5;
  const yMax = Math.max(...hrs) + 5;
  const x = (t: number) => ((t - tMin) / (tMax - tMin)) * SPARK_W;
  const y = (hr: number) =>
    SPARK_H - ((hr - yMin) / (yMax - yMin)) * (SPARK_H - 8) - 4;
  const points = pts.map((p) => `${x(p.t).toFixed(1)},${y(p.hr).toFixed(1)}`).join(" ");
  const last = pts[pts.length - 1]!;
  return (
    <svg
      viewBox={`0 0 ${SPARK_W} ${SPARK_H}`}
      style={{ width: "100%", display: "block" }}
      aria-label="Live heart-rate chart"
    >
      <polyline
        points={points}
        fill="none"
        stroke="#E5743A"
        strokeWidth={1.6}
        strokeLinejoin="round"
        strokeLinecap="round"
      />
      <circle cx={x(last.t)} cy={y(last.hr)} r={2.6} fill="#E5743A" />
      <text x={0} y={9} fontSize={8} style={{ fill: "var(--ink-faint)" }}>
        {Math.round(yMax - 5)}
      </text>
      <text x={0} y={SPARK_H - 1} fontSize={8} style={{ fill: "var(--ink-faint)" }}>
        {Math.round(yMin + 5)}
      </text>
    </svg>
  );
}

/// Read-only fullscreen mirror of the in-progress WATCH workout — the same
/// CLIMBING / RESTING timer screen as the phone workout, driven by the
/// live_workouts heartbeat. The phase timestamps are absolute, so the timers
/// tick locally with second precision between ~5s beats; the watch also beats
/// immediately on Boulder/Stop, so phase flips land fast. No controls here —
/// the watch owns the workout.
export default function LiveWorkoutFullscreen({ live, hrSeries, onMinimize }: Props) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(t);
  }, []);

  const totalElapsed = (now - new Date(live.startedAt).getTime()) / 1000;
  const climbing = live.climbing;

  // Old watch builds don't send phase timestamps — fall back to startedAt so
  // the screen still renders something sensible.
  const climbingSinceMs = live.climbingSince
    ? new Date(live.climbingSince).getTime()
    : new Date(live.startedAt).getTime();
  const restStartedMs = live.restStartedAt
    ? new Date(live.restStartedAt).getTime()
    : new Date(live.startedAt).getTime();
  const restTarget = live.restTargetS ?? 180;

  const onWall = (now - climbingSinceMs) / 1000;
  const restElapsed = (now - restStartedMs) / 1000;
  const restRemaining = restTarget - restElapsed;
  const restOver = !climbing && restRemaining <= 0;

  const accent = climbing ? "var(--success)" : restOver ? "var(--danger)" : "var(--primary)";

  return createPortal(
    <div
      className="fullscreen-overlay"
      style={{
        background: `color-mix(in srgb, ${accent} 12%, var(--canvas))`,
        transition: "background 0.3s",
        display: "flex",
        justifyContent: "center",
      }}
    >
      <div
        style={{
          width: "100%",
          maxWidth: 520,
          display: "flex",
          flexDirection: "column",
          padding: "max(16px, env(safe-area-inset-top)) 16px max(16px, env(safe-area-inset-bottom))",
          boxSizing: "border-box",
        }}
      >
        {/* Top bar — minimize · live label + workout clock · HR readout */}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
          <button onClick={onMinimize} aria-label="Minimize" className="glass-chip">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M6 9l6 6 6-6" />
            </svg>
          </button>
          <div style={{ textAlign: "center" }}>
            <div className="label-eyebrow" style={{ display: "flex", alignItems: "center", gap: 6, justifyContent: "center" }}>
              <span
                aria-hidden="true"
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: "50%",
                  background: "var(--success)",
                  animation: "pulse 1.6s ease-in-out infinite",
                }}
              />
              Live on watch
            </div>
            <div style={{ fontWeight: 800, fontSize: "var(--t-lg)", letterSpacing: "-0.02em" }}>
              {fmt(totalElapsed)}
            </div>
          </div>
          <div
            style={{
              minWidth: 64,
              textAlign: "right",
              fontWeight: 700,
              fontSize: "var(--t-base)",
              color: "var(--danger)",
            }}
          >
            {live.hr !== null ? <>♥ {Math.round(live.hr)}</> : null}
          </div>
        </div>

        {/* Phase banner + big timer — same layout as the phone workout */}
        <div
          style={{
            flex: 1,
            margin: "12px 0",
            borderRadius: 20,
            background: `color-mix(in srgb, ${accent} 18%, var(--surface-1))`,
            border: `1px solid color-mix(in srgb, ${accent} 45%, transparent)`,
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            gap: 4,
            animation: restOver ? "pulse 0.8s ease-in-out infinite" : undefined,
          }}
        >
          <div style={{ fontWeight: 800, letterSpacing: "0.08em", fontSize: "var(--t-lg)", color: accent }}>
            {climbing ? "CLIMBING" : restOver ? "REST OVER" : "RESTING"}
          </div>
          <div
            style={{
              fontWeight: 800,
              fontSize: "clamp(64px, 22vw, 140px)",
              lineHeight: 1,
              color: "var(--ink)",
            }}
          >
            {climbing ? fmt(onWall) : fmt(Math.max(0, restRemaining))}
          </div>
          <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)" }}>
            {climbing ? "on the wall" : `rest target ${fmt(restTarget)}`}
            {" · "}
            <span style={{ color: "var(--ink)", fontWeight: 600 }}>
              {live.attemptCount} boulder{live.attemptCount === 1 ? "" : "s"}
            </span>
            {live.activeKcal !== null && (
              <> · {Math.round(live.activeKcal)} kcal</>
            )}
          </div>
        </div>

        {/* Realtime HR chart (SL-90) — builds up from the heartbeats while
            this mirror is open. */}
        {hrSeries.length >= 2 && (
          <div
            style={{
              borderRadius: 14,
              border: "1px solid var(--border)",
              background: "var(--surface-1)",
              padding: "8px 10px 4px",
              marginBottom: 10,
            }}
          >
            <div className="label-eyebrow" style={{ marginBottom: 2 }}>
              Heart rate
            </div>
            <HrSparkline pts={hrSeries} />
          </div>
        )}

        <div style={{ textAlign: "center", fontSize: "var(--t-sm)", color: "var(--ink-faint)", paddingBottom: 4 }}>
          Controlled from your watch — log boulders and end it there.
        </div>
      </div>
    </div>,
    document.body,
  );
}
