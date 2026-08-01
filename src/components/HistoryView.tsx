import { useState } from "react";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useLiveWorkout } from "../hooks/useLiveWorkout";
import { usePendingUploads } from "../hooks/usePendingUploads";
import {
  useRealtimeBump,
  useRealtimeVersion,
} from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import { useWatchInfo } from "../hooks/useWatchInfo";
import {
  deleteRecording,
  fetchRecordings,
  insertTindeqSession,
  recalcTindeqSessionDuration,
  restoreRecording,
  updateRecordingGroup,
} from "../lib/repo";
import { dominantZone, zoneSets } from "../lib/zoneHistory";
import { captureHandledOperationalFailure } from "../lib/monitoring";
import { uploadWarningPresentation } from "../lib/watchBuild";
import type { PhaseId, Session, TindeqRecordingMeta } from "../types";
import EditRecordingSheet from "./EditRecordingSheet";
import LiveSessionRow from "./LiveSessionRow";
import RecordingRow from "./RecordingRow";
import SessionRow from "./SessionRow";
import Sheet from "./Sheet";

interface Props {
  userId: string;
  sessions: Session[];
  currentPhase: PhaseId;
  onDelete: (id: string) => void;
  onEdit: (s: Session) => void;
  onOpenTrash: () => void;
}

const PAGE_SIZE = 40;

// Fallback zone mix for a Tindeq session whose groupId has no recordings in
// `allRecordings` yet (e.g. just created) — `dominantZone` on all-zeros
// returns null, same as "no zone known".
const EMPTY_ZONE_SETS = zoneSets([]);

type TimelineItem =
  | { kind: "session"; key: string; sortKey: string; s: Session }
  | { kind: "recording"; key: string; sortKey: string; rec: TindeqRecordingMeta };

/// History is the single combined timeline: every session (workouts expand
/// to stats + HR chart; Tindeq sessions expand to full recording charts)
/// plus ungrouped Tindeq recordings interleaved by date.
export default function HistoryView({
  userId,
  sessions,
  currentPhase,
  onDelete,
  onEdit,
  onOpenTrash,
}: Props) {
  const realtimeVersion = useRealtimeVersion();
  // The in-progress watch workout, shown as a pinned live row (SL-98) so a
  // long session is visible immediately instead of only after it ends. Null
  // when nothing's live / the beat goes stale.
  const [live] = useLiveWorkout(userId);
  const bumpRealtime = useRealtimeBump();
  const toast = useToast();
  const uploadWarning = uploadWarningPresentation(
    useWatchInfo(),
    usePendingUploads(),
  );
  const [removedIds, setRemovedIds] = useState<Set<string>>(new Set());
  // Lazy render (SL-86): mount the timeline in pages.
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);
  const [assignedIds, setAssignedIds] = useState<Set<string>>(new Set());
  // Multi-select of loose recordings → one new session.
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  // Edit tag/side/note of a single recording (SL-58).
  const [editingRec, setEditingRec] = useState<TindeqRecordingMeta | null>(null);
  // Local overrides so an edit shows immediately, before the realtime refetch.
  const [editedRecs, setEditedRecs] = useState<Map<string, TindeqRecordingMeta>>(new Map());
  // "Assign to existing session" picker for the ticked recordings (SL-58).
  const [assignOpen, setAssignOpen] = useState(false);
  const [assigning, setAssigning] = useState(false);
  const [assignError, setAssignError] = useState<string | null>(null);

  const allRecordings = useCancellableFetch<TindeqRecordingMeta[]>(
    fetchRecordings,
    [],
    realtimeVersion,
  );
  // Tindeq session badge should read as the training QUALITY the session's
  // own recordings belong to (power/strength/pow-end/endurance, same
  // classification the Training-balance card uses), not the app-wide
  // "Global phase" — the two vocabularies otherwise contradict each other on
  // the same session (#214). Grouped once here (no new fetch — `allRecordings`
  // already has everything) and passed down to each Tindeq SessionRow.
  const recordingsByGroup = new Map<string, TindeqRecordingMeta[]>();
  for (const r of allRecordings) {
    if (!r.groupId) continue;
    const list = recordingsByGroup.get(r.groupId);
    if (list) list.push(r);
    else recordingsByGroup.set(r.groupId, [r]);
  }
  const zoneByGroup = new Map<string, ReturnType<typeof zoneSets>>();
  for (const [groupId, recs] of recordingsByGroup) {
    zoneByGroup.set(groupId, zoneSets(recs));
  }
  // A recording belongs to a session only if its groupId matches a session
  // that actually exists. A gauge run that was never "finished"/logged leaves
  // recordings stamped with a groupId but no session row — those are orphans,
  // not grouped, so treat them as loose (otherwise they'd show nowhere: not
  // under a session, and excluded from the loose list — the "PR missing from
  // History" bug).
  const sessionGroupIds = new Set(
    sessions.map((s) => s.groupId).filter((g): g is string => !!g),
  );
  // Optimistic local hides (delete/assign) until the realtime refetch lands,
  // and local edits (tag/side/note) applied over the fetched rows.
  const ungrouped = allRecordings
    .filter(
      (r) =>
        (r.groupId === null || !sessionGroupIds.has(r.groupId)) &&
        !removedIds.has(r.id) &&
        !assignedIds.has(r.id),
    )
    .map((r) => editedRecs.get(r.id) ?? r);

  const total = sessions.reduce((s, x) => s + x.load, 0);

  // Existing exercise tags, for the edit sheet's quick-pick chips.
  const recentTags = [
    ...new Set(allRecordings.map((r) => r.tag).filter(Boolean)),
  ];

  // Tindeq sessions the ticked recordings can be assigned into (SL-58).
  const tindeqSessions = sessions.filter(
    (s) => s.type === "tindeq" && s.groupId,
  );

  async function assignSelectionToSession(groupId: string) {
    const ids = [...selectedIds];
    if (ids.length === 0) return;
    setAssigning(true);
    setAssignError(null);
    try {
      for (const id of ids) await updateRecordingGroup(id, groupId);
      // The target session's span just grew — recompute its total time so the
      // duration/load reflect the newly-added recordings, not the stale value.
      await recalcTindeqSessionDuration(groupId);
      setAssignedIds((prev) => {
        const next = new Set(prev);
        for (const id of ids) next.add(id);
        return next;
      });
      setSelectedIds(new Set());
      setAssignOpen(false);
      bumpRealtime();
      toast(`Assigned ${ids.length} recording${ids.length === 1 ? "" : "s"}`);
    } catch (e) {
      setAssignError(e instanceof Error ? e.message : "Failed to assign");
    } finally {
      setAssigning(false);
    }
  }

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
    setCreateError(null);
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
      try {
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
      } catch (error) {
        captureHandledOperationalFailure("session.insert", error, {
          automatic: false,
        });
        throw error;
      }
      setAssignedIds((prev) => {
        const next = new Set(prev);
        for (const r of recs) next.add(r.id);
        return next;
      });
      setSelectedIds(new Set());
      bumpRealtime(); // refresh sessions + recordings everywhere
      toast("Session created from recordings");
    } catch (error) {
      setCreateError(
        error instanceof Error ? error.message : "Failed to create session",
      );
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
      {uploadWarning && (
        <div className="upload-status-banner" role="status">
          <div className="upload-status-title">{uploadWarning.title}</div>
          {uploadWarning.items.map((item) => (
            <div className="upload-status-item" key={item.source}>
              <div>{item.text}</div>
              <div className="upload-status-detail">
                {item.detail}
                {item.reportedAt !== undefined
                  ? ` Last report: ${new Date(item.reportedAt * 1000).toLocaleString()}.`
                  : ""}
              </div>
            </div>
          ))}
        </div>
      )}
      {/* Pinned live-workout row (SL-98) — outside the paginated list so it's
          always visible; disappears on its own when the workout ends. */}
      {live && <LiveSessionRow live={live} />}
      {items.length === 0 && !live && (
        <div
          style={{
            textAlign: "center",
            color: "var(--ink-faint)",
            fontSize: "var(--t-base)",
            padding: "60px 0",
          }}
        >
          No sessions yet.
        </div>
      )}
      {items.slice(0, visibleCount).map((it) =>
        it.kind === "session" ? (
          <SessionRow
            key={it.key}
            s={it.s}
            onDelete={onDelete}
            onEdit={onEdit}
            zoneMix={it.s.groupId ? zoneByGroup.get(it.s.groupId) ?? null : null}
            zone={
              it.s.groupId
                ? dominantZone(zoneByGroup.get(it.s.groupId) ?? EMPTY_ZONE_SETS)
                : null
            }
          />
        ) : (
          <RecordingRow
            key={it.key}
            rec={it.rec}
            onDelete={(id) => {
              setRemovedIds((prev) => new Set(prev).add(id));
              void deleteRecording(id);
              // Issue #143: instant delete (unchanged) + an Undo action that
              // restores the recording and drops the optimistic hide.
              toast("Recording deleted", "success", {
                label: "Undo",
                onClick: () => {
                  void restoreRecording(id);
                  setRemovedIds((prev) => {
                    const next = new Set(prev);
                    next.delete(id);
                    return next;
                  });
                },
              });
            }}
            onEdit={setEditingRec}
            selectable
            selected={selectedIds.has(it.rec.id)}
            onToggleSelect={toggleSelect}
          />
        ),
      )}

      {/* Lazy render (SL-86): a long history mounts rows in pages instead of
          all at once — expanded charts already fetch lazily per row. */}
      {items.length > visibleCount && (
        <button
          className="btn-ghost"
          style={{ marginTop: 4 }}
          onClick={() => setVisibleCount((n) => n + PAGE_SIZE)}
        >
          Load {Math.min(PAGE_SIZE, items.length - visibleCount)} more ·{" "}
          {items.length - visibleCount} older
        </button>
      )}

      {/* Floating glass action bar while loose recordings are ticked */}
      {selectedIds.size > 0 && (
        <div className="glass-bar" style={{ flexWrap: "wrap" }}>
          {createError && (
            <div
              style={{
                width: "100%",
                fontSize: "var(--t-xs)",
                color: "var(--danger)",
              }}
            >
              {createError}
            </div>
          )}
          <button
            className="btn-primary"
            disabled={creating}
            onClick={() => void createSessionFromSelection()}
            style={{ flex: 2, minWidth: 130 }}
          >
            {creating ? "Creating…" : `New session (${selectedIds.size})`}
          </button>
          {tindeqSessions.length > 0 && (
            <button
              className="btn-ghost"
              disabled={creating}
              onClick={() => setAssignOpen(true)}
              style={{ flex: 1, minWidth: 90, whiteSpace: "nowrap" }}
            >
              Assign…
            </button>
          )}
          <button
            className="btn-ghost"
            disabled={creating}
            onClick={() => setSelectedIds(new Set())}
            style={{ flex: 1, minWidth: 70 }}
          >
            Cancel
          </button>
        </div>
      )}

      {/* Edit a recording's tag/side/note — optionally the whole set/run (SL-79) */}
      {editingRec && (
        <EditRecordingSheet
          rec={editingRec}
          runSiblings={
            editingRec.protocolRunId
              ? allRecordings.filter(
                  (r) => r.protocolRunId === editingRec.protocolRunId,
                )
              : []
          }
          recentTags={recentTags}
          onSaved={(saved) => {
            setEditedRecs((prev) => {
              const next = new Map(prev);
              for (const r of saved) next.set(r.id, r);
              return next;
            });
            toast(
              saved.length === 1
                ? "Recording updated"
                : `${saved.length} recordings updated`,
            );
          }}
          onClose={() => setEditingRec(null)}
        />
      )}

      {/* Assign ticked recordings into an existing Tindeq session */}
      {assignOpen && (
        <Sheet onClose={() => setAssignOpen(false)}>
          <div style={{ fontFamily: "Inter, sans-serif", fontSize: "var(--t-xl)", fontWeight: 800, marginBottom: 2 }}>
            Assign to session
          </div>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 12 }}>
            Move {selectedIds.size} recording{selectedIds.size === 1 ? "" : "s"} into an existing Tindeq session.
          </div>
          {assignError && (
            <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginBottom: 8 }}>{assignError}</div>
          )}
          {tindeqSessions.map((s) => (
            <button
              key={s.id}
              disabled={assigning}
              onClick={() => void assignSelectionToSession(s.groupId!)}
              style={{
                display: "block",
                width: "100%",
                textAlign: "left",
                padding: "12px 14px",
                marginBottom: 8,
                background: "var(--canvas)",
                border: "1px solid var(--card-border)",
                borderRadius: 10,
                cursor: assigning ? "default" : "pointer",
                boxShadow: "var(--shadow-card)",
              }}
            >
              <div style={{ fontSize: "var(--t-base)", fontWeight: 600, color: "var(--ink)" }}>
                {s.date} · {s.duration}min · RPE {s.rpe}
              </div>
              {s.note && (
                <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 2 }}>
                  {s.note}
                </div>
              )}
            </button>
          ))}
          <div style={{ marginTop: 8 }}>
            <button className="btn-ghost" disabled={assigning} onClick={() => setAssignOpen(false)}>
              Cancel
            </button>
          </div>
        </Sheet>
      )}
    </div>
  );
}
