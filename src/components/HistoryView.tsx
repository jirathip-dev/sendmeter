import { useState } from "react";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import {
  useRealtimeBump,
  useRealtimeVersion,
} from "../hooks/useRealtimeVersion";
import {
  deleteRecording,
  fetchRecordings,
  insertTindeqSession,
  updateRecordingGroup,
} from "../lib/repo";
import type { PhaseId, Session, TindeqRecordingMeta } from "../types";
import RecordingRow from "./RecordingRow";
import SessionRow from "./SessionRow";

interface Props {
  sessions: Session[];
  currentPhase: PhaseId;
  onDelete: (id: string) => void;
  onEdit: (s: Session) => void;
  onOpenTrash: () => void;
}

type TimelineItem =
  | { kind: "session"; key: string; sortKey: string; s: Session }
  | { kind: "recording"; key: string; sortKey: string; rec: TindeqRecordingMeta };

/// History is the single combined timeline: every session (workouts expand
/// to stats + HR chart; Tindeq sessions expand to full recording charts)
/// plus ungrouped Tindeq recordings interleaved by date.
export default function HistoryView({
  sessions,
  currentPhase,
  onDelete,
  onEdit,
  onOpenTrash,
}: Props) {
  const realtimeVersion = useRealtimeVersion();
  const bumpRealtime = useRealtimeBump();
  const [removedIds, setRemovedIds] = useState<Set<string>>(new Set());
  const [assignedIds, setAssignedIds] = useState<Set<string>>(new Set());
  // Multi-select of loose recordings → one new session.
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [creating, setCreating] = useState(false);

  const allRecordings = useCancellableFetch<TindeqRecordingMeta[]>(
    fetchRecordings,
    [],
    realtimeVersion,
  );
  // Optimistic local hides (delete/assign) until the realtime refetch lands.
  const ungrouped = allRecordings.filter(
    (r) => r.groupId === null && !removedIds.has(r.id) && !assignedIds.has(r.id),
  );

  const total = sessions.reduce((s, x) => s + x.load, 0);

  function toggleSelect(id: string) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  // Group the ticked recordings under a new session: the session takes the
  // recordings' own date and time span; RPE defaults to 5 (editable via the
  // pencil afterwards).
  async function createSessionFromSelection() {
    const recs = ungrouped
      .filter((r) => selectedIds.has(r.id))
      .sort((a, b) => a.recordedAt.localeCompare(b.recordedAt));
    if (recs.length === 0) return;
    setCreating(true);
    try {
      const groupId = crypto.randomUUID();
      for (const r of recs) {
        await updateRecordingGroup(r.id, groupId);
      }
      const first = recs[0]!;
      const last = recs[recs.length - 1]!;
      const spanMs =
        Date.parse(last.recordedAt) + last.durationMs - Date.parse(first.recordedAt);
      const tags = [...new Set(recs.map((r) => r.tag).filter(Boolean))];
      await insertTindeqSession({
        durationMin: Math.max(1, Math.round(spanMs / 60000)),
        rpe: 5,
        phase: currentPhase,
        note: [
          `${recs.length} recording${recs.length === 1 ? "" : "s"}`,
          ...(tags.length ? [tags.join(", ")] : []),
        ].join(" · "),
        groupId,
        date: first.recordedAt.slice(0, 10),
      });
      setAssignedIds((prev) => {
        const next = new Set(prev);
        for (const r of recs) next.add(r.id);
        return next;
      });
      setSelectedIds(new Set());
      bumpRealtime(); // refresh sessions + recordings everywhere
    } finally {
      setCreating(false);
    }
  }

  // Interleave: sessions carry a date (YYYY-MM-DD); recordings a timestamp.
  // Sort by date desc; same-day sessions come before loose recordings.
  const items: TimelineItem[] = [
    ...sessions.map((s) => ({
      kind: "session" as const,
      key: `s-${s.id}`,
      sortKey: `${s.date}~1`,
      s,
    })),
    ...ungrouped.map((rec) => ({
      kind: "recording" as const,
      key: `r-${rec.id}`,
      sortKey: `${rec.recordedAt.slice(0, 10)}~0`,
      rec,
    })),
  ].sort((a, b) => b.sortKey.localeCompare(a.sortKey));

  return (
    <div>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
        }}
      >
        <div className="section-head">HISTORY</div>
        <button className="header-btn" onClick={onOpenTrash}>
          Trash
        </button>
      </div>
      <div className="section-sub">
        {sessions.length} sessions · {total.toLocaleString()} AU total
        {ungrouped.length > 0 &&
          ` · ${ungrouped.length} loose recording${ungrouped.length === 1 ? "" : "s"}`}
      </div>
      {items.length === 0 && (
        <div
          style={{
            textAlign: "center",
            color: "var(--ink-faint)",
            fontSize: 13,
            padding: "60px 0",
          }}
        >
          No sessions yet.
        </div>
      )}
      {items.map((it) =>
        it.kind === "session" ? (
          <SessionRow key={it.key} s={it.s} onDelete={onDelete} onEdit={onEdit} />
        ) : (
          <RecordingRow
            key={it.key}
            rec={it.rec}
            onDelete={(id) => {
              setRemovedIds((prev) => new Set(prev).add(id));
              void deleteRecording(id);
            }}
            selectable
            selected={selectedIds.has(it.rec.id)}
            onToggleSelect={toggleSelect}
          />
        ),
      )}

      {/* Floating glass action bar while loose recordings are ticked */}
      {selectedIds.size > 0 && (
        <div className="glass-bar">
          <button
            className="btn-primary"
            disabled={creating}
            onClick={() => void createSessionFromSelection()}
            style={{ flex: 2 }}
          >
            {creating
              ? "Creating…"
              : `Create session (${selectedIds.size})`}
          </button>
          <button
            className="btn-ghost"
            disabled={creating}
            onClick={() => setSelectedIds(new Set())}
            style={{ flex: 1 }}
          >
            Cancel
          </button>
        </div>
      )}

    </div>
  );
}
