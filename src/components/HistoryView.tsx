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
  fetchHiddenTags,
  fetchRecordings,
  insertTindeqSession,
  recalcTindeqSessionDuration,
  restoreRecording,
  updateRecordingGroup,
} from "../lib/repo";
import { dominantZone, zoneSets } from "../lib/zoneHistory";
import {
  historyFilterOptions,
  liveWorkoutMatchesHistoryFilters,
  looseRecordingMatchesHistoryFilters,
  sessionMatchesHistoryFilters,
  type HistoryTagFilter,
  type HistoryTypeFilter,
} from "../lib/historyFilters";
import { captureHandledOperationalFailure } from "../lib/monitoring";
import { prunePendingAssignedIds } from "../lib/assignedIds";
import { dateStr } from "../lib/dates";
import { applyRecordingEdits } from "../lib/recordingEdits";
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
  const [selectedType, setSelectedType] = useState<string | null>(null);
  const [selectedTag, setSelectedTag] = useState<string | null>(null);

  const allRecordings = useCancellableFetch<TindeqRecordingMeta[]>(
    fetchRecordings,
    [],
    realtimeVersion,
  );
  // Tags hidden in the Force tab's tag manager (SL-92) shouldn't resurface as
  // History filter chips — same pattern as ForceConsistencyCard.
  const hiddenTags = useCancellableFetch<string[]>(
    fetchHiddenTags,
    [],
    realtimeVersion,
  );
  // Tindeq session badge should read as the training QUALITY the session's
  // own recordings belong to (power/strength/pow-end/endurance, same
  // classification the Training-balance card uses), not the app-wide
  // "Global phase" — the two vocabularies otherwise contradict each other on
  // the same session (#214). Grouped once here (no new fetch — `allRecordings`
  // already has everything) and passed down to each Tindeq SessionRow.
  // Edits must feed every derived view (group membership, tag filters and
  // rows), rather than only the loose-recording row that happened to be open.
  // Only the user-editable fields (tag/side/note) come from the overlay — the
  // rest, notably `groupId`, always comes from the fresh fetch, so a later
  // grouping action isn't clobbered by a stale override (#452).
  const effectiveRecordings = applyRecordingEdits(
    allRecordings.filter((r) => !removedIds.has(r.id)),
    editedRecs,
  );
  const recordingsByGroup = new Map<string, TindeqRecordingMeta[]>();
  for (const r of effectiveRecordings) {
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
  // assignedIds only needs to hide a recording until the refetch confirms
  // its new groupId — once confirmed, drop the id so the orphan-rescue rule
  // just below regains authority if that session is later deleted.
  const pendingAssignedIds = prunePendingAssignedIds(assignedIds, allRecordings);
  if (pendingAssignedIds !== assignedIds) setAssignedIds(pendingAssignedIds);
  // Optimistic local hides (delete/assign) until the realtime refetch lands,
  // and local edits (tag/side/note) applied over the fetched rows.
  const ungrouped = effectiveRecordings
    .filter(
      (r) =>
        (r.groupId === null || !sessionGroupIds.has(r.groupId)) &&
        !pendingAssignedIds.has(r.id),
    );

  const filterOptions = historyFilterOptions(
    sessions,
    ungrouped,
    recordingsByGroup,
    hiddenTags,
    selectedType,
    selectedTag,
  );
  // The selected option can vanish (last tagged recording deleted/retagged,
  // last session of that type removed) — `filterOptions` already coerces the
  // render to "All", but the stale value must also be cleared from state, or
  // it silently re-engages the moment matching data reappears (realtime
  // insert, delete-undo, a tag edit back to the selected value).
  if (selectedType && filterOptions.activeType === null) setSelectedType(null);
  if (selectedTag && filterOptions.activeTag === null) setSelectedTag(null);
  const filteredSessions = sessions.filter((session) =>
    sessionMatchesHistoryFilters(
      session,
      recordingsByGroup,
      filterOptions.activeType,
      filterOptions.activeTag,
    ),
  );
  const filteredUngrouped = ungrouped.filter((recording) =>
    looseRecordingMatchesHistoryFilters(
      recording,
      filterOptions.activeType,
      filterOptions.activeTag,
    ),
  );
  const filteredLive =
    live &&
    liveWorkoutMatchesHistoryFilters(
      filterOptions.activeType,
      filterOptions.activeTag,
    )
      ? live
      : null;
  const total = filteredSessions.reduce((sum, session) => sum + session.load, 0);

  // Existing exercise tags, for the edit sheet's quick-pick chips.
  const recentTags = [...new Set(effectiveRecordings.map((r) => r.tag).filter(Boolean))];

  // Tindeq sessions the ticked recordings can be assigned into (SL-58).
  const tindeqSessions = sessions.filter(
    (s) => s.type === "tindeq" && s.groupId,
  );

  async function assignSelectionToSession(groupId: string) {
    // Derived exactly like createSessionFromSelection's `recs`: only visible
    // `ungrouped` rows, so a ticked-then-soft-deleted (or otherwise hidden)
    // recording is never written to and the toast count matches reality.
    const recs = ungrouped.filter((r) => selectedIds.has(r.id));
    if (recs.length === 0) return;
    setAssigning(true);
    setAssignError(null);
    try {
      for (const r of recs) await updateRecordingGroup(r.id, groupId);
      // The target session's span just grew — recompute its total time so the
      // duration/load reflect the newly-added recordings, not the stale value.
      await recalcTindeqSessionDuration(groupId);
      setAssignedIds((prev) => {
        const next = new Set(prev);
        for (const r of recs) next.add(r.id);
        return next;
      });
      setSelectedIds(new Set());
      setAssignOpen(false);
      bumpRealtime();
      toast(`Assigned ${recs.length} recording${recs.length === 1 ? "" : "s"}`);
    } catch (e) {
      setAssignError(e instanceof Error ? e.message : "Failed to assign");
    } finally {
      setAssigning(false);
    }
  }

  // A filter change can hide a ticked recording without unticking it — prune
  // the selection to what the new filter still shows, so a bulk action never
  // silently includes a row the user can no longer see.
  function pruneSelectionToVisible(type: HistoryTypeFilter, tag: HistoryTagFilter) {
    setSelectedIds((prev) => {
      if (prev.size === 0) return prev;
      const visible = new Set(
        ungrouped
          .filter((r) => looseRecordingMatchesHistoryFilters(r, type, tag))
          .map((r) => r.id),
      );
      const next = new Set([...prev].filter((id) => visible.has(id)));
      return next.size === prev.size ? prev : next;
    });
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
          date: dateStr(new Date(first.recordedAt)),
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
    ...filteredSessions.map((s) => ({
      kind: "session" as const,
      key: `s-${s.id}`,
      sortKey: `${s.date}~1`,
      s,
    })),
    ...filteredUngrouped.map((rec) => ({
      kind: "recording" as const,
      key: `r-${rec.id}`,
      sortKey: `${dateStr(new Date(rec.recordedAt))}~0`,
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
        {filteredSessions.length} sessions · {total.toLocaleString()} AU total
        {filteredUngrouped.length > 0 &&
          ` · ${filteredUngrouped.length} loose recording${filteredUngrouped.length === 1 ? "" : "s"}`}
      </div>
      {filterOptions.types.length > 0 && (
        <HistoryFilterRow
          label="Session type"
          allLabel="All types"
          value={filterOptions.activeType}
          options={filterOptions.types.map((option) => ({
            value: option.id,
            label: option.label,
          }))}
          onChange={(value) => {
            setSelectedType(value);
            setVisibleCount(PAGE_SIZE);
            pruneSelectionToVisible(value, filterOptions.activeTag);
          }}
        />
      )}
      {filterOptions.tags.length > 0 && (
        <HistoryFilterRow
          label="Force tag"
          allLabel="All tags"
          value={filterOptions.activeTag}
          options={filterOptions.tags.map((tag) => ({ value: tag, label: tag }))}
          onChange={(value) => {
            setSelectedTag(value);
            setVisibleCount(PAGE_SIZE);
            pruneSelectionToVisible(filterOptions.activeType, value);
          }}
        />
      )}
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
      {filteredLive && <LiveSessionRow live={filteredLive} />}
      {items.length === 0 &&
        (!filteredLive || sessions.length > 0 || ungrouped.length > 0) && (
        <div
          style={{
            textAlign: "center",
            color: "var(--ink-faint)",
            fontSize: "var(--t-base)",
            padding: "60px 0",
          }}
        >
          {sessions.length === 0 && ungrouped.length === 0
            ? "No sessions yet."
            : "No history matches these filters."}
        </div>
        )}
      {items.slice(0, visibleCount).map((it) =>
        it.kind === "session" ? (
          <SessionRow
            key={it.key}
            s={it.s}
            onDelete={onDelete}
            onEdit={onEdit}
            onRecordingsSaved={(saved) => {
              setEditedRecs((prev) => {
                const next = new Map(prev);
                for (const recording of saved) next.set(recording.id, recording);
                return next;
              });
            }}
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
              // A ticked recording that gets deleted must drop out of the
              // action-bar count immediately; it stays un-ticked on
              // undo-restore (simplest is an unconditional delete here).
              setSelectedIds((prev) => {
                if (!prev.has(id)) return prev;
                const next = new Set(prev);
                next.delete(id);
                return next;
              });
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

function HistoryFilterRow({
  label,
  allLabel,
  value,
  options,
  onChange,
}: {
  label: string;
  allLabel: string;
  value: string | null;
  options: { value: string; label: string }[];
  onChange: (value: string | null) => void;
}) {
  return (
    <div style={{ marginBottom: 10 }}>
      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 5 }}>
        {label}
      </div>
      <div className="chip-scroll" role="group" aria-label={label} style={{ display: "flex", gap: 6, overflowX: "auto" }}>
        <FilterButton active={value === null} onClick={() => onChange(null)}>
          {allLabel}
        </FilterButton>
        {options.map((option) => (
          <FilterButton
            key={option.value}
            active={value === option.value}
            onClick={() => onChange(option.value)}
          >
            {option.label}
          </FilterButton>
        ))}
      </div>
    </div>
  );
}

function FilterButton({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      style={{
        flex: "0 0 auto",
        border: `1px solid ${active ? "var(--primary)" : "var(--card-border)"}`,
        borderRadius: 999,
        padding: "5px 10px",
        background: active
          ? "color-mix(in srgb, var(--primary) 15%, var(--canvas))"
          : "var(--canvas)",
        color: active ? "var(--primary-accent)" : "var(--ink-muted)",
        fontSize: "var(--t-xs)",
        fontWeight: active ? 700 : 600,
        cursor: "pointer",
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </button>
  );
}
