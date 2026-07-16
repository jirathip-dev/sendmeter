import { useState } from "react";
import { PHASES } from "../constants";
import {
  deleteRecording,
  fetchRecordingsByGroup,
  fetchWorkoutForSession,
} from "../lib/repo";
import type { Session, TindeqRecordingMeta, WorkoutDetail } from "../types";
import RecordingRow from "./RecordingRow";
import WorkoutDetailPanel from "./WorkoutDetailPanel";

interface Props {
  s: Session;
  onDelete: (id: string) => void;
  onEdit?: (s: Session) => void;
}

export default function SessionRow({ s, onDelete, onEdit }: Props) {
  const ph = PHASES.find((p) => p.id === s.phase);
  // workoutSource (not type) marks a device workout — it survives type edits
  // (SL-43), so an auto-tracked session re-typed to "Board" still expands.
  const isWorkout = s.workoutSource !== null;
  const isTindeq = s.type === "tindeq" && s.groupId !== null;
  const expandable = isWorkout || isTindeq;
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
      if (isWorkout && detail === null) {
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
          style={{ background: ph?.color || "var(--border)" }}
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
            <span style={{ fontSize: 13, color: "var(--ink)" }}>
              {s.typeLabel}
            </span>
            <span
              className="tag"
              style={{
                background: ph?.bg || "var(--border)",
                color: ph?.color || "var(--ink-muted)",
                border: `1px solid ${ph?.border || "var(--border)"}`,
              }}
            >
              {ph?.name || s.phase}
            </span>
            {/* Immutable provenance badge — survives type edits */}
            {isWorkout && (
              <span
                className="tag"
                title={
                  s.workoutSource === "watch"
                    ? "Auto-tracked by the watch"
                    : "Logged manually on the phone"
                }
                style={{
                  background: "transparent",
                  color: "var(--ink-faint)",
                  border: "1px solid var(--border)",
                }}
              >
                {s.workoutSource === "watch" ? "AUTO" : "PHONE"}
              </span>
            )}
            {expandable && (
              <span style={{ fontSize: 10, color: "var(--ink-muted)" }}>
                {expanded ? "▾" : "▸"}
              </span>
            )}
          </div>
          <div style={{ fontSize: 11, color: "var(--ink-muted)" }}>
            {s.date} · {s.duration}min · RPE {s.rpe} ·{" "}
            <span style={{ color: "var(--ink-muted)" }}>{s.load} AU</span>
          </div>
          {s.note && (
            <div style={{ fontSize: 11, color: "var(--ink-faint)", marginTop: 3 }}>
              {s.note}
            </div>
          )}
        </div>
        {onEdit && (
          <button
            className="del-btn"
            aria-label="Edit session"
            style={{ fontSize: 13 }}
            onClick={(e) => {
              e.stopPropagation();
              onEdit(s);
            }}
          >
            ✎
          </button>
        )}
        <button
          className="del-btn"
          // The pencil (when present) already carries the push-right auto
          // margin from .del-btn; a second auto margin would split the gap.
          style={onEdit ? { marginLeft: 0 } : undefined}
          onClick={(e) => {
            e.stopPropagation();
            onDelete(s.id);
          }}
        >
          ×
        </button>
      </div>

      {expanded && isWorkout && (
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

      {expanded && isTindeq && (
        <div
          // Recording rows have their own expand/collapse — don't let their
          // clicks bubble up and toggle the whole session row.
          onClick={(e) => e.stopPropagation()}
          style={{
            marginTop: 10,
            paddingTop: 10,
            borderTop: "1px solid var(--hairline)",
            cursor: "default",
          }}
        >
          {tindeqRecs === null && !loadError && (
            <div style={{ fontSize: 10, color: "var(--ink-faint)" }}>
              Loading recordings…
            </div>
          )}
          {loadError && (
            <div style={{ fontSize: 10, color: "var(--danger)" }}>
              Failed to load recordings
            </div>
          )}
          {tindeqRecs !== null && tindeqRecs.length === 0 && (
            <div style={{ fontSize: 10, color: "var(--ink-faint)" }}>
              No recordings in this session
            </div>
          )}
          {/* Full recording rows — expand each for its force-trace chart */}
          {tindeqRecs?.map((r) => (
            <RecordingRow
              key={r.id}
              rec={r}
              onDelete={(id) => {
                setTindeqRecs((list) =>
                  list ? list.filter((x) => x.id !== id) : list,
                );
                void deleteRecording(id);
              }}
            />
          ))}
        </div>
      )}
    </div>
  );
}
