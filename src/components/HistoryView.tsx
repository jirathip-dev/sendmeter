import { useState, type CSSProperties } from "react";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import {
  deleteRecording,
  fetchRecordings,
  updateRecordingGroup,
} from "../lib/repo";
import type { Session, TindeqRecordingMeta } from "../types";
import AssignRecordingSheet from "./AssignRecordingSheet";
import RecordingRow from "./RecordingRow";
import RpeScatterCard from "./RpeScatterCard";
import SessionRow from "./SessionRow";
import Sheet from "./Sheet";

interface Props {
  sessions: Session[];
  onDelete: (id: string) => void;
  onEdit: (s: Session) => void;
  onOpenTrash: () => void;
}

const HEADER_BTN_STYLE: CSSProperties = {
  background: "none",
  border: "none",
  color: "var(--ink-faint)",
  fontSize: 9,
  textTransform: "uppercase",
  letterSpacing: "0.08em",
  cursor: "pointer",
  padding: 4,
  fontFamily: "Inter, sans-serif",
};

type TimelineItem =
  | { kind: "session"; key: string; sortKey: string; s: Session }
  | { kind: "recording"; key: string; sortKey: string; rec: TindeqRecordingMeta };

/// History is the single combined timeline: every session (workouts expand
/// to stats + HR chart; Tindeq sessions expand to full recording charts)
/// plus ungrouped Tindeq recordings interleaved by date.
export default function HistoryView({
  sessions,
  onDelete,
  onEdit,
  onOpenTrash,
}: Props) {
  const [showRpeModel, setShowRpeModel] = useState(false);
  const [assigning, setAssigning] = useState<TindeqRecordingMeta | null>(null);
  const realtimeVersion = useRealtimeVersion();
  const [removedIds, setRemovedIds] = useState<Set<string>>(new Set());
  const [assignedIds, setAssignedIds] = useState<Set<string>>(new Set());

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
        <div style={{ display: "flex", gap: 4 }}>
          <button style={HEADER_BTN_STYLE} onClick={() => setShowRpeModel(true)}>
            RPE Model
          </button>
          <button style={HEADER_BTN_STYLE} onClick={onOpenTrash}>
            Trash
          </button>
        </div>
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
            onAssign={setAssigning}
          />
        ),
      )}

      {assigning && (
        <AssignRecordingSheet
          recording={assigning}
          recordings={allRecordings}
          onAssign={(groupId) => {
            const id = assigning.id;
            setAssignedIds((prev) => new Set(prev).add(id));
            void updateRecordingGroup(id, groupId);
          }}
          onClose={() => setAssigning(null)}
        />
      )}

      {showRpeModel && (
        <Sheet onClose={() => setShowRpeModel(false)}>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 20,
              fontWeight: 800,
              marginBottom: 12,
            }}
          >
            RPE Model
          </div>
          <RpeScatterCard />
          <div style={{ marginTop: 12 }}>
            <button className="btn-ghost" onClick={() => setShowRpeModel(false)}>
              Close
            </button>
          </div>
        </Sheet>
      )}
    </div>
  );
}
