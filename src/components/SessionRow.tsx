import { useState } from "react";
import { PHASES } from "../constants";
import { fetchRecordingsByGroup, fetchWorkoutForSession } from "../lib/repo";
import type { Session, TindeqRecordingMeta, WorkoutDetail } from "../types";
import WorkoutDetailPanel from "./WorkoutDetailPanel";

interface Props {
  s: Session;
  onDelete: (id: string) => void;
}

function sideLabel(side: TindeqRecordingMeta["side"]): string {
  return side === "both" ? "L+R" : side === "left" ? "L" : side === "right" ? "R" : "";
}

export default function SessionRow({ s, onDelete }: Props) {
  const ph = PHASES.find((p) => p.id === s.phase);
  const isAuto = s.type === "auto";
  const isTindeq = s.type === "tindeq" && s.groupId !== null;
  const expandable = isAuto || isTindeq;
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState<WorkoutDetail | null | "missing">(null);
  const [tindeqRecs, setTindeqRecs] = useState<TindeqRecordingMeta[] | null>(
    null,
  );
  const [loadError, setLoadError] = useState(false);

  async function toggle() {
    if (!expandable) return;
    const next = !expanded;
    setExpanded(next);
    if (!next || loadError) return;
    try {
      if (isAuto && detail === null) {
        const d = await fetchWorkoutForSession(s.id);
        setDetail(d ?? "missing");
      } else if (isTindeq && tindeqRecs === null) {
        setTindeqRecs(await fetchRecordingsByGroup(s.groupId!));
      }
    } catch {
      setLoadError(true);
    }
  }

  return (
    <div
      className="session-row"
      style={{
        flexDirection: "column",
        alignItems: "stretch",
        gap: 0,
        cursor: expandable ? "pointer" : undefined,
      }}
      onClick={() => void toggle()}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div
          className="session-phase-bar"
          style={{ background: ph?.color || "#C7C7CC" }}
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
            <span style={{ fontSize: 13, color: "#1C1C1E" }}>
              {s.typeLabel}
            </span>
            <span
              className="tag"
              style={{
                background: ph?.bg || "#D8D8DC",
                color: ph?.color || "#6E6E73",
                border: `1px solid ${ph?.border || "#D8D8DC"}`,
              }}
            >
              {ph?.name || s.phase}
            </span>
            {expandable && (
              <span style={{ fontSize: 10, color: "#6E6E73" }}>
                {expanded ? "▾" : "▸"}
              </span>
            )}
          </div>
          <div style={{ fontSize: 11, color: "#6E6E73" }}>
            {s.date} · {s.duration}min · RPE {s.rpe} ·{" "}
            <span style={{ color: "#6E6E73" }}>{s.load} AU</span>
          </div>
          {s.note && (
            <div style={{ fontSize: 11, color: "#8E8E93", marginTop: 3 }}>
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

      {expanded && isAuto && (
        <>
          {detail === null && !loadError && (
            <div style={{ fontSize: 10, color: "#8E8E93", marginTop: 8 }}>
              Loading workout…
            </div>
          )}
          {loadError && (
            <div style={{ fontSize: 10, color: "#FF453A", marginTop: 8 }}>
              Failed to load workout
            </div>
          )}
          {detail === "missing" && (
            <div style={{ fontSize: 10, color: "#8E8E93", marginTop: 8 }}>
              No workout data
            </div>
          )}
          {detail !== null && detail !== "missing" && (
            <WorkoutDetailPanel detail={detail} />
          )}
        </>
      )}

      {expanded && isTindeq && (
        <div
          style={{
            marginTop: 10,
            paddingTop: 10,
            borderTop: "1px solid #E5E5EA",
          }}
        >
          {tindeqRecs === null && !loadError && (
            <div style={{ fontSize: 10, color: "#8E8E93" }}>
              Loading recordings…
            </div>
          )}
          {loadError && (
            <div style={{ fontSize: 10, color: "#FF453A" }}>
              Failed to load recordings
            </div>
          )}
          {tindeqRecs !== null && tindeqRecs.length === 0 && (
            <div style={{ fontSize: 10, color: "#8E8E93" }}>
              No recordings in this session
            </div>
          )}
          {tindeqRecs?.map((r) => (
            <div
              key={r.id}
              style={{
                display: "flex",
                justifyContent: "space-between",
                gap: 8,
                fontSize: 11,
                color: "#6E6E73",
                marginBottom: 4,
              }}
            >
              <span style={{ color: "#6E6E73" }}>
                {new Date(r.recordedAt).toLocaleTimeString([], {
                  hour: "2-digit",
                  minute: "2-digit",
                })}
                {r.tag && <span style={{ color: "#7B83EB" }}> {r.tag}</span>}
                {r.side && (
                  <span style={{ color: "#FFB800" }}> {sideLabel(r.side)}</span>
                )}
              </span>
              <span>
                <span style={{ color: "#34C759" }}>{r.peakKg.toFixed(1)}kg</span>{" "}
                · {(r.durationMs / 1000).toFixed(0)}s
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
