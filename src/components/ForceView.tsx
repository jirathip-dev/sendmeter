import { useEffect, useRef, useState } from "react";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useLiveForce } from "../hooks/useLiveForce";
import { interruptionNote, recoveredTagSide } from "../hooks/useTindeq";
import { useTindeqSession } from "../hooks/useTindeqSession";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import { useWakeLock } from "../hooks/useWakeLock";
import {
  deleteRecording,
  fetchHiddenTags,
  fetchRecordings,
  fetchRecordingSamples,
  fetchTagCurves,
  insertRecording,
  saveTagCurve,
} from "../lib/repo";
import { predictSessionRpe } from "../lib/rpeDepletion";
import {
  computeForceCurve,
  CURVE_PERIODS,
  pickCurveRecordings,
  ZONE_INTENSITY,
} from "../lib/force-curve";
import type { ForceCurveModel, PeriodCurve } from "../lib/force-curve";
import { buildTimeline, presetTargetKg, timelineAt } from "../lib/protocol";
import type { ProtocolSegment } from "../lib/protocol";
import {
  endTindeqLiveActivity,
  startTindeqLiveActivity,
  updateTindeqLivePeak,
} from "../lib/liveActivity";
import { endGaugeSession } from "../lib/gaugeSessionEnd";
import { reportPersistFailure } from "../lib/lostRecordings";
import { persistRecordingDurable } from "../lib/recordingQueue";
import { usePendingUploads } from "../hooks/usePendingUploads";
import { PENDING_BACKED_UP } from "../lib/pendingUploads";
import type {
  NewTindeqRecording,
  TindeqPreset,
  TindeqRecordingMeta,
  TindeqSide,
} from "../types";
import ForceCurveCard from "./ForceCurveCard";
import type { GaugeTarget } from "./ForceCurveCard";
import PresetManager from "./PresetManager";
import { clearPersistedPreset } from "../lib/forcePresetStorage";
import { restoredSelection, selectZoneOutcome, withPresetSelected } from "../lib/forceSelection";
import SideAsymmetryCard from "./SideAsymmetryCard";
import TagManagerSheet from "./TagManagerSheet";
import TagSideEditor from "./TagSideEditor";
import TargetZonesCard from "./TargetZonesCard";
import {
  applyIntensity,
  buildZoneSelection,
  loadIntensity,
  performedQuality,
  saveIntensity,
  type ZoneSelection,
} from "../lib/zoneSelection";
import ZoneFocusCard from "./ZoneFocusCard";
import ForceFullscreen from "./ForceFullscreen";
import ForceTrendChart from "./ForceTrendChart";
import LiveForceSparkline from "./LiveForceSparkline";

interface ForceViewProps {
  userId: string;
  onLogSession: (input: {
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
    rpeConfirmed?: boolean;
  }) => Promise<boolean>;
}

export default function ForceView({ userId, onLogSession }: ForceViewProps) {
  const toast = useToast();
  // #106: a rep whose insert fails (dead auth session, dropped connection)
  // gets queued instead of dropped — App.tsx drains it once a session comes
  // back. Tracks whether the PREVIOUS attempt (of either kind) failed, so the
  // toast below fires once per outage rather than once per queue-empty check —
  // a queue that's still non-empty from an earlier outage must not swallow the
  // notice for a brand-new one.
  const outageRef = useRef(false);
  // #269: the queue's ambient depth. Not an interrupt — see pendingUploads.ts
  // for why a per-failure toast is the wrong shape.
  const pendingUploads = usePendingUploads();
  // #264: reps that the insert AND both stores refused. Their samples exist
  // nowhere but this array, so the banner below says exactly that and offers a
  // real retry while the view is still mounted. Never told "will sync
  // automatically" — nothing is holding them but this component.
  const [unqueued, setUnqueued] = useState<(NewTindeqRecording & { id: string })[]>(
    [],
  );
  const [retryingUnqueued, setRetryingUnqueued] = useState(false);
  // #269: async, and free to be — unlike useTindeq's unmount cleanup this
  // caller stays mounted for the whole write, so it uses the IndexedDB main
  // queue rather than the synchronous emergency lane.
  async function queueFailedRecording(rec: NewTindeqRecording & { id: string }) {
    const isNewOutage = !outageRef.current;
    outageRef.current = true;
    const result = await persistRecordingDurable(rec, userId);
    reportPersistFailure("save-failed", result, rec.samples.length);
    if (!result.persisted) {
      // Always banner (one row per lost rep) but keep the toast on the same
      // once-per-outage gate as the queued case, so a guided protocol whose
      // every rep fails doesn't stack a toast per rep.
      setUnqueued((list) => [...list, rec]);
      if (isNewOutage) {
        toast("Storage full — this recording is not saved anywhere", "error");
      }
      return;
    }
    if (!isNewOutage) return;
    toast("Couldn't save — recording queued, will sync automatically", "error");
  }

  /// Retry everything in the banner: the server first (the outage may be
  /// over), then the durable queue (storage may have room again — a drain or
  /// an eviction elsewhere frees it), and only what fails both stays in
  /// memory. A rep that reaches the queue leaves the banner: it is durable
  /// now, which is the whole point of the queue.
  async function retryUnqueued() {
    if (retryingUnqueued || unqueued.length === 0) return;
    setRetryingUnqueued(true);
    const pending = unqueued;
    const saved: TindeqRecordingMeta[] = [];
    const stillLost: (NewTindeqRecording & { id: string })[] = [];
    let queued = 0;
    for (const rec of pending) {
      try {
        saved.push(await insertRecording(rec));
      } catch {
        const result = await persistRecordingDurable(rec, userId);
        reportPersistFailure("save-failed", result, rec.samples.length);
        if (result.persisted) queued += 1;
        else stillLost.push(rec);
      }
    }
    if (saved.length > 0) {
      outageRef.current = false;
      setRecordings((list) => [...saved, ...list]);
      setListError(null);
    }
    setUnqueued(stillLost);
    setRetryingUnqueued(false);
    if (saved.length > 0) {
      toast(`Saved ${saved.length} recording${saved.length === 1 ? "" : "s"}`);
    } else if (queued > 0) {
      toast(`Queued ${queued} recording${queued === 1 ? "" : "s"} — will sync`);
    } else {
      toast("Still can't save — storage is full", "error");
    }
  }
  // Connection + active gauge session live in an app-level provider so the
  // Progressor stays connected and the session survives leaving fullscreen /
  // changing tabs (SL-58 #5). The session is minted lazily on the first save.
  const {
    tindeq,
    session: gaugeSession,
    ensureSession,
    clearSession,
    minimized: gaugeMinimized,
    setMinimized: setGaugeMinimized,
  } = useTindeqSession();
  // Watch gauge mirror (SL-87) — non-null while the watch's Progressor
  // screen is connected/measuring and the phone is WC-reachable.
  const liveForce = useLiveForce();
  // The just-auto-saved recording, shown as a confirmation so the user can
  // eyeball its tag (and undo if it was wrong). Replaces the old discard/save
  // prompt — a rep now saves the moment you stop, using the tag set beforehand.
  const [justSaved, setJustSaved] = useState<TindeqRecordingMeta | null>(null);
  const [pendingTag, setPendingTag] = useState("");
  const [pendingSide, setPendingSide] = useState<TindeqSide>("");
  const [saving, setSaving] = useState(false);
  // Guided-protocol clock controls. The protocol position is normally a pure
  // function of the physical measuring clock (tindeq.elapsedMs); these let the
  // user Pause / Skip by shifting *protocol* time relative to physical time.
  //   protoTime = (paused ? pausedAtS : physicalS) + protoShiftS
  // Skip adds the current segment's remaining time to the shift (jump forward);
  // Pause freezes the base at the physical second it was tapped. The per-rep
  // recorder maps protocol→physical by SUBTRACTING protoShiftS, so holds are
  // still sliced from the right physical window (see saveHoldSlice). Reset on
  // each Start.
  const [protoShiftS, setProtoShiftS] = useState(0);
  const [pausedAtS, setPausedAtS] = useState<number | null>(null);
  const [recordings, setRecordings] = useState<TindeqRecordingMeta[]>([]);
  // #295: endSession runs from the disconnect effect's deferred timeout,
  // whose closure captured `recordings` from the render before the final
  // rep's save landed — read the current list instead of that stale one.
  const recordingsRef = useRef<TindeqRecordingMeta[]>(recordings);
  useEffect(() => {
    recordingsRef.current = recordings;
  }, [recordings]);
  // #295: groupIds already ended, claimed synchronously (before any await) in
  // endGaugeSession — the disconnect effect's deferred endSession() and a
  // Finish tap can both pass the `if (!gaugeSession) return` guard above from
  // stale-but-still-valid closures (clearSession's setState can't retroactively
  // null another in-flight closure's captured value), so without this a
  // double call inserted two sessions for the same groupId.
  const endedGroupsRef = useRef<Set<string>>(new Set());
  const [listError, setListError] = useState<string | null>(null);
  const [zoneSel, setZoneSel] = useState<ZoneSelection | null>(null);
  const [preset, setPreset] = useState<TindeqPreset | null>(null);
  // #296: keep the zone and custom-preset selections mutually exclusive —
  // see forceSelection.ts for the rule and why it's needed.
  function selectZone(sel: ZoneSelection | null) {
    const { selection, clearsPersistedPreset } = selectZoneOutcome({ zoneSel, preset }, sel);
    setZoneSel(selection.zoneSel);
    setPreset(selection.preset);
    if (clearsPersistedPreset) clearPersistedPreset();
  }
  function selectPreset(p: TindeqPreset | null) {
    const next = withPresetSelected({ zoneSel, preset }, p);
    setPreset(next.preset);
    if (next.zoneSel !== zoneSel) setZoneSel(next.zoneSel);
  }
  // Global session-intensity dial (SL-97b) — one number for the whole
  // Protocol-presets section (zones AND custom presets), lazily seeded from
  // localStorage so a returning user keeps their last adjustment.
  const [intensityPct, setIntensityPct] = useState(() => loadIntensity());
  // Force-curve model for the selected tag/side — auto-computed (no button)
  // and shared by the curve card + the target-zones picker.
  const [curveModel, setCurveModel] = useState<ForceCurveModel | null>(null);
  // Curve-shift overlays (SL-80c): one model per trailing window (30d…3y).
  const [periodCurves, setPeriodCurves] = useState<PeriodCurve[]>([]);
  const [curveComputedFor, setCurveComputedFor] = useState<string | null>(null);
  const [curveError, setCurveError] = useState<string | null>(null);
  const realtimeVersion = useRealtimeVersion();

  // Every tag ever used with its rep count, most frequent first (SL-82).
  const tagCounts = (() => {
    const counts = new Map<string, number>();
    for (const r of recordings) {
      if (r.tag) counts.set(r.tag, (counts.get(r.tag) ?? 0) + 1);
    }
    return [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([name, count]) => ({ name, count }));
  })();
  // Hidden tags (SL-92) drop out of the pickers/trend/curve — the recordings
  // stay. Not in the realtime publication, so mutations bump manually.
  const hiddenTags = useCancellableFetch(fetchHiddenTags, [], realtimeVersion);
  const hiddenSet = new Set(hiddenTags);
  const allTags = tagCounts
    .filter((t) => !hiddenSet.has(t.name))
    .map((t) => t.name);
  const [showTagManager, setShowTagManager] = useState(false);

  const sessionCount = gaugeSession
    ? recordings.filter((r) => r.groupId === gaugeSession.groupId).length
    : 0;

  /// Predict this session's RPE from W' depletion (#280), the same model the
  /// watch runs: every rep against ITS OWN tag's fitted curve, read back from
  /// the registry the curve effect below keeps up to date. Any failure — a
  /// dead network, a tag that's never been fitted — falls back rather than
  /// blocking the log; the caller banks the result unconfirmed either way.
  /// Bounded to 4s (#295): ending a session now logs immediately, so this
  /// can no longer sit waiting on a stalled fetch the way the old RPE-prompt
  /// flow could (that prompt was already open; nothing here is).
  ///
  /// The recordings snapshot is taken AFTER the curve fetch resolves, not
  /// before — on an involuntary disconnect the final rep's save
  /// (insertRecording → setRecordings) can still be in flight, and this
  /// wait is the only grace period it gets. Snapshotting early can miss it,
  /// so the prediction, note and duration below all read the same
  /// as-late-as-possible list.
  async function predictGroupRpe(groupId: string) {
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    const curves = await Promise.race([
      fetchTagCurves().catch(() => [] as Awaited<ReturnType<typeof fetchTagCurves>>),
      new Promise<Awaited<ReturnType<typeof fetchTagCurves>>>((resolve) => {
        timeoutId = setTimeout(() => resolve([]), 4000);
      }),
    ]).finally(() => clearTimeout(timeoutId));
    const recs = recordingsRef.current.filter((r) => r.groupId === groupId);
    const byTag = new Map(curves.map((c) => [c.name, c]));
    const predicted = predictSessionRpe(
      recs.map((r) => ({
        peakKg: r.peakKg,
        durationS: r.durationMs / 1000,
        cf: byTag.get(r.tag)?.cf ?? null,
        wPrime: byTag.get(r.tag)?.wPrime ?? null,
      })),
    );
    return { predicted, recs };
  }

  // #295: mirrors the watch's TindeqManager.logSessionNow() — logs the
  // instant the session ends, no confirm step. RPE is the #280 W'-depletion
  // prediction (or its fallback), always banked unconfirmed since nobody
  // reviewed it; History's EditSessionSheet is where that review now happens.
  async function endSession() {
    if (!gaugeSession) return;
    const groupId = gaugeSession.groupId;
    const wallClockMin = Math.max(
      1,
      Math.round((Date.now() - gaugeSession.startedAt) / 60000),
    );
    clearSession();
    const ok = await endGaugeSession({
      groupId,
      wallClockMin,
      claimed: endedGroupsRef.current,
      predictGroupRpe,
      onLogSession,
    });
    if (ok === null) return; // lost the race — another call already logged this group
    toast(
      ok ? "Gauge session logged to history" : "Couldn't log gauge session",
      ok ? undefined : "error",
    );
  }

  useEffect(() => {
    let cancelled = false;
    fetchRecordings()
      .then((list) => {
        if (cancelled) return;
        setRecordings(list);
        // Default the tag input to the most-recorded exercise so the input
        // matches what the charts below already show (they fall back to it).
        const counts = new Map<string, number>();
        for (const r of list) {
          if (r.tag) counts.set(r.tag, (counts.get(r.tag) ?? 0) + 1);
        }
        const top = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
        if (top) setPendingTag((prev) => (prev.trim() ? prev : top));
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setListError(
            e instanceof Error ? e.message : "Failed to load recordings",
          );
        }
      });
    return () => {
      cancelled = true;
    };
  }, [realtimeVersion]);

  // Save one hold segment of a guided protocol as its OWN recording — sliced
  // from the live sample buffer, with the segment's hand (L/R when
  // alternating) so per-side analysis stays honest.
  //
  // `segIdx` makes the save IDEMPOTENT: the per-rep autosave effect and
  // handleStop can both reach a hold near its boundary, and without this
  // guard both would slice+insert it (one full segment, one partial-at-stop)
  // → the duplicate recordings seen in the wild. The index is claimed
  // synchronously before the async insert so whichever path runs first wins.
  const savedSegsRef = useRef<Set<number>>(new Set());
  // One id per guided-protocol run (SL-79) — every rep saved from that run
  // carries it (+ its set number), so History can treat the run/set as a
  // group and edits can apply to all of it. Null while free-holding.
  const protocolRunIdRef = useRef<string | null>(null);
  async function saveHoldSlice(
    seg: ProtocolSegment,
    segIdx: number,
    endMsOverride?: number,
  ) {
    if (savedSegsRef.current.has(segIdx)) return;
    savedSegsRef.current.add(segIdx);
    // Segment times are PROTOCOL seconds; the sample buffer is PHYSICAL ms.
    // physical = protocol − protoShiftS (Skip/Pause only shift between holds,
    // so the shift is constant across any single hold's physical span).
    const startMs = (seg.startS - protoShiftS) * 1000;
    const endMs = endMsOverride ?? (seg.startS + seg.durS - protoShiftS) * 1000;
    const slice = tindeq.samplesRef.current
      .filter((s) => s.t >= startMs && s.t <= endMs)
      .map((s) => ({ t: Math.round((s.t - startMs) * 10) / 10, kg: s.kg }));
    if (slice.length < 2) {
      savedSegsRef.current.delete(segIdx); // nothing saved — allow a retry
      return;
    }
    const kgs = slice.map((s) => s.kg);
    // Minted up front (not just on retry) so even the FIRST attempt below
    // carries it — if that request actually lands server-side but the
    // response never makes it back (dead session, timeout), a later queue
    // drain retrying with this SAME id collides on the primary key (23505)
    // instead of inserting a second row for the same rep (#106).
    const rec: NewTindeqRecording & { id: string } = {
      id: crypto.randomUUID(),
      durationMs: Math.max(1, Math.round(slice[slice.length - 1]!.t)),
      peakKg: Math.max(...kgs),
      avgKg: Math.round((kgs.reduce((a, b) => a + b, 0) / kgs.length) * 100) / 100,
      note: "",
      tag: pendingTag.trim(),
      side: seg.side ?? pendingSide,
      groupId: ensureSession(),
      protocolRunId: protocolRunIdRef.current,
      setNo: seg.set,
      // #259: stamp the quality this rep was PERFORMED under — the armed
      // zone's own quality, or the custom preset's load-aware badge at THIS
      // set's target (per-set ramps can move it). Without this the load half
      // of that decision is thrown away and the hold gets re-classified from
      // duration alone on every later read.
      zone: performedQuality(
        activeProtocol,
        activeProtocol ? presetTargetKg(activeProtocol, presetRefs, seg.set) : null,
        presetRefs,
      ),
      samples: slice,
    };
    try {
      const saved = await insertRecording(rec);
      outageRef.current = false;
      setRecordings((list) => [saved, ...list]);
      setJustSaved(saved);
    } catch (e) {
      // Insert failed (dead auth session, dropped connection, …) — queue the
      // slice for retry instead of dropping it (#106). Unlike the "nothing
      // captured" branch above, KEEP the segment claimed: retrying now
      // happens via the queue drain, not the live autosave effect, so
      // un-claiming would let that effect re-walk this same index once more
      // time has passed and insert the FULL segment — landing both the
      // queued partial and the live full rep as two rows for one hold (the
      // exact double-count hazard CLAUDE.md warns about for guided protocols).
      setListError(e instanceof Error ? e.message : "Failed to save recording");
      await queueFailedRecording(rec);
    }
  }

  // Stop always saves — the tag was required before Start, so there's nothing
  // to decide here. Guided protocols save PER REP (each hold is already its
  // own recording); a free hold saves the whole pull as one recording.
  // Re-entrancy guard: a manual Stop and the BLE-disconnect auto-save (or a
  // double tap) could both call this — the first claim wins so a free hold is
  // never inserted twice.
  const stopInFlightRef = useRef(false);
  // `note` labels the free-hold save — "" for a normal stop; the interruption
  // effect below passes "Recovered after connection loss" when the drop fired
  // while this view was unmounted (#117).
  async function handleStop(note = "") {
    if (stopInFlightRef.current) return;
    stopInFlightRef.current = true;
    try {
      await runStop(note);
    } finally {
      stopInFlightRef.current = false;
    }
  }

  async function runStop(note: string) {
    if (timeline) {
      const tMs = tindeq.elapsedMs;
      const physS = tMs / 1000;
      // Walk the timeline in PROTOCOL time (physical clock + Pause/Skip shift).
      const effS = (pausedAtS ?? physS) + protoShiftS;
      const endPhysMs = (pausedAtS ?? physS) * 1000; // physical clock at effS
      setSaving(true);
      try {
        // Flush any completed-but-unflushed holds, then a ≥1s partial hold.
        let idx = timeline.findIndex((s) => effS < s.startS + s.durS);
        if (idx === -1) idx = timeline.length;
        for (let i = savedThroughRef.current; i < idx; i++) {
          const seg = timeline[i]!;
          if (seg.phase === "hold") await saveHoldSlice(seg, i);
        }
        savedThroughRef.current = idx;
        const pos = timelineAt(timeline, effS);
        // idx is the current (in-progress) segment — same key the autosave
        // effect would use, so the guard dedupes the two paths.
        if (
          pos &&
          pos.seg.phase === "hold" &&
          endPhysMs - (pos.seg.startS - protoShiftS) * 1000 >= 1000
        ) {
          await saveHoldSlice(pos.seg, idx, endPhysMs);
        }
      } finally {
        setSaving(false);
      }
      await tindeq.stop();
      void endTindeqLiveActivity();
      return;
    }
    // #119: a recovery stop (note !== "") can be running on a FRESH mount whose
    // pendingTag/pendingSide are still empty — this 0 ms-deferred call beats
    // the async tag seeding — so fall back to the tag/side snapshotted when the
    // drop fired. That's the same pre-Start label the sign-out salvage path
    // writes from salvageContextRef; the two recovery paths were inconsistent.
    // Read BEFORE tindeq.stop(), which releases the claim and the snapshot.
    const { tag, side } =
      note === ""
        ? { tag: pendingTag.trim(), side: pendingSide }
        : recoveredTagSide(
            { tag: pendingTag.trim(), side: pendingSide },
            tindeq.interruptionContext,
          );
    const summary = await tindeq.stop();
    void endTindeqLiveActivity();
    if (!summary) return;
    setSaving(true);
    // Minted up front — see the comment on the equivalent line in
    // saveHoldSlice (retry idempotency via 23505, #106).
    const rec: NewTindeqRecording & { id: string } = {
      id: crypto.randomUUID(),
      durationMs: summary.durationMs,
      peakKg: summary.peakKg,
      avgKg: summary.avgKg,
      note,
      tag,
      side,
      groupId: ensureSession(),
      protocolRunId: null,
      setNo: null,
      // Freehand pull — this branch only runs with no protocol armed, so
      // there is no zone the hold was performed under. Null, not a guess:
      // readers infer one from duration and can say that they did (#259).
      zone: null,
      samples: summary.samples,
    };
    try {
      const saved = await insertRecording(rec);
      outageRef.current = false;
      setRecordings((list) => [saved, ...list]);
      setJustSaved(saved);
      // keep tag and side — set once, tweak side between reps
    } catch (e) {
      // Queue instead of dropping (#106) — see saveHoldSlice above.
      setListError(e instanceof Error ? e.message : "Failed to save recording");
      await queueFailedRecording(rec);
    } finally {
      setSaving(false);
    }
  }

  // Undo a just-saved rep (mis-tagged, or a bad pull) — deletes it and clears
  // the confirmation so the user can retag and pull again.
  async function undoJustSaved() {
    if (!justSaved) return;
    const id = justSaved.id;
    setJustSaved(null);
    await removeRecording(id);
  }

  // The tag + side set in the Exercise card are GLOBAL for this tab: they
  // label the next recording AND drive the target zones, trend and curve.
  // Charts fall back to the most-recorded tag while the input doesn't match
  // an existing one (mid-typing / brand-new tag).
  const trimmedTag = pendingTag.trim();
  const effectiveTag = allTags.includes(trimmedTag)
    ? trimmedTag
    : (allTags[0] ?? null);
  const chartSide: TindeqSide | null =
    pendingSide === "left" || pendingSide === "right" ? pendingSide : null;

  // Auto-compute the force curve for the active tag/side (default show — no
  // "Compute" button). All state writes happen in async callbacks; "which key
  // the model belongs to" is tracked so computing/model are derived, not
  // synced.
  const curveRecordings = recordings.filter(
    (r) =>
      effectiveTag !== null &&
      r.tag === effectiveTag &&
      (chartSide === null || r.side === chartSide),
  );
  const tagSideKey = `${effectiveTag ?? ""}|${chartSide ?? "all"}`;
  const curveKey = `${tagSideKey}|${curveRecordings.length}`;
  const canComputeCurve = effectiveTag !== null && curveRecordings.length > 0;
  const curveFrozen = tindeq.status === "measuring";
  useEffect(() => {
    if (!canComputeCurve) return;
    // Freeze mid-run (SL-80): every per-rep save bumps the count and would
    // trigger a recompute whose short-hold flood can null CF — taking the
    // armed target away mid-set. Recompute on stop instead.
    if (curveFrozen) return;
    let cancelled = false;
    // Best per duration bucket over a long window — NOT the latest N, which a
    // burst of short reps floods (SL-80).
    const now = Date.now();
    const recs = pickCurveRecordings(curveRecordings, now);
    // Per-period picks for the curve-shift overlays (strict windows — an
    // empty period is an honestly absent curve, not a fallback).
    const periodPicks = CURVE_PERIODS.map((p) => ({
      ...p,
      recs: pickCurveRecordings(curveRecordings, now, {
        windowDays: p.days,
        fallbackToAll: false,
      }),
    }));
    // One shared sample fetch across the active model + every period.
    const ids = [
      ...new Set([...recs, ...periodPicks.flatMap((p) => p.recs)].map((r) => r.id)),
    ];
    Promise.all(ids.map((id) => fetchRecordingSamples(id)))
      .then((all) => {
        if (cancelled) return;
        const samplesById = new Map(ids.map((id, i) => [id, all[i]!]));
        const m = computeForceCurve(recs.map((r) => samplesById.get(r.id)!));
        setCurveModel(m);
        setPeriodCurves(
          periodPicks.map((p) => ({
            label: p.label,
            days: p.days,
            model: p.recs.length
              ? computeForceCurve(p.recs.map((r) => samplesById.get(r.id)!))
              : null,
          })),
        );
        setCurveError(m ? null : "No usable samples in these recordings.");
        setCurveComputedFor(curveKey);
        // #280: bank the fit on the tag registry so the WATCH can predict a
        // session's RPE from W' depletion. It can't refit — that needs the raw
        // sample streams it doesn't keep — but two numbers are enough.
        // Deliberately only the ALL-SIDES fit: the registry row is per tag
        // NAME, so persisting a left-only or right-only model would be read
        // back as "this tag's curve" and quietly halve it.
        // Fire-and-forget — a failed write just leaves the previous fit (or
        // none, and the prediction falls back); nothing here may block or
        // disturb the curve UI.
        if (effectiveTag !== null && chartSide === null && m?.cf != null && m.wPrime != null) {
          void saveTagCurve({
            name: effectiveTag,
            cf: m.cf,
            wPrime: m.wPrime,
            recordingCount: recs.length,
          }).catch(() => {});
        }
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setCurveError(e instanceof Error ? e.message : "Failed to compute curve");
        setCurveModel(null);
        setPeriodCurves([]);
        setCurveComputedFor(curveKey);
      });
    return () => {
      cancelled = true;
    };
    // curveKey encodes tag/side/count — the actual deps of this computation.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [curveKey, canComputeCurve, curveFrozen]);
  // Serve the model as long as it belongs to this tag/side — even while a
  // recompute for a newer count is pending — so the curve/zones/targets never
  // blank between reps. The count is the key's last "|" segment.
  const computedTagSide =
    curveComputedFor === null
      ? null
      : curveComputedFor.slice(0, curveComputedFor.lastIndexOf("|"));
  const modelForTagSide = computedTagSide === tagSideKey;
  const model = canComputeCurve && modelForTagSide ? curveModel : null;
  const curveComputing = canComputeCurve && !modelForTagSide;

  // PR for the active exercise (+side) — the same best-peak the trend chart
  // marks as PR. Anchors presets whose target is a % of PR.
  const prKg = curveRecordings.length
    ? Math.max(...curveRecordings.map((r) => r.peakKg))
    : null;

  // Force references a preset resolves its target against (PR / CF / W' / maxF).
  const presetRefs = {
    prKg,
    cf: model?.cf ?? null,
    wPrime: model?.wPrime ?? null,
    maxF: model?.maxF ?? null,
  };

  // One guided-timer path: `selectZone`/`selectPreset` (#296) keep the two
  // selections mutually exclusive, so at most one of these is non-null — the
  // `??` here is just picking whichever is armed, not a precedence rule. The
  // chart band comes from the preset's target (kg, %-of-PR/CF, or the smart
  // curve — set 1 here; the fullscreen ramps it per set), else the zone.
  const activeProtocol: TindeqPreset | null = preset ?? zoneSel?.protocol ?? null;
  const presetKgSet1 = preset ? presetTargetKg(preset, presetRefs, 1) : null;
  const bandTarget: GaugeTarget | null =
    preset && presetKgSet1 != null
      ? {
          kg: presetKgSet1,
          lowKg: presetKgSet1 * 0.9,
          highKg: presetKgSet1 * 1.1,
          workS: preset.holdS,
          label: preset.name,
        }
      : (zoneSel?.target ?? null);

  // The composed exercise label a zone selection arms/re-arms under (matches
  // the `tag` prop TargetZonesCard/ZoneFocusCard render with). Null while no
  // tag is selected yet.
  const zoneTag = effectiveTag ? (chartSide ? `${effectiveTag} · ${chartSide}` : effectiveTag) : null;

  // Move the global intensity dial (the slider on TargetZonesCard, #172):
  // persist + update state, and if a zone is currently armed, re-arm it at the
  // new pct so its baked target/timer numbers update immediately. Custom
  // presets are UNAFFECTED by this dial — their load is never rescaled, only
  // recommended zones respond to it (see `applyIntensity`).
  function changeIntensity(pct: number) {
    const next = Math.min(ZONE_INTENSITY.max, Math.max(ZONE_INTENSITY.min, pct));
    if (next === intensityPct) return;
    setIntensityPct(next);
    saveIntensity(next);
    setZoneSel(applyIntensity(zoneSel, model, zoneTag, next));
  }

  // Get-ready countdown preference (5s PREPARE before the first hold).
  const [prepare, setPrepare] = useState(
    () => localStorage.getItem("sendmeter:gauge-prepare") !== "0",
  );
  function togglePrepare(on: boolean) {
    setPrepare(on);
    localStorage.setItem("sendmeter:gauge-prepare", on ? "1" : "0");
  }

  // The expanded protocol timeline — built here (not in the fullscreen) so
  // the per-rep recorder below and the countdown display walk the SAME
  // segments and can never disagree. Cheap to rebuild per render.
  const timeline = activeProtocol
    ? buildTimeline(activeProtocol, {
        switchS: 3,
        prepareS: prepare ? 5 : 0,
      })
    : null;

  // Per-rep recorder: as the measurement clock passes each hold segment,
  // slice it out of the sample buffer and save it as its own recording.
  // Reset happens on the measuring rising edge (not on measuring→false) so an
  // involuntary disconnect can still flush the un-saved holds without
  // double-saving the ones this effect already wrote.
  const savedThroughRef = useRef(0);
  const wasMeasuringRef = useRef(false);
  const measuring = tindeq.status === "measuring";
  // Protocol seconds = physical clock (frozen while paused) + Pause/Skip shift.
  const protoTS = (pausedAtS ?? tindeq.elapsedMs / 1000) + protoShiftS;
  const paused = pausedAtS !== null;
  const protoPos = timeline && measuring ? timelineAt(timeline, protoTS) : null;
  useEffect(() => {
    if (measuring && !wasMeasuringRef.current) {
      savedThroughRef.current = 0;
      savedSegsRef.current = new Set();
    }
    wasMeasuringRef.current = measuring;
    if (!measuring || !timeline) return;
    const tS = protoTS;
    let idx = timeline.findIndex((s) => tS < s.startS + s.durS);
    if (idx === -1) idx = timeline.length;
    for (let i = savedThroughRef.current; i < idx; i++) {
      const seg = timeline[i]!;
      if (seg.phase === "hold") void saveHoldSlice(seg, i);
    }
    if (idx > savedThroughRef.current) savedThroughRef.current = idx;
    // saveHoldSlice is stable enough for this use (reads refs/state at call
    // time); depending on it would re-run every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [measuring, timeline, protoTS]);

  // Pause / Skip during a guided run. Both first FINALIZE an in-progress hold
  // (save the rep-so-far, mark it done) so the recorder never has to slice a
  // hold across a shift change; then they mutate the protocol clock.
  function finalizeHoldIfOpen() {
    if (!timeline || !protoPos || protoPos.seg.phase !== "hold") return;
    let idx = timeline.findIndex((s) => protoTS < s.startS + s.durS);
    if (idx === -1) idx = timeline.length;
    const physNowMs = (pausedAtS ?? tindeq.elapsedMs / 1000) * 1000;
    // Slice the rep-so-far now; saveHoldSlice claims the index synchronously
    // (savedSegsRef), so the autosave effect's later pass over this index is a
    // harmless no-op — no need to advance savedThroughRef (which the compiler
    // won't allow us to write from here anyway).
    void saveHoldSlice(protoPos.seg, idx, physNowMs);
  }
  function skipSegment() {
    if (!measuring || !timeline || !protoPos) return;
    finalizeHoldIfOpen();
    // Jump protocol time to the end of the current segment (= next segment's
    // start); the physical clock is unchanged, so the next segment begins now.
    setProtoShiftS((s) => s + protoPos.remaining);
  }
  function togglePause() {
    if (!measuring) return;
    if (pausedAtS !== null) {
      // Resume: keep protocol time where it froze, then track physical again.
      const physNow = tindeq.elapsedMs / 1000;
      setProtoShiftS((s) => s + pausedAtS - physNow);
      setPausedAtS(null);
    } else {
      finalizeHoldIfOpen();
      setPausedAtS(tindeq.elapsedMs / 1000);
    }
  }

  // Connection dropped mid-measurement (device died, walked out of range,
  // phone locked): the samples survive in samplesRef, so run the exact same
  // stop/save path a manual Stop would — the interrupted recording is saved
  // instead of lost. Driven by the provider-owned salvage CLAIM (not a
  // counter delta): effects run on mount, so a drop that fired while this
  // view was UNMOUNTED (tab switched) is re-detected on remount and recovered
  // the same way (#117). The claim is released inside handleStop → runStop →
  // tindeq.stop(), which flips the dep false; if a stop already completed
  // before this runs, the claim is false and nothing is scheduled. Deferred
  // to a task so no state writes happen synchronously inside the effect.
  // Whether THIS mounted instance ever observed measuring — false in the
  // remount case, which labels the recovered save (see interruptionNote).
  const everMeasuredRef = useRef(false);
  useEffect(() => {
    if (measuring) everMeasuredRef.current = true;
  }, [measuring]);
  useEffect(() => {
    if (!tindeq.pendingInterruption) return;
    const t = setTimeout(
      () => void handleStop(interruptionNote(everMeasuredRef.current)),
      0,
    );
    return () => clearTimeout(t);
    // handleStop reads current state/refs at call time; depending on it
    // would re-arm this effect every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tindeq.pendingInterruption]);

  // Feed the session peak to the lock-screen card, throttled — the card's
  // timers render natively; only the number needs occasional refreshes.
  const lastPeakSentRef = useRef(0);
  useEffect(() => {
    if (!measuring || tindeq.peak <= 0) return;
    const now = Date.now();
    if (now - lastPeakSentRef.current < 5000) return;
    lastPeakSentRef.current = now;
    void updateTindeqLivePeak(tindeq.peak);
  }, [measuring, tindeq.peak]);

  // Never leave a stale lock-screen card behind when the tab unmounts.
  useEffect(() => {
    return () => {
      void endTindeqLiveActivity();
    };
  }, []);

  // #106: if the auth session dies mid-measurement, the tab that vanishes is
  // NOT this component — App.tsx's `if (!session) return <LoginScreen />`
  // tears down the whole authed tree, including TindeqProvider, which owns
  // the BLE connection/samplesRef ABOVE the tab switch (SL-58 #5) so it
  // (correctly) survives ordinary navigation away from Force. TindeqProvider
  // therefore only unmounts for that one reason, and its own unmount
  // cleanup (in useTindeq.ts) is what salvages an in-progress pull — this
  // effect just keeps it supplied with the current tag/side/groupId (and
  // whether OUR OWN Stop flow is already handling the data) so that salvage
  // has something better than a tag-less fallback to work with. Not
  // unregistered on ForceView's own unmount: if the user leaves the Force
  // tab and the session then dies while they're elsewhere, this LAST-known
  // context is still the best guess available.
  useEffect(() => {
    tindeq.setSalvageContext(() => ({
      tag: pendingTag.trim(),
      side: pendingSide,
      groupId: gaugeSession?.groupId ?? null,
      // The signed-in user, always known here — without this a salvaged
      // recording would fall to enqueueRecording's null-userId path, which
      // ANY signed-in user can drain (real risk on a shared device using
      // throwaway dev accounts, not just hypothetical).
      userId,
      stopInFlight: stopInFlightRef.current,
    }));
    // setSalvageContext itself is useCallback-stable ([] deps in useTindeq);
    // depending on the whole `tindeq` object instead would re-run this every
    // animation frame while measuring (its container is a fresh object each
    // TindeqProvider render, since current/peak/elapsedMs tick via rAF).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tindeq.setSalvageContext, pendingTag, pendingSide, gaugeSession, userId]);

  // Pop the gauge fullscreen the moment the Progressor connects (only on the
  // connecting→connected transition — a stop→connected change must not
  // override a user's minimize). And when it DISCONNECTS with an active
  // session, prompt to finish it (SL-58 #5) — the connection now persists
  // across tabs, so a disconnect is a deliberate end (or the device dying).
  const { status } = tindeq;
  // Keep the screen awake while the gauge is live so a short auto-lock doesn't
  // interrupt a hold/protocol mid-recording.
  useWakeLock(status === "connected" || status === "measuring");
  const prevStatusRef = useRef(status);
  useEffect(() => {
    const prev = prevStatusRef.current;
    prevStatusRef.current = status;
    if (status === "connected" && prev === "connecting") {
      setGaugeMinimized(false);
    }
    if (status === "idle" && (prev === "connected" || prev === "measuring")) {
      // Defer so any interrupted-save from the same disconnect lands first,
      // and to avoid a synchronous setState in the effect body.
      const t = setTimeout(() => void endSession(), 150);
      return () => clearTimeout(t);
    }
    // endSession/setGaugeMinimized read current state at call time; depending
    // on them would re-run this transition effect every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status]);

  async function removeRecording(id: string) {
    const prev = recordings;
    setRecordings((list) => list.filter((r) => r.id !== id));
    try {
      await deleteRecording(id);
    } catch (e) {
      setRecordings(prev);
      setListError(
        e instanceof Error ? e.message : "Failed to delete recording",
      );
    }
  }

  return (
    <div>
      <div className="section-head">
        FORCE{" "}
        {tindeq.fakeMode && (
          <span style={{ fontSize: "var(--t-2xs)", color: "var(--warning)" }}>(fake mode)</span>
        )}
      </div>
      {/* #173: this copy — and "Connect Progressor" below — is still written
          for the Tindeq specifically, even though the hook underneath it is
          now device-agnostic. Deliberately NOT templated off
          `tindeq.deviceName`: these strings are hand-tuned prose ("Progressor"
          alone reads better than the full product name here), and a second
          device needs a copy pass, not a variable. That pass belongs with the
          driver that motivates it. */}
      <div className="section-sub">
        Grip-force analysis &amp; training — Tindeq Progressor via Bluetooth.
      </div>

      {/* Watch gauge mirror (SL-87) — the Progressor is on the WATCH; show
          its live numbers here, read-only (the watch owns the session). */}
      {liveForce && (
        <div
          className="card"
          style={{
            marginBottom: 10,
            border: "1px solid color-mix(in srgb, var(--info) 45%, transparent)",
          }}
        >
          <div
            className="label-eyebrow"
            style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 8 }}
          >
            <span
              aria-hidden="true"
              style={{
                width: 6,
                height: 6,
                borderRadius: "50%",
                background: "var(--success)",
                animation: "pulse 1.6s ease-in-out infinite",
              }}
            />
            Live on watch
            {liveForce.tag && (
              <span style={{ color: "var(--ink-faint)", textTransform: "none" }}>
                · {liveForce.tag}
                {liveForce.side ? ` · ${liveForce.side}` : ""}
              </span>
            )}
          </div>
          <div style={{ display: "flex", alignItems: "baseline", gap: 16 }}>
            <div>
              <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>
                {liveForce.status === "measuring" ? "CURRENT" : "LAST PEAK"}
              </div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: 32,
                  lineHeight: 1.1,
                  color: liveForce.status === "measuring" ? "var(--success)" : "var(--ink)",
                }}
              >
                {(liveForce.status === "measuring" ? liveForce.kg : liveForce.peakKg).toFixed(1)}
                <span style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)" }}> kg</span>
              </div>
            </div>
            {liveForce.status === "measuring" && (
              <div>
                <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>PEAK</div>
                <div
                  style={{
                    fontFamily: "Inter, sans-serif",
                    fontWeight: 800,
                    fontSize: "var(--t-md)",
                    color: "var(--warning)",
                  }}
                >
                  {liveForce.peakKg.toFixed(1)}
                </div>
              </div>
            )}
            <div style={{ marginLeft: "auto", textAlign: "right" }}>
              <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>REPS</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: "var(--t-md)",
                  color: "var(--ink)",
                }}
              >
                {liveForce.sessionCount}
              </div>
            </div>
          </div>
          {/* SL-95: recent-samples sparkline, accumulated client-side from
              each beat's small trailing window (see useLiveForce). */}
          <LiveForceSparkline samples={liveForce.spark} />
        </div>
      )}

      {/* Gauge session bar — appears once the first recording auto-creates a
          session (SL-58 #5, no manual Start). Finish auto-logs it (#295) with
          a predicted, unconfirmed RPE — edit it after the fact in History. */}
      {gaugeSession && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            padding: "10px 14px",
            background: "var(--canvas)",
            border: "1px solid rgba(91,95,199,0.55)",
            borderRadius: 10,
            boxShadow: "0 1px 4px rgba(0,0,0,0.12)",
            marginBottom: 10,
          }}
        >
          <div
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              background: "var(--info)",
            }}
          />
          <span style={{ fontSize: "var(--t-sm)", color: "var(--ink)", flex: 1 }}>
            Gauge session{" "}
            <span style={{ color: "var(--ink-muted)" }}>
              · {sessionCount} recording{sessionCount === 1 ? "" : "s"}
            </span>
          </span>
          <button
            onClick={() => void endSession()}
            style={{
              background: "none",
              border: "1px solid var(--ink-faint)",
              color: "var(--ink-muted)",
              padding: "6px 10px",
              borderRadius: 6,
              fontSize: "var(--t-2xs)",
              cursor: "pointer",
              fontFamily: "Inter, sans-serif",
            }}
          >
            Finish
          </button>
        </div>
      )}

      {status === "unsupported" && (
        <div className="card">
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: "var(--t-md)",
              fontWeight: 800,
              marginBottom: 8,
            }}
          >
            Bluetooth not available
          </div>
          <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", lineHeight: 1.5 }}>
            {tindeq.secure
              ? "This browser doesn't support Web Bluetooth. Use Chrome or Edge on desktop or Android — iOS Safari can't connect to Bluetooth devices."
              : "Web Bluetooth requires a secure (HTTPS) connection."}
          </div>
        </div>
      )}

      {status === "idle" && (
        <button className="btn-primary" onClick={() => void tindeq.connect()}>
          Connect Progressor
        </button>
      )}
      {status === "connecting" && (
        <button className="btn-primary" disabled>
          Connecting…
        </button>
      )}

      {tindeq.errorMsg && (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 10 }}>
          {tindeq.errorMsg}
        </div>
      )}

      {/* Connected: the gauge lives fullscreen; this is the resume bar */}
      {(status === "connected" || status === "measuring") && (
        <button
          onClick={() => setGaugeMinimized(false)}
          style={{
            width: "100%",
            textAlign: "left",
            cursor: "pointer",
            background: "var(--canvas)",
            border: `1px solid color-mix(in srgb, ${status === "measuring" ? "var(--success)" : "var(--info)"} 45%, transparent)`,
            borderRadius: 12,
            padding: 16,
            display: "flex",
            alignItems: "center",
            gap: 10,
            fontFamily: "inherit",
          }}
        >
          <div
            aria-hidden="true"
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              background: status === "measuring" ? "var(--success)" : "var(--info)",
              animation: status === "measuring" ? "pulse 1.6s ease-in-out infinite" : undefined,
            }}
          />
          <span style={{ fontSize: "var(--t-base)", color: "var(--ink)", flex: 1 }}>
            Progressor{" "}
            <span style={{ color: "var(--ink-muted)" }}>
              · {status === "measuring" ? "measuring" : "connected"}
            </span>
          </span>
          <span style={{ color: "var(--primary)", fontWeight: 700, fontSize: "var(--t-base)" }}>
            Open gauge ›
          </span>
        </button>
      )}

      {/* GLOBAL exercise + side: labels the next recording AND drives the
          target zones, trend and curve below. Always visible — this is also
          the only place a brand-new tag can be typed. */}
      <div className="card" style={{ marginTop: 10 }}>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            marginBottom: 8,
          }}
        >
          <div className="label-eyebrow">Exercise &amp; Side</div>
          {tagCounts.length > 0 && (
            <button
              onClick={() => setShowTagManager(true)}
              style={{
                background: "none",
                border: "none",
                color: "var(--primary)",
                fontFamily: "Inter, sans-serif",
                fontWeight: 700,
                fontSize: "var(--t-xs)",
                cursor: "pointer",
                padding: 0,
              }}
            >
              Manage tags
            </button>
          )}
        </div>
        <TagSideEditor
          tag={pendingTag}
          side={pendingSide}
          allTags={allTags}
          onTag={setPendingTag}
          onSide={setPendingSide}
        />
        {!pendingTag.trim() &&
          (status === "connected" || status === "measuring") && (
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", marginTop: 8 }}>
              Add a tag to start recording.
            </div>
          )}
        {justSaved && status === "connected" && (
            <div
              style={{
                marginTop: 10,
                paddingTop: 10,
                borderTop: "1px solid var(--hairline)",
                display: "flex",
                alignItems: "center",
                gap: 10,
              }}
            >
              <span style={{ fontSize: "var(--t-sm)", color: "var(--success)", fontWeight: 700, flex: 1 }}>
                Saved · {justSaved.tag || "untagged"}
                {justSaved.side ? ` · ${justSaved.side}` : ""}
              </span>
              <span style={{ fontSize: "var(--t-sm)", color: "var(--ink)", fontFamily: "Inter, sans-serif", fontWeight: 800 }}>
                {justSaved.peakKg.toFixed(1)} kg
              </span>
              <button
                onClick={() => void undoJustSaved()}
                style={{
                  background: "none",
                  border: "1px solid var(--ink-faint)",
                  color: "var(--ink-muted)",
                  padding: "6px 10px",
                  borderRadius: 6,
                  fontSize: "var(--t-2xs)",
                  cursor: "pointer",
                  fontFamily: "Inter, sans-serif",
                }}
              >
                Undo
              </button>
            </div>
          )}
      </div>

      {listError && (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 10 }}>
          {listError}
        </div>
      )}

      {/* #269: ambient backlog depth. Muted, no buttons, no interrupt — a rep
          waiting to upload is not a problem the user can act on mid-session,
          and a toast per failure would fire during exactly the outage they
          can do nothing about. What this buys is that a backlog which ISN'T
          draining becomes visible while the data is still there, instead of
          being discovered as a missing rep in History weeks later. Absent when
          the queue is empty (or not yet read) — this is the one place silence
          is honest, because the recordings list right above it is the positive
          signal that saving works. */}
      {pendingUploads !== null && pendingUploads > 0 && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            marginTop: 10,
            fontSize: "var(--t-xs)",
            color:
              pendingUploads >= PENDING_BACKED_UP ? "var(--warning)" : "var(--ink-muted)",
          }}
        >
          <span
            aria-hidden
            style={{
              width: 6,
              height: 6,
              borderRadius: "50%",
              background:
                pendingUploads >= PENDING_BACKED_UP ? "var(--warning)" : "var(--ink-faint)",
              flexShrink: 0,
            }}
          />
          <span>
            {pendingUploads} recording{pendingUploads === 1 ? "" : "s"} waiting to
            upload — saved on this device, {pendingUploads === 1 ? "it" : "they"} will
            sync when the connection is back.
          </span>
        </div>
      )}

      {/* #264: the honest banner for reps that reached NO durable store —
          neither the server nor the offline queue took them. It stays put
          (not a toast) because it is the only thing holding those samples,
          and it says so: "will be lost when you leave" is the truth, and a
          Retry that can actually still succeed is the only recovery there is.
          Discard makes the loss the user's explicit choice rather than a
          silent consequence of navigating away. */}
      {unqueued.length > 0 && (
        <div
          className="card"
          style={{
            marginTop: 10,
            borderColor: "var(--danger)",
            display: "flex",
            flexDirection: "column",
            gap: 10,
          }}
        >
          <div style={{ fontSize: "var(--t-sm)", color: "var(--danger)", fontWeight: 700 }}>
            {unqueued.length} recording{unqueued.length === 1 ? "" : "s"} not saved
          </div>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
            Device storage is full, so {unqueued.length === 1 ? "it" : "they"}{" "}
            couldn&apos;t be queued for later either.{" "}
            {unqueued.length === 1 ? "It is" : "They are"} only held on this
            screen and will be lost when you leave it. Free up storage, then
            retry.
          </div>
          <div style={{ display: "flex", gap: 8 }}>
            <button
              onClick={() => void retryUnqueued()}
              disabled={retryingUnqueued}
              style={{
                flex: 1,
                background: "var(--danger)",
                border: "none",
                color: "#fff",
                padding: "8px 12px",
                borderRadius: 8,
                fontSize: "var(--t-xs)",
                fontWeight: 700,
                fontFamily: "Inter, sans-serif",
                cursor: "pointer",
              }}
            >
              {retryingUnqueued ? "Retrying…" : "Retry"}
            </button>
            <button
              onClick={() => setUnqueued([])}
              disabled={retryingUnqueued}
              style={{
                background: "none",
                border: "1px solid var(--ink-faint)",
                color: "var(--ink-muted)",
                padding: "8px 12px",
                borderRadius: 8,
                fontSize: "var(--t-xs)",
                fontFamily: "Inter, sans-serif",
                cursor: "pointer",
              }}
            >
              Discard
            </button>
          </div>
        </div>
      )}

      {/* Protocols: the zone target is the recommended/default protocol
          (from your force curve); custom presets follow. The session-
          intensity dial (SL-97, slider on the recommended card since #172)
          applies to RECOMMENDED ZONES ONLY — it scales the target load and
          adapts hold time to keep the training dose equivalent. Custom
          presets are never touched by it; a preset's quality badge below
          still reflects whatever load it actually resolves to. */}
      <div
        style={{
          fontSize: "var(--t-2xs)",
          color: "var(--ink-faint)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          margin: "20px 0 10px",
        }}
      >
        Protocol presets
      </div>
      {zoneTag && (
        <TargetZonesCard
          tag={zoneTag}
          model={model}
          selected={zoneSel}
          onSelect={selectZone}
          intensityPct={intensityPct}
          onIntensityChange={changeIntensity}
        />
      )}
      {effectiveTag && zoneTag && (
        <ZoneFocusCard
          recordings={recordings.filter((r) => r.tag === effectiveTag)}
          // The card is scoped to the TAG (both sides), not `zoneTag` — which
          // carries the selected side and would overclaim (#214).
          exercise={effectiveTag}
          model={model}
          onPick={(q) => selectZone(buildZoneSelection(model, q, zoneTag, false, intensityPct))}
        />
      )}
      <PresetManager
        selectedId={preset?.id ?? null}
        onSelect={selectPreset}
        onRestore={(p) => {
          // #296: mount-time restore must never disarm a zone (or a preset)
          // armed since — restoredSelection reads the CURRENT zoneSel/preset
          // closed over by THIS render, so a zone armed while the presets
          // fetch was in flight still wins (forceSelection.test.ts covers
          // the race).
          const next = restoredSelection({ zoneSel, preset }, p);
          setZoneSel(next.zoneSel);
          setPreset(next.preset);
        }}
        presetRefs={presetRefs}
      />

      {showTagManager && (
        <TagManagerSheet
          tags={tagCounts}
          hidden={hiddenSet}
          onClose={() => setShowTagManager(false)}
        />
      )}

      {/* Peak force trend + force curve — always visible */}
      <div style={{ marginTop: 16 }}>
        {recordings.length >= 2 ? (
          <>
            <ForceTrendChart
              recordings={recordings}
              selectedTag={effectiveTag}
              selectedSide={chartSide}
            />
            {effectiveTag && (
              <ForceCurveCard
                tag={
                  chartSide
                    ? `${effectiveTag} · ${chartSide}`
                    : effectiveTag
                }
                model={model}
                periods={modelForTagSide ? periodCurves : []}
                computing={curveComputing}
                error={curveError}
              />
            )}
            {effectiveTag && (
              <SideAsymmetryCard
                recordings={recordings.filter((r) => r.tag === effectiveTag)}
              />
            )}
          </>
        ) : (
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)" }}>
            Peak force trend and the force–duration curve appear here after a
            couple of recordings. Recordings themselves live in History.
          </div>
        )}
      </div>

      {/* Immersive fullscreen gauge (overlays everything while connected) */}
      {(status === "connected" || status === "measuring") && !gaugeMinimized && (
        <ForceFullscreen
          tindeq={tindeq}
          protocol={activeProtocol}
          timeline={timeline}
          target={bandTarget}
          presetRefs={presetRefs}
          globalSide={pendingSide}
          tag={pendingTag}
          allTags={allTags}
          onTag={setPendingTag}
          onSide={setPendingSide}
          canStart={!!pendingTag.trim()}
          saving={saving}
          prepare={prepare}
          onTogglePrepare={togglePrepare}
          onStop={() => void handleStop()}
          protoTS={protoTS}
          paused={paused}
          onPause={togglePause}
          onSkip={skipSegment}
          onStart={() => {
            setJustSaved(null);
            setProtoShiftS(0);
            setPausedAtS(null);
            // New run id for guided runs; free holds stay unstamped (SL-79).
            protocolRunIdRef.current =
              timeline && activeProtocol ? crypto.randomUUID() : null;
            void tindeq.start();
            // Lock-screen card for guided runs: hand the whole segment
            // schedule to native up front — the countdown renders from
            // timestamps with no further JS involvement.
            if (timeline && activeProtocol) {
              const tag = pendingTag.trim();
              void startTindeqLiveActivity(
                tag ? `${activeProtocol.name} · ${tag}` : activeProtocol.name,
                presetKgSet1 ?? bandTarget?.kg ?? null,
                Date.now(),
                timeline,
              );
            }
          }}
          onMinimize={() => setGaugeMinimized(true)}
        />
      )}
    </div>
  );
}
