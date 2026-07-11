import { useState } from "react";
import { PHASES } from "../constants";
import { fetchWorkoutForSession } from "../lib/repo";
import type { Session, WorkoutDetail } from "../types";
import WorkoutDetailPanel from "./WorkoutDetailPanel";

interface Props {
  s: Session;
  onDelete: (id: string) => void;
}

export default function SessionRow({ s, onDelete }: Props) {
  const ph = PHASES.find((p) => p.id === s.phase);
  const isAuto = s.type === "auto";
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState<WorkoutDetail | null | "missing">(null);
  const [loadError, setLoadError] = useState(false);

  async function toggle() {
    if (!isAuto) return;
    const next = !expanded;
    setExpanded(next);
    if (next && detail === null && !loadError) {
      try {
        const d = await fetchWorkoutForSession(s.id);
        setDetail(d ?? "missing");
      } catch {
        setLoadError(true);
      }
    }
  }

  return (
    <div
      className="session-row"
      style={{
        flexDirection: "column",
        alignItems: "stretch",
        gap: 0,
        cursor: isAuto ? "pointer" : undefined,
      }}
      onClick={() => void toggle()}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div
          className="session-phase-bar"
          style={{ background: ph?.color || "#334155" }}
        />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div
            style={{
              display: "flex",
              gap: 7,
              alignItems: "center",
              marginBottom: 4,
              flexWrap: "wrap",
            }}
          >
            <span style={{ fontSize: 13, color: "#e2e8f0" }}>
              {s.typeLabel}
            </span>
            <span
              className="tag"
              style={{
                background: ph?.bg || "#1e2d40",
                color: ph?.color || "#7a8a9a",
                border: `1px solid ${ph?.border || "#1e2d40"}`,
              }}
            >
              {ph?.name || s.phase}
            </span>
            {isAuto && (
              <span style={{ fontSize: 10, color: "#4a5a70" }}>
                {expanded ? "▾" : "▸"}
              </span>
            )}
          </div>
          <div style={{ fontSize: 11, color: "#4a5a70" }}>
            {s.date} · {s.duration}min · RPE {s.rpe} ·{" "}
            <span style={{ color: "#7a8a9a" }}>{s.load} AU</span>
          </div>
          {s.note && (
            <div style={{ fontSize: 11, color: "#3a4a60", marginTop: 3 }}>
              {s.note}
            </div>
          )}
        </div>
        <button
          className="del-btn"
          onClick={(e) => {
            e.stopPropagation();
            onDelete(s.id);
          }}
        >
          ×
        </button>
      </div>

      {expanded && (
        <>
          {detail === null && !loadError && (
            <div style={{ fontSize: 10, color: "#3a4a60", marginTop: 8 }}>
              Loading workout…
            </div>
          )}
          {loadError && (
            <div style={{ fontSize: 10, color: "#f87171", marginTop: 8 }}>
              Failed to load workout
            </div>
          )}
          {detail === "missing" && (
            <div style={{ fontSize: 10, color: "#3a4a60", marginTop: 8 }}>
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
