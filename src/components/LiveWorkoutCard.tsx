import { useEffect, useState } from "react";
import type { LiveWorkout } from "../types";
import type { LiveWorkoutSyncState } from "../lib/liveWorkoutMirror";

function fmtElapsed(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`
    : `${m}:${String(sec).padStart(2, "0")}`;
}

/// Honest transport copy (#614): `watch-direct` and `server-fallback` name
/// the last accepted message's transport; `temporarily-unreachable` means
/// the row is older than one heartbeat cadence (neither path fresh) and the
/// mirror is showing the last update; `unknown` must not read as healthy.
const SYNC_COPY: Record<LiveWorkoutSyncState, string> = {
  "watch-direct": "Instant watch link",
  "server-fallback": "Catching up through the server",
  "temporarily-unreachable": "Wrist link paused — showing the last update",
  unknown: "Link state unknown",
};

/// Live mirror of the in-progress watch workout (SL-41) — heartbeat data
/// from the live_workouts row, re-rendered every second for the clock.
/// Tapping opens the fullscreen mirror (same timer screen as phone workouts).
export default function LiveWorkoutCard({
  live,
  syncState = "server-fallback",
  onOpen,
}: {
  live: LiveWorkout;
  syncState?: LiveWorkoutSyncState;
  onOpen: () => void;
}) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  const elapsed = now - new Date(live.startedAt).getTime();

  return (
    <div
      className="card surface-workout tappable"
      onClick={onOpen}
      style={{
        marginBottom: 12,
        border: "1px solid color-mix(in srgb, var(--success) 45%, transparent)",
      }}
    >
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginBottom: 10,
        }}
      >
        <span className="card-title" style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span
            aria-hidden="true"
            style={{
              width: 7,
              height: 7,
              borderRadius: "50%",
              background: "var(--success)",
              animation: "pulse 1.6s ease-in-out infinite",
            }}
          />
          Live on watch
        </span>
        <span
          className="tag"
          style={{
            background: live.climbing
              ? "color-mix(in srgb, var(--success) 16%, transparent)"
              : "transparent",
            color: live.climbing ? "var(--success)" : "var(--ink-muted)",
            border: `1px solid ${live.climbing ? "var(--success)" : "var(--border)"}`,
          }}
        >
          {live.climbing ? "CLIMBING" : "RESTING"}
        </span>
        <span aria-hidden="true" style={{ color: "var(--ink-faint)", fontSize: "var(--t-md)" }}>›</span>
      </div>

      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", marginTop: 8 }}>
        {SYNC_COPY[syncState]}
      </div>

      <div style={{ display: "flex", alignItems: "baseline", gap: 14, flexWrap: "wrap" }}>
        <span
          style={{
            fontFamily: "Inter, sans-serif",
            fontWeight: 800,
            fontSize: 32,
            fontVariantNumeric: "tabular-nums",
          }}
        >
          {fmtElapsed(elapsed)}
        </span>
        <span style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)" }}>
          {live.hr !== null && (
            <>
              <span style={{ color: "var(--danger)" }}>♥</span>{" "}
              {Math.round(live.hr)} bpm ·{" "}
            </>
          )}
          {live.attemptCount} boulder{live.attemptCount === 1 ? "" : "s"}
          {live.activeKcal !== null && ` · ${Math.round(live.activeKcal)} kcal`}
        </span>
      </div>
    </div>
  );
}
