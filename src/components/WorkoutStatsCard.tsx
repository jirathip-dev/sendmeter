import { useState } from "react";
import { fetchRecentWorkoutDetails, fetchWorkoutRaw } from "../lib/repo";
import { climbRestStats, hrRecoveryBpm } from "../lib/workoutStats";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import type { WorkoutDetail } from "../types";

function fmtS(s: number): string {
  return s >= 90 ? `${(s / 60).toFixed(1)}m` : `${Math.round(s)}s`;
}

function dayLabel(iso: string): string {
  const d = new Date(iso);
  return `${d.getMonth() + 1}/${d.getDate()}`;
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

/// Summary stats across recent workouts (SL-85): average climb time, average
/// rest between boulders, and (on demand — it needs the raw HR traces) how
/// fast HR recovers in the minute after each climb.
export default function WorkoutStatsCard() {
  const realtimeVersion = useRealtimeVersion();
  const workouts = useCancellableFetch<WorkoutDetail[]>(
    () => fetchRecentWorkoutDetails(8),
    [],
    realtimeVersion,
  );
  // HR recovery is fetched on demand: it needs each workout's raw trace.
  const [hrDrops, setHrDrops] = useState<Map<string, number | null> | null>(null);
  const [hrLoading, setHrLoading] = useState(false);

  const withAttempts = workouts.filter((w) => w.attempts.length > 0);
  if (withAttempts.length === 0) return null;

  // Oldest → newest so the trend reads left-to-right/top-to-bottom in time.
  const ordered = [...withAttempts].reverse();
  const stats = ordered.map((w) => ({ w, ...climbRestStats(w.attempts) }));

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
        Session stats · last {ordered.length} workouts
      </div>

      <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", marginBottom: 4, fontWeight: 600 }}>
        AVG CLIMB TIME
      </div>
      <BarTrend
        rows={stats.map((s) => ({ label: dayLabel(s.w.startedAt), value: s.avgClimbS }))}
        color="var(--success)"
        fmt={fmtS}
      />

      <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", margin: "12px 0 4px", fontWeight: 600 }}>
        AVG REST BETWEEN CLIMBS
      </div>
      <BarTrend
        rows={stats.map((s) => ({ label: dayLabel(s.w.startedAt), value: s.avgRestS }))}
        color="var(--primary)"
        fmt={fmtS}
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
    </div>
  );
}
