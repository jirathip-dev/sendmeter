import { useState } from "react";
import { fetchWorkoutById } from "../lib/repo";
import type { WorkoutDetail, WorkoutListItem } from "../types";
import WorkoutDetailPanel from "./WorkoutDetailPanel";

interface Props {
  w: WorkoutListItem;
}

function fmtDateTime(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/// One row in the Workout tab's recent-workouts list; expands to the full
/// WorkoutDetailPanel (stats + HR chart + attempt bars), lazy-loaded.
export default function WorkoutRow({ w }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState<WorkoutDetail | null | "missing">(null);
  const [loadError, setLoadError] = useState(false);

  const durationMin = Math.round(
    (new Date(w.endedAt).getTime() - new Date(w.startedAt).getTime()) / 60000,
  );

  async function toggle() {
    const next = !expanded;
    setExpanded(next);
    if (!next || loadError || detail !== null) return;
    try {
      setDetail((await fetchWorkoutById(w.id)) ?? "missing");
    } catch {
      setLoadError(true);
    }
  }

  return (
    <div
      className="session-row"
      style={{ flexDirection: "column", alignItems: "stretch", gap: 0, cursor: "pointer" }}
      onClick={() => void toggle()}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div className="session-phase-bar" style={{ background: "var(--success)" }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", gap: 7, alignItems: "center", marginBottom: 4, flexWrap: "wrap" }}>
            <span style={{ fontSize: 13, color: "var(--ink)" }}>
              {w.source === "watch" ? "Auto-tracked" : "Phone workout"}
            </span>
            <span
              className="tag"
              style={{
                background: "transparent",
                color: "var(--ink-faint)",
                border: "1px solid var(--border)",
              }}
            >
              {w.source === "watch" ? "AUTO" : "PHONE"}
            </span>
            <span style={{ fontSize: 10, color: "var(--ink-muted)" }}>
              {expanded ? "▾" : "▸"}
            </span>
          </div>
          <div style={{ fontSize: 11, color: "var(--ink-muted)" }}>
            {fmtDateTime(w.startedAt)} · {durationMin}min ·{" "}
            {w.attemptsConfirmed} boulder{w.attemptsConfirmed === 1 ? "" : "s"}
            {w.avgHr !== null && ` · avg ${Math.round(w.avgHr)} bpm`}
            {w.rpeConfirmed !== null && ` · RPE ${w.rpeConfirmed}`}
          </div>
        </div>
      </div>

      {expanded && (
        <>
          {detail === null && !loadError && (
            <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 8 }}>
              Loading workout…
            </div>
          )}
          {loadError && (
            <div style={{ fontSize: 10, color: "var(--danger)", marginTop: 8 }}>
              Failed to load workout
            </div>
          )}
          {detail === "missing" && (
            <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 8 }}>
              No workout data
            </div>
          )}
          {detail !== null && detail !== "missing" && (
            <WorkoutDetailPanel detail={detail} />
          )}
        </>
      )}
    </div>
  );
}
