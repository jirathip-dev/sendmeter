import { useEffect, useState } from "react";
import { PHASES } from "../constants";
import {
  useRealtimeBump,
  useRealtimeVersion,
} from "../hooks/useRealtimeVersion";
import {
  deleteRecording,
  fetchRecordingsByGroup,
  fetchWorkoutForSession,
  recalcTindeqSessionDuration,
} from "../lib/repo";
import type { Session, TindeqRecordingMeta, WorkoutDetail } from "../types";
import EditRecordingSheet from "./EditRecordingSheet";
import RecordingRow from "./RecordingRow";
import Sheet from "./Sheet";
import WorkoutDetailPanel from "./WorkoutDetailPanel";

interface Props {
  s: Session;
  onDelete: (id: string) => void;
  onEdit?: (s: Session) => void;
}

/// One collapsible section per exercise tag inside a Tindeq session's detail
/// page — a high-rep session (dozens of reps across exercises) reads as a few
/// summary lines instead of an endless list.
function TagGroup({
  tag,
  recs,
  onEditRec,
  onDeleteRec,
}: {
  tag: string;
  recs: TindeqRecordingMeta[];
  onEditRec: (r: TindeqRecordingMeta) => void;
  onDeleteRec: (id: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const best = Math.max(...recs.map((r) => r.peakKg));
  return (
    <div style={{ marginBottom: 8 }}>
      <button
        onClick={() => setOpen((v) => !v)}
        style={{
          width: "100%",
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "10px 12px",
          borderRadius: 9,
          border: "1px solid var(--border)",
          background: "var(--surface-1)",
          fontFamily: "inherit",
          cursor: "pointer",
          textAlign: "left",
        }}
      >
        <span style={{ fontSize: "var(--t-base)", fontWeight: 700, color: "var(--ink)", flex: 1 }}>
          {tag || "untagged"}
        </span>
        <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
          {recs.length} rep{recs.length === 1 ? "" : "s"} · best{" "}
          <span style={{ color: "var(--success)", fontWeight: 700 }}>
            {best.toFixed(1)} kg
          </span>
        </span>
        <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
          {open ? "▾" : "▸"}
        </span>
      </button>
      {open && (
        <div style={{ marginTop: 6 }}>
          {recs.map((r) => (
            <RecordingRow
              key={r.id}
              rec={r}
              onEdit={onEditRec}
              onDelete={onDeleteRec}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export default function SessionRow({ s, onDelete, onEdit }: Props) {
  const ph = PHASES.find((p) => p.id === s.phase);
  // workoutSource (not type) marks a device workout — it survives type edits
  // (SL-43), so an auto-tracked session re-typed to "Board" still expands.
  const isWorkout = s.workoutSource !== null;
  const isTindeq = s.type === "tindeq" && s.groupId !== null;
  const expandable = isWorkout || isTindeq;
  // Detail opens as its OWN full-height page (sheet) instead of expanding
  // inline — long sessions were unmanageable inside the timeline (SL-86).
  const [detailOpen, setDetailOpen] = useState(false);
  const [detail, setDetail] = useState<WorkoutDetail | null | "missing">(null);
  const [tindeqRecs, setTindeqRecs] = useState<TindeqRecordingMeta[] | null>(
    null,
  );
  const [editingRec, setEditingRec] = useState<TindeqRecordingMeta | null>(null);
  const [loadError, setLoadError] = useState(false);

  async function open() {
    if (!expandable) return;
    setDetailOpen(true);
    if (loadError) return;
    // Always refetch on open (not just when the cache is empty) so a recording
    // assigned into this group while it was closed shows on re-open.
    try {
      if (isWorkout) {
        const d = await fetchWorkoutForSession(s.id);
        setDetail(d ?? "missing");
      } else if (isTindeq) {
        setTindeqRecs(await fetchRecordingsByGroup(s.groupId!));
      }
    } catch {
      setLoadError(true);
    }
  }

  // Refetch the open detail when data changes elsewhere (e.g. a recording
  // assigned into this session's group, or a watch write).
  const realtimeVersion = useRealtimeVersion();
  const bumpRealtime = useRealtimeBump();
  useEffect(() => {
    if (!detailOpen) return;
    let cancelled = false;
    void (async () => {
      try {
        if (isWorkout) {
          const d = await fetchWorkoutForSession(s.id);
          if (!cancelled) setDetail(d ?? "missing");
        } else if (isTindeq) {
          const recs = await fetchRecordingsByGroup(s.groupId!);
          if (!cancelled) setTindeqRecs(recs);
        }
      } catch {
        /* keep the stale view rather than flashing an error */
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [realtimeVersion]);

  // Recordings grouped by tag, preserving first-seen order.
  const tagGroups: { tag: string; recs: TindeqRecordingMeta[] }[] = [];
  for (const r of tindeqRecs ?? []) {
    const g = tagGroups.find((x) => x.tag === r.tag);
    if (g) g.recs.push(r);
    else tagGroups.push({ tag: r.tag, recs: [r] });
  }

  function deleteRec(id: string) {
    setTindeqRecs((list) => (list ? list.filter((x) => x.id !== id) : list));
    // Removing a rep shrinks the session's span — recompute its total time,
    // then bump so the header duration/load refresh.
    void (async () => {
      await deleteRecording(id);
      if (s.groupId) await recalcTindeqSessionDuration(s.groupId);
      bumpRealtime();
    })();
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
      onClick={() => void open()}
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
            <span style={{ fontSize: "var(--t-base)", color: "var(--ink)" }}>
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
              <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
                ›
              </span>
            )}
          </div>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
            {s.date} · {s.duration}min · RPE {s.rpe} ·{" "}
            <span style={{ color: "var(--ink-muted)" }}>{s.load} AU</span>
          </div>
          {s.note && (
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", marginTop: 3 }}>
              {s.note}
            </div>
          )}
        </div>
        {onEdit && (
          <button
            className="del-btn"
            aria-label="Edit session"
            style={{ fontSize: "var(--t-base)" }}
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

      {/* The session's own page — detail charts + recordings live here */}
      {detailOpen && (
        <div onClick={(e) => e.stopPropagation()} style={{ cursor: "default" }}>
          <Sheet fullHeight onClose={() => setDetailOpen(false)}>
            <div style={{ fontFamily: "Inter, sans-serif", fontSize: "var(--t-xl)", fontWeight: 800 }}>
              {s.typeLabel}
            </div>
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", margin: "2px 0 10px" }}>
              {s.date} · {s.duration}min · RPE {s.rpe} · {s.load} AU
              {s.note ? ` · ${s.note}` : ""}
            </div>

            {isWorkout && (
              <>
                {detail === null && !loadError && (
                  <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
                    Loading workout…
                  </div>
                )}
                {loadError && (
                  <div style={{ fontSize: "var(--t-2xs)", color: "var(--danger)" }}>
                    Failed to load workout
                  </div>
                )}
                {detail === "missing" && (
                  <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
                    No workout data
                  </div>
                )}
                {detail !== null && detail !== "missing" && (
                  <WorkoutDetailPanel detail={detail} />
                )}
              </>
            )}

            {isTindeq && (
              <>
                {tindeqRecs === null && !loadError && (
                  <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
                    Loading recordings…
                  </div>
                )}
                {loadError && (
                  <div style={{ fontSize: "var(--t-2xs)", color: "var(--danger)" }}>
                    Failed to load recordings
                  </div>
                )}
                {tindeqRecs !== null && tindeqRecs.length === 0 && (
                  <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
                    No recordings in this session
                  </div>
                )}
                {tagGroups.map((g) => (
                  <TagGroup
                    key={g.tag || "untagged"}
                    tag={g.tag}
                    recs={g.recs}
                    onEditRec={setEditingRec}
                    onDeleteRec={deleteRec}
                  />
                ))}
              </>
            )}
          </Sheet>
        </div>
      )}

      {editingRec && (
        <EditRecordingSheet
          rec={editingRec}
          runSiblings={
            editingRec.protocolRunId
              ? (tindeqRecs ?? []).filter(
                  (r) => r.protocolRunId === editingRec.protocolRunId,
                )
              : []
          }
          recentTags={[...new Set((tindeqRecs ?? []).map((r) => r.tag).filter(Boolean))]}
          onSaved={(saved) =>
            setTindeqRecs((list) => {
              if (!list) return list;
              const byId = new Map(saved.map((r) => [r.id, r]));
              return list.map((x) => byId.get(x.id) ?? x);
            })
          }
          onClose={() => setEditingRec(null)}
        />
      )}
    </div>
  );
}
