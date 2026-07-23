import { useState } from "react";
import { fetchRecentWorkoutDetails, fetchWorkoutRaw } from "../lib/repo";
import {
  hrRecoveryBpm,
  recentDailyRpe,
  workRestRatio,
} from "../lib/workoutStats";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import type { Session, WorkoutDetail } from "../types";

// `iso` here is always a full climb_workouts timestamp (started_at), so
// parsing it is safe — it's an instant, not a bare local date, and
// `getMonth`/`getDate` read it back in the viewer's own timezone.
function dayLabel(iso: string): string {
  const d = new Date(iso);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

// `dateStr` here is a session's own YYYY-MM-DD (dates.ts) — split it
// directly rather than `new Date(dateStr)`, which parses as UTC midnight
// and would misdate sessions near a UTC-day boundary once reinterpreted in
// the viewer's local zone.
function dateLabel(dateStr: string): string {
  const [, m, d] = dateStr.split("-");
  return `${Number(m)}/${Number(d)}`;
}

/// Horizontal mini bar-trend: one row per workout, bar scaled to the max.
function BarTrend({
  rows,
  color,
  fmt,
}: {
  rows: { label: string; value: number | null }[];
  color: string;
  fmt: (v: number) => string;
}) {
  const max = Math.max(1, ...rows.map((r) => r.value ?? 0));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
      {rows.map((r, i) => (
        <div key={i} style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", width: 30, flexShrink: 0 }}>
            {r.label}
          </span>
          <div style={{ flex: 1, height: 8, borderRadius: 4, background: "var(--surface-1)", overflow: "hidden" }}>
            {r.value !== null && (
              <div
                style={{
                  width: `${(r.value / max) * 100}%`,
                  height: "100%",
                  background: color,
                  borderRadius: 4,
                }}
              />
            )}
          </div>
          <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink)", width: 40, textAlign: "right", flexShrink: 0 }}>
            {r.value !== null ? fmt(r.value) : "—"}
          </span>
        </div>
      ))}
    </div>
  );
}

/// Summary stats for the Workout tab (SL-85 / SL-99 / #108): the RPE you
/// logged on each of your most recent training days (every session, manual
/// or auto-tracked), plus — for the subset that were watch/phone-tracked
/// with attempts — work-to-rest density and (on demand, it needs the raw HR
/// traces) how fast HR recovers in the minute after a climb.
export default function WorkoutStatsCard({ sessions }: { sessions: Session[] }) {
  const realtimeVersion = useRealtimeVersion();
  const workouts = useCancellableFetch<WorkoutDetail[]>(
    () => fetchRecentWorkoutDetails(8),
    [],
    realtimeVersion,
  );
  // HR recovery is fetched on demand: it needs each workout's raw trace.
  const [hrDrops, setHrDrops] = useState<Map<string, number | null> | null>(null);
  const [hrLoading, setHrLoading] = useState(false);

  // RPE by day (#108): reads straight off every logged session, so a
  // manually-logged past workout (no climb_workouts/attempts row) still
  // shows up here even though it's excluded from the attempts-only rows
  // below.
  const rpeRows = recentDailyRpe(sessions, 8);

  const withAttempts = workouts.filter((w) => w.attempts.length > 0);
  // Oldest → newest so the trend reads left-to-right/top-to-bottom in time.
  const ordered = [...withAttempts].reverse();
  const stats = ordered.map((w) => ({
    w,
    ratio: workRestRatio(w.attempts),
  }));

  if (rpeRows.length === 0 && ordered.length === 0) return null;

  async function loadHrRecovery() {
    setHrLoading(true);
    try {
      const entries = await Promise.all(
        ordered.map(async (w) => {
          const raw = await fetchWorkoutRaw(w.id);
          return [
            w.id,
            raw ? hrRecoveryBpm(raw, w.startedAt, w.attempts) : null,
          ] as const;
        }),
      );
      setHrDrops(new Map(entries));
    } finally {
      setHrLoading(false);
    }
  }

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="label-eyebrow" style={{ marginBottom: 10 }}>
        Session stats
      </div>

      {rpeRows.length > 0 && (
        <>
          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", marginBottom: 4, fontWeight: 600 }}>
            SESSION RPE
          </div>
          <BarTrend
            rows={rpeRows.map((r) => ({ label: dateLabel(r.date), value: r.rpe }))}
            color="var(--warning)"
            fmt={(v) => v.toFixed(1)}
          />
        </>
      )}

      {ordered.length > 0 && (
        <>
          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", margin: "12px 0 4px", fontWeight: 600 }}>
            WORK : REST (climb time ÷ rest time)
          </div>
          <BarTrend
            rows={stats.map((s) => ({ label: dayLabel(s.w.startedAt), value: s.ratio }))}
            color="var(--primary)"
            fmt={(v) => v.toFixed(2)}
          />

          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", margin: "12px 0 4px", fontWeight: 600 }}>
            HR RECOVERY (60s AFTER A CLIMB)
          </div>
          {hrDrops === null ? (
            <button
              className="btn-ghost"
              disabled={hrLoading}
              onClick={() => void loadHrRecovery()}
            >
              {hrLoading ? "Crunching HR traces…" : "Load HR recovery"}
            </button>
          ) : (
            <BarTrend
              rows={ordered.map((w) => ({
                label: dayLabel(w.startedAt),
                value: hrDrops.get(w.id) ?? null,
              }))}
              color="var(--danger)"
              fmt={(v) => `${Math.round(v)} bpm`}
            />
          )}
        </>
      )}
    </div>
  );
}
