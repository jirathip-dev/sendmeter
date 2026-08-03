import { useEffect, useState } from "react";
import { PHASES } from "../constants";
import {
  useRealtimeBump,
  useRealtimeVersion,
} from "../hooks/useRealtimeVersion";
import { QUALITIES, type TrainingQuality } from "../lib/force-curve";
import {
  deleteRecording,
  fetchRecordingsByGroup,
  fetchSamplesForRecordings,
  fetchWorkoutForSession,
  recalcTindeqSessionDuration,
} from "../lib/repo";
import { QUALITY_COLORS } from "../lib/zoneSelection";
import type {
  Session,
  TindeqRecordingMeta,
  TindeqSample,
  WorkoutDetail,
} from "../types";
import DetailPage from "./DetailPage";
import EditRecordingSheet from "./EditRecordingSheet";
import RecordingRow from "./RecordingRow";
import RepBoxPlotChart from "./RepBoxPlotChart";
import WhyZoneInfo from "./WhyZoneInfo";
import WorkoutDetailPanel from "./WorkoutDetailPanel";

interface Props {
  s: Session;
  onDelete: (id: string) => void;
  onEdit?: (s: Session) => void;
  onRecordingsSaved?: (recordings: TindeqRecordingMeta[]) => void;
  /// Dominant training quality of this Tindeq session's own recordings
  /// (#214) — badges the session by what it actually trained instead of the
  /// app-wide phase. Null for non-Tindeq sessions or when no zone could be
  /// classified (e.g. the session has no recordings yet).
  zone?: TrainingQuality | null;
  /// Per-zone set-count mix backing `zone`, for the badge's title tooltip.
  zoneMix?: Record<TrainingQuality, number> | null;
}

/// One collapsible section per exercise tag inside a Tindeq session's detail
/// page — a high-rep session (dozens of reps across exercises) reads as a few
/// summary lines instead of an endless list.
function TagGroup({
  tag,
  recs,
  samplesById,
  onEditRec,
  onDeleteRec,
}: {
  tag: string;
  recs: TindeqRecordingMeta[];
  /// Recording id → raw kg samples for the whole session (issue #100) — the
  /// per-rep box plot below reads each rep's distribution out of this.
  samplesById: Map<string, TindeqSample[]>;
  onEditRec: (r: TindeqRecordingMeta) => void;
  onDeleteRec: (id: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const reverse = recs.filter((r) => r.protocolMode === "reverse_action");
  const measured = recs.filter(
    (r) =>
      r.protocolMode !== "reverse_action" &&
      r.source !== "manual" &&
      r.peakKg != null,
  );
  const manual = recs.filter((r) => r.source === "manual");
  const best = measured.length ? Math.max(...measured.map((r) => r.peakKg!)) : null;
  const displayRecs =
    reverse.length === recs.length
      ? [...recs].sort(
          (a, b) =>
            new Date(a.recordedAt).getTime() - new Date(b.recordedAt).getTime(),
        )
      : recs;
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
          {reverse.length === recs.length
            ? `${reverse.length} set${reverse.length === 1 ? "" : "s"}`
            : `${recs.length} entr${recs.length === 1 ? "y" : "ies"}`}
          {manual.length ? ` · ${manual.length} manual` : ""}{best != null && <> · best <span style={{ color: "var(--success)", fontWeight: 700 }}>{best.toFixed(1)} kg</span></>}
        </span>
        <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
          {open ? "▾" : "▸"}
        </span>
      </button>
      {/* Per-rep box plot — always visible (glanceable without expanding),
          but it's interactive (hover/scrub) so it lives outside the toggle
          button; stopPropagation as a backstop against any future wrapper
          click handler between here and the button. SL-102: samples are
          fetched once, eagerly, when the session detail opens (see `open()`
          below) — the amplifier that issue killed was the REALTIME refetch
          re-downloading everything on every account-wide write, not this
          one-shot fetch, so it stays eager to keep the chart glanceable. */}
      <div onClick={(e) => e.stopPropagation()}>
        {measured.length > 0 && <RepBoxPlotChart recs={measured} samplesById={samplesById} />}
      </div>
      {open && (
        <div style={{ marginTop: 6 }}>
          {displayRecs.map((r) => (
            <RecordingRow
              key={r.id}
              rec={r}
              prefetchedSamples={samplesById.get(r.id)}
              defaultExpanded={r.protocolMode === "reverse_action"}
              onEdit={onEditRec}
              onDelete={onDeleteRec}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export default function SessionRow({
  s,
  onDelete,
  onEdit,
  onRecordingsSaved,
  zone = null,
  zoneMix = null,
}: Props) {
  const ph = PHASES.find((p) => p.id === s.phase);
  // workoutSource (not type) marks a device workout — it survives type edits
  // (SL-43), so an auto-tracked session re-typed to "Board" still expands.
  const isWorkout = s.workoutSource !== null;
  const isTindeq = s.type === "tindeq" && s.groupId !== null;
  // #214: a Tindeq session badges by the training quality its own
  // recordings belong to (same classification as the Training-balance
  // card), not the app-wide phase — the two vocabularies otherwise
  // contradict each other on the same session. Falls back to the phase
  // badge until a zone is known (e.g. no classifiable recordings yet).
  const qualityBadge = isTindeq && zone !== null;
  const qualityColor = isTindeq && zone !== null ? QUALITY_COLORS[zone] : null;
  const expandable = isWorkout || isTindeq;
  // Detail opens as its OWN full-height page (sheet) instead of expanding
  // inline — long sessions were unmanageable inside the timeline (SL-86).
  const [detailOpen, setDetailOpen] = useState(false);
  const [detail, setDetail] = useState<WorkoutDetail | null | "missing">(null);
  const [tindeqRecs, setTindeqRecs] = useState<TindeqRecordingMeta[] | null>(
    null,
  );
  // Raw kg samples per recording (issue #100), keyed by recording id —
  // fetched alongside the metadata so the per-rep box plots have a
  // distribution to draw. Starts empty rather than null: the header/meta
  // above never waits on this, and `RepBoxPlotChart` treats "id missing from
  // the map" as "still loading".
  const [tindeqSamples, setTindeqSamples] = useState<Map<string, TindeqSample[]>>(
    () => new Map(),
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
        const recs = await fetchRecordingsByGroup(s.groupId!);
        setTindeqRecs(recs);
        // Samples need the recording ids, so this can't join the metadata
        // fetch in a Promise.all — but it's still one eager, one-shot fetch
        // per open (SL-102 review: this keeps the box plot glanceable
        // without a click; the amplifier the issue was actually about was
        // the REALTIME refetch below, not this one).
        const samples = await fetchSamplesForRecordings(recs.map((r) => r.id));
        setTindeqSamples(samples);
      }
    } catch {
      setLoadError(true);
    }
  }

  // Refetch the open detail when data changes elsewhere (e.g. a recording
  // assigned into this session's group, or a watch write). `tindeq_recordings`
  // is in `RealtimeVersionProvider`'s `WATCHED_TABLES` account-wide, so this
  // fires on every recording write anywhere, not just this session's — always
  // refetching full samples here was the SL-102 amplifier. Metadata is cheap
  // and always refreshed; samples are only fetched for recording ids that
  // aren't already cached (i.e. reps that showed up since the last fetch,
  // e.g. one saved from the watch while this sheet is open) — already-cached
  // ids are never refetched. Stale entries (recordings removed from this
  // group by the metadata refetch) are purged from the cache to match.
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
          if (cancelled) return;
          setTindeqRecs(recs);
          const currentIds = new Set(recs.map((r) => r.id));
          const newIds = recs
            .map((r) => r.id)
            .filter((id) => !tindeqSamples.has(id));
          // Purge samples for ids no longer in this group's metadata —
          // complements the deleteRec purge for the "deleted elsewhere"
          // path (e.g. reassigned to a different tag/session).
          setTindeqSamples((prev) => {
            let changed = false;
            const next = new Map(prev);
            for (const id of prev.keys()) {
              if (!currentIds.has(id)) {
                next.delete(id);
                changed = true;
              }
            }
            return changed ? next : prev;
          });
          if (newIds.length > 0) {
            const fetched = await fetchSamplesForRecordings(newIds);
            if (!cancelled) {
              setTindeqSamples((prev) => new Map([...prev, ...fetched]));
            }
          }
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
    // SL-102: also drop the id from the samples cache — otherwise it lingers
    // in `tindeqSamples` (harmless but an orphaned entry) until the group is
    // next re-expanded and the fetch happens to overwrite it.
    setTindeqSamples((prev) => {
      if (!prev.has(id)) return prev;
      const next = new Map(prev);
      next.delete(id);
      return next;
    });
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
      {/* #171: the tick sits on the header, not on the `.session-row` wrapper
          — the expanded panel below is inside that wrapper but stops its own
          clicks, so a tap there must stay silent. Only when the row actually
          expands: a non-expandable row's tap does nothing. */}
      <div
        data-haptic={expandable ? "light" : undefined}
        style={{ display: "flex", alignItems: "center", gap: 12 }}
      >
        <div
          className="session-phase-bar"
          style={{ background: qualityColor || ph?.color || "var(--border)" }}
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
            {qualityBadge ? (
              <span
                className="tag"
                title={
                  zoneMix
                    ? QUALITIES.map((q) => {
                        const n = Math.round(zoneMix[q.id] * 10) / 10;
                        return `${q.label} ${n} set${n === 1 ? "" : "s"}`;
                      }).join(" · ")
                    : undefined
                }
                style={{
                  background: `color-mix(in srgb, ${qualityColor} 12%, transparent)`,
                  color: qualityColor ?? "var(--ink-muted)",
                  border: `1px solid color-mix(in srgb, ${qualityColor} 35%, transparent)`,
                }}
              >
                {QUALITIES.find((q) => q.id === zone)!.label}
              </span>
            ) : (
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
            )}
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

      {/* The session's own page — slides in from the right, swipe right to
          go back (iOS push style). */}
      {detailOpen && (
        <div onClick={(e) => e.stopPropagation()} style={{ cursor: "default" }}>
          <DetailPage
            title={s.typeLabel}
            subtitle={`${s.date} · ${s.duration}min · RPE ${s.rpe} · ${s.load} AU${s.note ? ` · ${s.note}` : ""}`}
            onClose={() => setDetailOpen(false)}
          >
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
                {/* #214: why this session carries the zone badge it does —
                    the hold durations and the band each one fell in, in the
                    same layout the Training-balance page uses. The two
                    surfaces measure different things (this is one session;
                    that is one exercise over 4 weeks), so both show their
                    working rather than leaving the difference unexplained.
                    #292: that explanation now lives behind the "?" instead
                    of rendering inline all the time. */}
                {tindeqRecs !== null && tindeqRecs.length > 0 && (
                  <WhyZoneInfo
                    zoneLabel={zone ? QUALITIES.find((q) => q.id === zone)!.label : "unzoned"}
                    recs={tindeqRecs}
                  />
                )}
                {tagGroups.map((g) => (
                  <TagGroup
                    key={g.tag || "untagged"}
                    tag={g.tag}
                    recs={g.recs}
                    samplesById={tindeqSamples}
                    onEditRec={setEditingRec}
                    onDeleteRec={deleteRec}
                  />
                ))}
              </>
            )}
          </DetailPage>
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
          onSaved={(saved) => {
            setTindeqRecs((list) => {
              if (!list) return list;
              const byId = new Map(saved.map((r) => [r.id, r]));
              return list.map((x) => byId.get(x.id) ?? x);
            });
            onRecordingsSaved?.(saved);
          }}
          onClose={() => setEditingRec(null)}
        />
      )}
    </div>
  );
}
