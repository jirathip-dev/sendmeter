import { useEffect, useState } from "react";
import type { LiveWorkout } from "../types";

/// A pinned, read-only row at the top of History for the workout that's
/// happening RIGHT NOW on the watch (SL-98). It appears the instant the live
/// heartbeat arrives — no waiting for the offline queue to flush the finished
/// session — so a long session is visibly "being tracked". Driven entirely by
/// the live_workouts heartbeat; disappears on its own once the workout ends
/// (the hook returns null) and the real session row takes its place.
export default function LiveSessionRow({ live }: { live: LiveWorkout }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  const elapsedS = Math.max(0, (now - new Date(live.startedAt).getTime()) / 1000);
  const mm = Math.floor(elapsedS / 60);
  const ss = String(Math.floor(elapsedS % 60)).padStart(2, "0");

  return (
    <div
      className="session-row"
      style={{
        alignItems: "center",
        gap: 12,
        border: "1px solid color-mix(in srgb, var(--success) 45%, transparent)",
        background: "color-mix(in srgb, var(--success) 8%, var(--surface-1))",
      }}
    >
      <span
        aria-hidden="true"
        style={{
          width: 9,
          height: 9,
          borderRadius: "50%",
          background: "var(--success)",
          flexShrink: 0,
          animation: "pulse 1.6s ease-in-out infinite",
        }}
      />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", gap: 7, alignItems: "center", marginBottom: 4 }}>
          <span style={{ fontSize: "var(--t-base)", color: "var(--ink)", fontWeight: 700 }}>
            {live.climbing ? "Climbing now" : "Workout in progress"}
          </span>
          <span
            className="tag"
            style={{
              background: "color-mix(in srgb, var(--success) 18%, transparent)",
              color: "var(--success)",
              border: "1px solid color-mix(in srgb, var(--success) 45%, transparent)",
            }}
          >
            LIVE
          </span>
        </div>
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
          {mm}:{ss} elapsed · {live.attemptCount} boulder
          {live.attemptCount === 1 ? "" : "s"}
          {live.hr !== null && (
            <span style={{ color: "var(--danger)" }}> · ♥ {Math.round(live.hr)}</span>
          )}
          {live.activeKcal !== null && ` · ${Math.round(live.activeKcal)} kcal`}
        </div>
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 3 }}>
          Tracking on your watch — it lands here when the workout ends.
        </div>
      </div>
    </div>
  );
}
