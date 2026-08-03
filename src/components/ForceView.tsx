import { useEffect, useLayoutEffect, useRef, useState } from "react";
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
import {
  buildTimeline,
  prescriptionWorkS,
  presetTargetKg,
  timelineAt,
} from "../lib/protocol";
import { nextLockedCapabilityFit } from "../lib/capabilityFitLock";
import {
  curveCandidateRecordings,
  effortPeakKg,
  isDepletionEffortRecording,
  isMeasuredRecording,
  recordingCapacityModality,
} from "../lib/zoneHistory";
import type { ProtocolSegment } from "../lib/protocol";
import {
  buildReverseActionTimeline,
  buildReverseActionSetRecording,
  buildUnclaimedReverseActionSalvage,
  completesReverseActionSetAt,
  persistReverseActionSetOnce,
  reverseActionSetKey,
  reverseActionSetWindow,
  reverseActionTargetBand,
  type ReverseActionSegment,
} from "../lib/reverseAction";
import { nextLockedGaugeInputs } from "../lib/gaugeInputLock";
import type { GaugeInputs } from "../lib/gaugeInputLock";
import {
  endTindeqLiveActivity,
  startTindeqLiveActivity,
  updateTindeqLivePeak,
} from "../lib/liveActivity";
import { endGaugeSession } from "../lib/gaugeSessionEnd";
import { reportPersistFailure } from "../lib/lostRecordings";
import { persistRecordingDurable } from "../lib/recordingQueue";
import {
  armedHandsFreeForce,
  handsFreeForceAtInactiveStatus,
  idleHandsFreeForce,
  stepHandsFreeForce,
  type HandsFreeForceState,
} from "../lib/handsFreeForce";
import {
  adaptiveStaticHolds,
  armAdaptiveStatic,
  stepAdaptiveStatic,
  type AdaptiveStaticHold,
  type AdaptiveStaticState,
} from "../lib/adaptiveStaticProtocol";
import { usePendingUploads } from "../hooks/usePendingUploads";
import { PENDING_BACKED_UP } from "../lib/pendingUploads";
import { appendUniqueById, claimManualAttempt, claimManualSession, manualAttemptKey } from "../lib/manualForceSubmission";
import type {
  ForceCapacityModality,
  NewTindeqRecording,
  TindeqPreset,
  TindeqRecordingMeta,
  TindeqSample,
  TindeqSide,
} from "../types";
import ForceCurveCard from "./ForceCurveCard";
import type { GaugeTarget } from "./ForceCurveCard";
import PresetManager from "./PresetManager";
import { clearPersistedPreset } from "../lib/forcePresetStorage";
import {
  canSwitchProtocolModality,
  loadProtocolModality,
  presetModality,
  saveProtocolModality,
} from "../lib/protocolModeContext";
import { restoredSelection, selectZoneOutcome, withPresetSelected } from "../lib/forceSelection";
import SideAsymmetryCard from "./SideAsymmetryCard";
import TagManagerSheet from "./TagManagerSheet";
import TagSideEditor from "./TagSideEditor";
import TargetZonesCard from "./TargetZonesCard";
import {
  applyIntensity,
  armedAlternates,
  armedForDifferentTag,
  buildZoneSelectionPreservingSides,
  chartSideFor,
  loadIntensity,
  performedQuality,
  rederiveSelection,
  saveIntensity,
  selectedQuality,
  type ZoneSelection,
} from "../lib/zoneSelection";
import {
  postFitZoneDecision,
  type PostFitZoneState,
} from "../lib/postFitZoneDecision";
import {
  alternatingCurveInputKey,
  alternatingHoldDurations,
  needsHandReferences,
  nextLockedAlternatingPrescription,
  prescriptionForSegment,
  resolveAlternatingMaintenance,
  resolveAlternatingPreset,
  resolveAlternatingRecommendation,
  type AlternatingPrescription,
} from "../lib/alternatingProtocol";
import ZoneFocusCard from "./ZoneFocusCard";
import ForceFullscreen from "./ForceFullscreen";
import ManualForceFullscreen from "./ManualForceFullscreen";
import CadenceOnlyReverseActionFullscreen from "./CadenceOnlyReverseActionFullscreen";
import ForceConnectionCard from "./ForceConnectionCard";
import {
  isActiveTindeqStatus,
  sensorlessLaunchAvailable,
} from "../lib/forceConnection";
import ForceTrendChart from "./ForceTrendChart";
import LiveForceSparkline from "./LiveForceSparkline";
import ForceSetupGuide from "./ForceSetupGuide";
import {
  type ForceMeasurementMode,
} from "../lib/forceSetup";
import {
  cadenceOnlyRunComplete,
  loadCadenceOnlyRun,
  saveCadenceOnlyRun,
  type CadenceOnlyRunState,
} from "../lib/cadenceOnlyRun";

interface ForceViewProps {
  userId: string;
  onLogSession: (input: {
    id?: string;
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
    rpeConfirmed?: boolean;
    typeLabel?: string;
  }) => Promise<boolean>;
}

type ForceTimelineSegment = ProtocolSegment | ReverseActionSegment;

export default function ForceView({ userId, onLogSession }: ForceViewProps) {
  const toast = useToast();
  const [setupGuideOpen, setSetupGuideOpen] = useState(false);
  const [setupGuideSensor, setSetupGuideSensor] = useState(true);
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
      setUnqueued((list) => appendUniqueById(list, rec));
      if (isNewOutage) {
        toast("Storage full — this recording is not saved anywhere", "error");
      }
      return false;
    }
    if (isNewOutage) toast("Couldn't save — recording queued, will sync automatically", "error");
    return true;
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
  const [handsFreeEnabled, setHandsFreeEnabled] = useState(
    () => localStorage.getItem("sendmeter:gauge-hands-free") === "1",
  );
  const [targetCoachEnabled, setTargetCoachEnabled] = useState(
    () => localStorage.getItem("sendmeter:gauge-zone-coach") === "1",
  );
  // Pure threshold state lives in a ref because force samples arrive every
  // animation frame. Each emitted action advances the ref to its claimed
  // phase before any callback can await, preventing duplicate Start/Stop.
  const handsFreeControlRef = useRef<HandsFreeForceState>(idleHandsFreeForce());
  const adaptiveStaticRef = useRef<AdaptiveStaticState | null>(null);
  const adaptiveHoldsRef = useRef<AdaptiveStaticHold[]>([]);
  const adaptiveRunSnapshotRef = useRef<{
    protocol: TindeqPreset;
    tag: string;
    side: TindeqSide;
    refs: typeof presetRefs;
    alternatingPrescription: AlternatingPrescription | null;
    groupId: string | null;
    runId: string;
  } | null>(null);
  const [adaptiveStaticState, setAdaptiveStaticState] = useState<AdaptiveStaticState | null>(null);
  const handsFreeArmInFlightRef = useRef(false);
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
  const [zoneState, setZoneState] = useState<PostFitZoneState>({
    selection: null,
    notice: null,
    revision: 0,
  });
  const zoneSel = zoneState.selection;
  const [preset, setPreset] = useState<TindeqPreset | null>(null);
  const [protocolModality, setProtocolModality] =
    useState<ForceCapacityModality>(loadProtocolModality);
  const [manualOpen, setManualOpen] = useState(false);
  const [cadenceRun, setCadenceRun] = useState<CadenceOnlyRunState | null>(
    () => {
      const restored = loadCadenceOnlyRun();
      return restored?.userId === userId ? restored : null;
    },
  );
  const manualGroupRef = useRef<string | null>(null);
  const manualStartedRef = useRef(0);
  const manualRunIdRef = useRef<string | null>(null);
  const manualAttemptIdsRef = useRef<Map<string, string>>(new Map());
  const manualAttemptClaimsRef = useRef<Set<string>>(new Set());
  const manualSessionClaimsRef = useRef<Set<string>>(new Set());
  // #296: keep the zone and custom-preset selections mutually exclusive —
  // see forceSelection.ts for the rule and why it's needed.
  function selectZone(sel: ZoneSelection | null) {
    const { selection, clearsPersistedPreset } = selectZoneOutcome({ zoneSel, preset }, sel);
    setZoneState((current) => ({
      selection: selection.zoneSel,
      notice: null,
      revision: current.revision + 1,
    }));
    setPreset(selection.preset);
    if (clearsPersistedPreset) clearPersistedPreset();
  }
  function selectPreset(p: TindeqPreset | null) {
    if (p) {
      const nextModality = presetModality(p);
      setProtocolModality(nextModality);
      saveProtocolModality(nextModality);
    }
    const next = withPresetSelected({ zoneSel, preset }, p);
    setPreset(next.preset);
    // Selecting a custom preset must also clear a post-fit zone notice when
    // the zone was already null, so this write is intentionally unconditional.
    setZoneState((current) => ({
      selection: next.zoneSel,
      notice: null,
      revision: current.revision + 1,
    }));
  }
  // #298: one explicit "unarm" affordance for both the tab and the
  // fullscreen — drops whichever of zone/preset is active AND the persisted
  // preset key, so a stale key can't re-arm the preset on the next mount
  // (the #296 class; `PresetManager` owns that key at `clearPersistedPreset`).
  function clearProtocol() {
    setZoneState((current) => ({
      selection: null,
      notice: null,
      revision: current.revision + 1,
    }));
    setPreset(null);
    clearPersistedPreset();
  }
  function selectProtocolModality(next: ForceCapacityModality) {
    if (!canSwitchProtocolModality(protocolModality, next, runActive)) return;
    // A zone belongs to Static and custom presets belong to their saved
    // modality. Switching context must not leave an invisible protocol armed
    // (or persisted for a later mount).
    clearProtocol();
    setProtocolModality(next);
    saveProtocolModality(next);
  }
  // Global session-intensity dial (SL-97b) — one number for the whole
  // Protocol-presets section (zones AND custom presets), lazily seeded from
  // localStorage so a returning user keeps their last adjustment.
  const [intensityPct, setIntensityPct] = useState(() => loadIntensity());
  // Read inside the curve-recompute effect's `.then` below (an async path) —
  // the effect's deps are keyed on `curveKey`, so a dial move alone doesn't
  // cancel/rerun it, and the closed-over `intensityPct` would otherwise
  // evaluate the disarm check at the pct that was current when the fetch
  // started, not when it resolves.
  const intensityPctRef = useRef(intensityPct);
  useEffect(() => {
    intensityPctRef.current = intensityPct;
  }, [intensityPct]);
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
    const recs = recordingsRef.current.filter(
      (r) => r.groupId === groupId && isMeasuredRecording(r),
    );
    const byTagModality = new Map(
      curves.map((curve) => [`${curve.name}|${curve.modality}`, curve]),
    );
    const predicted = predictSessionRpe(
      recs.map((r) => ({
        peakKg: r.peakKg!,
        durationS: r.durationMs / 1000,
        cf: byTagModality.get(`${r.tag}|${recordingCapacityModality(r)}`)?.cf ?? null,
        wPrime: byTagModality.get(`${r.tag}|${recordingCapacityModality(r)}`)?.wPrime ?? null,
        isEffort: isDepletionEffortRecording(r),
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
      // `endSession` only runs from event/effect paths; this is elapsed wall
      // time, not a render-time value.
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
  const reverseSetClaimsRef = useRef<Set<string>>(new Set());
  const reverseSetIdsRef = useRef<Map<string, string>>(new Map());
  const reverseRunGroupIdRef = useRef<string | null>(null);
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
      // #298 round 5 (finding 2): the LOCKED pendingTag/pendingSide, not the
      // raw state — TagSideEditor is editable until this run's Start, so
      // reading the raw values here would let a tag change mid-run file
      // later reps under a different tag than the zone/target they were
      // actually performed against.
      tag: gaugeInputs.pendingTag,
      side: seg.side ?? gaugeInputs.pendingSide,
      groupId: ensureSession(),
      protocolRunId: protocolRunIdRef.current,
      setNo: seg.set,
      // #259: stamp the quality this rep was PERFORMED under — the armed
      // zone's own quality, or the custom preset's load-aware badge at THIS
      // set's target (per-set ramps can move it). Without this the load half
      // of that decision is thrown away and the hold gets re-classified from
      // duration alone on every later read.
      // #298 round 5: `activeProtocol` and `presetRefs.prKg` are themselves
      // derived from the LOCKED gauge inputs, so neither can have changed
      // since this run started — nothing further to freeze here.
      zone: (() => {
        // This async path reads the current frozen pair through a ref before
        // its first await; an older render's closure is never provenance.
        const resolved = prescriptionForSegment(
          alternatingPrescriptionRef.current,
          seg.side,
          seg.set,
        );
        return performedQuality(
          activeProtocol,
          resolved?.target?.kg ??
            (activeProtocol ? presetTargetKg(activeProtocol, presetRefs, seg.set) : null),
          resolved?.hand.refs ?? presetRefs,
          seg.set,
        );
      })(),
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

  function buildAdaptiveRecording(
    hold: AdaptiveStaticHold,
    samples: readonly TindeqSample[],
    startedMs: number,
    endedMs: number,
    outcome: "good" | "failed",
    note = outcome === "failed" ? "Hands-free protocol attempt failed" : "",
  ): (NewTindeqRecording & { id: string }) | null {
    const snapshot = adaptiveRunSnapshotRef.current;
    if (!snapshot) return null;
    const slice = samples
      .filter((sample) => sample.t >= startedMs && sample.t <= endedMs)
      .map((sample) => ({ t: Math.round((sample.t - startedMs) * 10) / 10, kg: sample.kg }));
    if (slice.length < 2) return null;
    const kgs = slice.map((sample) => sample.kg);
    const { protocol } = snapshot;
    const resolved = prescriptionForSegment(
      snapshot.alternatingPrescription,
      hold.side || snapshot.side,
      hold.set,
    );
    return {
      id: crypto.randomUUID(),
      durationMs: Math.max(1, endedMs - startedMs),
      peakKg: Math.max(...kgs),
      avgKg: Math.round((kgs.reduce((sum, kg) => sum + kg, 0) / kgs.length) * 100) / 100,
      note,
      tag: snapshot.tag,
      side: hold.side || snapshot.side,
      groupId: snapshot.groupId,
      protocolRunId: snapshot.runId,
      setNo: hold.set,
      repNo: hold.rep,
      zone: performedQuality(
        protocol,
        resolved?.target?.kg ?? presetTargetKg(protocol, snapshot.refs, hold.set),
        resolved?.hand.refs ?? snapshot.refs,
        hold.set,
      ),
      outcome,
      plannedDurationMs: hold.durationMs,
      actualDurationMs: Math.max(1, endedMs - startedMs),
      samples: slice,
    };
  }

  async function saveAdaptiveHold(
    hold: AdaptiveStaticHold,
    startedMs: number,
    endedMs: number,
    outcome: "good" | "failed",
    note?: string,
  ) {
    if (savedSegsRef.current.has(hold.segmentIndex)) return;
    // Claim before building or persisting. Manual Stop, disconnect recovery,
    // the sample effect and sign-out salvage can all converge on this hold.
    savedSegsRef.current.add(hold.segmentIndex);
    const rec = buildAdaptiveRecording(
      hold,
      tindeq.samplesRef.current,
      startedMs,
      endedMs,
      outcome,
      note,
    );
    if (!rec) {
      savedSegsRef.current.delete(hold.segmentIndex);
      return;
    }
    try {
      const saved = await insertRecording(rec);
      outageRef.current = false;
      setRecordings((list) => [saved, ...list]);
      setJustSaved(saved);
    } catch (error) {
      setListError(error instanceof Error ? error.message : "Failed to save recording");
      await queueFailedRecording(rec);
    }
  }

  function buildAdaptiveStaticSalvage(
    samples: readonly TindeqSample[],
  ): (NewTindeqRecording & { id: string })[] | null {
    const machine = adaptiveStaticRef.current;
    if (!machine) return null;
    // A recovery/complete state has no open hold. Returning [] deliberately
    // suppresses the generic whole-buffer salvage row, which would merge
    // already-saved adaptive reps and their rests into a false free hold.
    if (machine.phase !== "hold") return [];
    const hold = adaptiveHoldsRef.current[machine.holdIndex];
    if (!hold || savedSegsRef.current.has(hold.segmentIndex)) return [];
    savedSegsRef.current.add(hold.segmentIndex);
    const endedMs = samples.at(-1)?.t ?? machine.lastMs;
    const rec = buildAdaptiveRecording(
      hold,
      samples,
      machine.startedMs,
      endedMs,
      "failed",
      "Recovered after sign-out · Hands-free protocol attempt failed",
    );
    if (!rec) {
      savedSegsRef.current.delete(hold.segmentIndex);
      return [];
    }
    return [rec];
  }

  /// Save one continuous Reverse Action SET. Completed-set autosave, manual
  /// Stop and interruption recovery all enter here; the run/set claim is made
  /// before the first persistence await by `persistReverseActionSetOnce`.
  async function saveReverseActionSet(
    set: number,
    endMsOverride?: number,
    note = "",
  ) {
    const runId = protocolRunIdRef.current;
    const snapshot = reverseSalvageStateRef.current;
    const protocol = snapshot.protocol;
    const runTimeline = snapshot.timeline;
    if (!runId || !protocol || !runTimeline) return;
    const targetKg = presetTargetKg(protocol, snapshot.refs, set);
    const band = reverseActionTargetBand(
      targetKg,
      protocol.toleranceMode ?? "percent",
      protocol.toleranceValue ?? 10,
    );
    if (!band) return;
    const key = reverseActionSetKey(runId, set);
    let id = reverseSetIdsRef.current.get(key);
    if (!id) {
      id = crypto.randomUUID();
      reverseSetIdsRef.current.set(key, id);
    }
    const rec = buildReverseActionSetRecording({
      id,
      samples: tindeq.samplesRef.current,
      timeline: runTimeline,
      set,
      physicalEndMs: endMsOverride,
      protocolShiftS: snapshot.protocolShiftS,
      targetBand: band,
      cadenceOutS: protocol.cadenceOutS ?? 3,
      cadenceReturnS: protocol.cadenceReturnS ?? 3,
      base: {
        note,
        tag: snapshot.tag,
        side: snapshot.side,
        groupId:
          reverseRunGroupIdRef.current ?? snapshot.groupId ?? ensureSession(),
        protocolRunId: runId,
        zone: performedQuality(protocol, targetKg, snapshot.refs, set),
        setupNote: protocol.setupNote ?? "",
        capacityEvidence: protocol.capacityEvidence ?? false,
      },
    });
    if (!rec) return;
    const outcome = await persistReverseActionSetOnce(
      key,
      reverseSetClaimsRef.current,
      rec,
      async (input) => {
        const saved = await insertRecording(input);
        outageRef.current = false;
        setRecordings((list) => [saved, ...list]);
        setJustSaved(saved);
      },
      queueFailedRecording,
    );
    if (outcome === "lost") {
      setListError("Failed to save Reverse Action set");
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
  async function handleStop(note = "", endMs?: number) {
    if (stopInFlightRef.current) return;
    stopInFlightRef.current = true;
    try {
      await runStop(note, endMs);
    } finally {
      stopInFlightRef.current = false;
    }
  }

  async function runStop(note: string, endMs?: number) {
    const adaptive = adaptiveStaticRef.current;
    if (adaptive) {
      // Claim the whole adaptive stop before any save/transport await. A
      // manual Stop and deferred disconnect recovery must not both own it.
      adaptiveStaticRef.current = null;
      handsFreeControlRef.current = idleHandsFreeForce();
      setSaving(true);
      try {
        if (adaptive.phase === "hold") {
          const hold = adaptiveHoldsRef.current[adaptive.holdIndex];
          if (hold) {
            await saveAdaptiveHold(
              hold,
              adaptive.startedMs,
              endMs ?? tindeq.elapsedMs,
              "failed",
              note || "Hands-free protocol attempt failed",
            );
          }
        }
        await tindeq.stop();
        void endTindeqLiveActivity();
      } finally {
        setSaving(false);
        adaptiveRunSnapshotRef.current = null;
        setAdaptiveStaticState(adaptive.phase === "complete" ? adaptive : null);
      }
      return;
    }
    // #298 round 5: `timeline` is itself derived from the LOCKED gauge
    // inputs, which now stay locked for as long as `runActive` — measuring OR
    // `tindeq.pendingInterruption` — not just `measuring` alone (finding 1).
    // That matters here specifically: a mid-run BLE drop sets `measuring`
    // false in the same render it claims the interruption, and THIS call is
    // what the deferred stop effect runs to finish that drop. Without the
    // wider `runActive` window, a tag/protocol change (or a "Clear — free
    // hold" tap) landing in the gap between the drop and this call would
    // re-derive a different (or absent) `timeline` right underneath it,
    // taking the guided per-rep branch below when the run that's actually
    // finishing was guided (or vice versa) — the double-count hazard
    // CLAUDE.md warns about for guided protocols. `pendingInterruption` is
    // cleared inside `tindeq.stop()` below, i.e. exactly when the run is
    // really over, so there is nothing further to freeze here.
    const runTimeline = timeline;
    if (runTimeline) {
      const tMs = tindeq.elapsedMs;
      const physS = tMs / 1000;
      // Walk the timeline in PROTOCOL time (physical clock + Pause/Skip shift).
      const effS = (pausedAtS ?? physS) + protoShiftS;
      const endPhysMs = (pausedAtS ?? physS) * 1000; // physical clock at effS
      setSaving(true);
      try {
        // Flush any completed-but-unflushed holds, then a ≥1s partial hold.
        let idx = runTimeline.findIndex((s) => effS < s.startS + s.durS);
        if (idx === -1) idx = runTimeline.length;
        const reverseSnapshot = reverseSalvageStateRef.current;
        const reverseTimeline = reverseSnapshot.protocol
          ? reverseSnapshot.timeline
          : null;
        const reverseShiftS = reverseSnapshot.protocolShiftS;
        for (let i = savedThroughRef.current; i < idx; i++) {
          const seg = runTimeline[i]!;
          if (seg.phase === "hold") await saveHoldSlice(seg, i);
          if (reverseTimeline && completesReverseActionSetAt(reverseTimeline, i)) {
            await saveReverseActionSet(seg.set);
          }
        }
        savedThroughRef.current = idx;
        const pos = timelineAt(runTimeline, effS);
        // idx is the current (in-progress) segment — same key the autosave
        // effect would use, so the guard dedupes the two paths.
        if (
          pos &&
          pos.seg.phase === "hold" &&
          endPhysMs - (pos.seg.startS - protoShiftS) * 1000 >= 1000
        ) {
          await saveHoldSlice(pos.seg, idx, endPhysMs);
        }
        if (reverseTimeline && pos?.seg.phase === "move") {
          const window = reverseActionSetWindow(reverseTimeline, pos.seg.set);
          const physicalSetStartMs = window
            ? (window.startS - reverseShiftS) * 1000
            : endPhysMs;
          if (endPhysMs - physicalSetStartMs >= 1000) {
            await saveReverseActionSet(pos.seg.set, endPhysMs, note);
          }
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
    // #298 round 6 (finding B1): the LOCKED gaugeInputs.pendingTag/.pendingSide,
    // not the raw state — same reasoning as saveHoldSlice above. This branch
    // is only reachable while TagSideEditor is disabled (runActive), so raw
    // and locked agree today, but reading raw here was reachable "only by
    // convention" — exactly the class of bug CLAUDE.md's #196 note warns about.
    const { tag, side } =
      note === ""
        ? { tag: gaugeInputs.pendingTag, side: gaugeInputs.pendingSide }
        : recoveredTagSide(
            { tag: gaugeInputs.pendingTag, side: gaugeInputs.pendingSide },
            tindeq.interruptionContext,
          );
    const summary = await tindeq.stop(endMs);
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
  const { status } = tindeq;
  const measuring = status === "measuring";
  const armed = status === "armed";
  // #298 round 5 (finding 1): a mid-measurement BLE drop batches
  // `setStatus("idle")` with claiming the interruption in the SAME render
  // (useTindeq's handleDeviceDropped), so `measuring` alone already reads
  // false before the deferred stop that actually finishes the run has run.
  // The gauge-input lock below holds for as long as `runActive` — releasing
  // only once `tindeq.stop()` (inside that deferred stop) clears
  // `pendingInterruption`, i.e. exactly when the run is really over.
  const runActive = measuring || armed || tindeq.pendingInterruption || manualOpen || cadenceRun !== null;
  const trimmedTag = pendingTag.trim();
  const liveEffectiveTag = allTags.includes(trimmedTag)
    ? trimmedTag
    : (allTags[0] ?? null);
  // #298: an alternating protocol trains BOTH hands, so its curve reference
  // must never lock to one — chartSide feeds zoneTag → armedZone's target
  // below AND filters which recordings compute the curve (curveRecordings
  // below), so a leftover single-side pick would silently target (and
  // curve-fit) one hand's data for a two-handed run. `armedAlternates` reads
  // straight off zoneSel/preset (see zoneSelection.ts) rather than off
  // `activeProtocol` below, which is itself derived FROM chartSide/zoneTag
  // and would make this circular.
  const liveChartSide = chartSideFor(armedAlternates(preset, zoneSel), pendingSide);
  // #298 round 5 (finding 3): the live PR — from the CURRENT tag/side, not
  // the already-locked `effectiveTag`/`chartSide` below (this feeds the same
  // struct those are locked through, so using the locked version here would
  // be circular).
  // Capacity recordings only — maintenance holds must never win this PR,
  // even by walkover.
  const liveCapacityModality = protocolModality;
  const livePrKg = effortPeakKg(
    recordings,
    liveEffectiveTag,
    liveChartSide,
    liveCapacityModality,
  );
  const liveGaugeInputs: GaugeInputs = {
    tag: liveEffectiveTag,
    chartSide: liveChartSide,
    zoneSel,
    preset,
    intensityPct,
    // #298 round 5 (finding 2): the raw Exercise&Side fields, separate from
    // `tag` above — see the field's own doc in gaugeInputLock.ts.
    pendingTag: trimmedTag,
    pendingSide,
    prKg: livePrKg,
  };
  // #298 round 5: hold the gauge inputs (tag, side, raw pendingTag/
  // pendingSide, the armed zone/preset selection, intensity, and PR)
  // constant for the whole duration of a run — see gaugeInputLock.ts for why
  // this replaced freezing the derived protocol/timeline instead. Computed
  // every render (the React "storing information from previous renders"
  // pattern, not an effect) so there is no one-render lag: the very render
  // `runActive` turns true already reads the correct snapshot, because
  // `lockedGaugeInputs` was kept synced to the live values on every render up
  // to that point.
  const [lockedGaugeInputs, setLockedGaugeInputs] = useState<GaugeInputs>(liveGaugeInputs);
  const gaugeInputs = nextLockedGaugeInputs(runActive, liveGaugeInputs, lockedGaugeInputs);
  if (gaugeInputs !== lockedGaugeInputs) setLockedGaugeInputs(gaugeInputs);
  const effectiveTag = gaugeInputs.tag;
  const chartSide = gaugeInputs.chartSide;
  const capacityModality = protocolModality;

  // The composed exercise label a zone selection arms/re-arms under (matches
  // the `tag` prop TargetZonesCard/ZoneFocusCard render with). Null while no
  // tag is selected yet.
  const zoneTag = effectiveTag ? (chartSide ? `${effectiveTag} · ${chartSide}` : effectiveTag) : null;

  // Auto-compute the force curve for the active tag/side (default show — no
  // "Compute" button). All state writes happen in async callbacks; "which key
  // the model belongs to" is tracked so computing/model are derived, not
  // synced.
  // Maintenance protocols are excluded from curve candidacy: neither is a
  // maximal-intent observation, so neither can feed a capacity model.
  const curveRecordings = curveCandidateRecordings(
    recordings,
    effectiveTag,
    chartSide,
    capacityModality,
  );
  const tagSideKey = `${effectiveTag ?? ""}|${chartSide ?? "all"}|${capacityModality}`;
  const curveKey = `${tagSideKey}|${curveRecordings.length}`;
  const canComputeCurve = effectiveTag !== null && curveRecordings.length > 0;
  // Frozen for the whole run, not just while `measuring` (#298): the stop flow
  // runs during the `pendingInterruption` gap, when `runStop` is still flushing
  // per-rep saves. Keying this on `measuring` alone let the recompute refire in
  // that gap — exactly the SL-80 short-hold flood that can null CF, and it can
  // reach `saveTagCurve`, which the watch reads back for RPE prediction.
  const curveFrozen = runActive;
  useEffect(() => {
    if (!canComputeCurve) return;
    // Freeze mid-run (SL-80): every per-rep save bumps the count and would
    // trigger a recompute whose short-hold flood can null CF — taking the
    // armed target away mid-set. Recompute on stop instead.
    if (curveFrozen) return;
    let cancelled = false;
    // Best per duration bucket over a long window — NOT the latest N, which a
    // burst of short reps floods (SL-80).
    //
    // #298 round 5: `react-hooks/purity` flags this `Date.now()` call, but
    // it's a false positive from this rule attributing the pure-updater
    // requirement of the functional state update below onto the WHOLE
    // effect callback — effects (this one included) are allowed to be
    // impure; only the updater passed to `setZoneState` itself needs to be a
    // pure function of its current argument, and it is
    // (`postFitZoneDecision` is pure). Confirmed by isolating this exact call:
    // removing the functional state update below makes the diagnostic
    // disappear with nothing else changed.
    // eslint-disable-next-line react-hooks/purity
    const now = Date.now();
    const fitZoneRevision = zoneState.revision;
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
    // Bounded (#298): `zoneCurvePending` disables Start until this settles, so
    // a request that HANGS rather than rejecting would leave Start dead for the
    // rest of the session under a message telling the user to wait a moment.
    // Rejecting on a deadline routes into the `.catch` below, which records the
    // failure and advances `curveComputedFor` — Start comes back, and the armed
    // zone falls back to the already-documented "no fit for this tag" tradeoff
    // instead of a dead button. Longer than `predictGroupRpe`'s 4s because this
    // fetches every sample stream behind the curve, not two numbers.
    let curveTimeoutId: ReturnType<typeof setTimeout> | undefined;
    Promise.race([
      Promise.all(ids.map((id) => fetchRecordingSamples(id))),
      new Promise<never>((_, reject) => {
        curveTimeoutId = setTimeout(
          () => reject(new Error("Timed out fetching recordings for this curve.")),
          15_000,
        );
      }),
    ])
      .finally(() => clearTimeout(curveTimeoutId))
      .then((all) => {
        if (cancelled) return;
        const samplesById = new Map(ids.map((id, i) => [id, all[i]!]));
        const m = computeForceCurve(recs.map((r) => samplesById.get(r.id)!));
        setCurveModel(m);
        // #298: this tag/side's fit just settled — if the zone currently
        // armed can no longer be derived against it (e.g. the new tag has no
        // CF), disarm for real rather than leaving a `zoneSel` that renders
        // as a free hold now but would resurrect if the model changes again.
        // Functional update (never the `zoneSel` closed over at effect-
        // creation time) per the CLAUDE.md stale-closure rule — this `.then`
        // can resolve after the user has since armed a different zone.
        setZoneState((current) =>
          postFitZoneDecision(
            current,
            m,
            zoneTag,
            intensityPctRef.current,
            fitZoneRevision,
          ),
        );
        setPeriodCurves(
          periodPicks.map((p) => ({
            label: p.label,
            days: p.days,
            model: p.recs.length
              ? computeForceCurve(
                  p.recs.map((r) => samplesById.get(r.id)!),
                  { bootstrapSamples: 0 },
                )
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
            modality: capacityModality,
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
    // curveKey encodes tag/side/count — the actual deps of the curve FETCH.
    // intensityPct also feeds the disarm check above but is read through
    // intensityPctRef, not this closure, precisely so it doesn't need to be
    // (and doesn't need to trigger a re-fetch on every dial nudge).
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

  // #331: alternating recommended zones resolve two independent fits in
  // parallel. The all-sides curve above remains the chart/reference outside
  // a run; it is never borrowed for a missing hand.
  const alternatingArmed = armedAlternates(gaugeInputs.preset, gaugeInputs.zoneSel);
  const leftCurveRecordings = curveCandidateRecordings(
    recordings,
    effectiveTag,
    "left",
    capacityModality,
  );
  const rightCurveRecordings = curveCandidateRecordings(
    recordings,
    effectiveTag,
    "right",
    capacityModality,
  );
  const alternatingCurveKey = alternatingCurveInputKey(
    effectiveTag,
    leftCurveRecordings,
    rightCurveRecordings,
  );
  const [alternatingModels, setAlternatingModels] = useState<{
    left: ForceCurveModel | null;
    right: ForceCurveModel | null;
  }>({ left: null, right: null });
  const [alternatingComputedFor, setAlternatingComputedFor] = useState<string | null>(null);
  useEffect(() => {
    if (!effectiveTag || curveFrozen) return;
    let cancelled = false;
    // `alternatingComputedFor !== alternatingCurveKey` marks this exact
    // request pending before its first await; the previous tag's pair cannot
    // pass the key check while this one resolves.
    const fit = async (rows: (TindeqRecordingMeta & { peakKg: number; avgKg: number })[]) => {
      if (rows.length === 0) return null;
      const picked = pickCurveRecordings(rows, Date.now());
      const samples = await Promise.all(picked.map((r) => fetchRecordingSamples(r.id)));
      return computeForceCurve(samples);
    };
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    Promise.race([
      Promise.all([fit(leftCurveRecordings), fit(rightCurveRecordings)]),
      new Promise<never>((_, reject) => {
        timeoutId = setTimeout(
          () => reject(new Error("Timed out fetching both hand curves.")),
          15_000,
        );
      }),
    ])
      .finally(() => clearTimeout(timeoutId))
      .then(([left, right]) => {
        if (cancelled) return;
        setAlternatingModels({ left, right });
        setAlternatingComputedFor(alternatingCurveKey);
      })
      .catch(() => {
        if (cancelled) return;
        setAlternatingModels({ left: null, right: null });
        setAlternatingComputedFor(alternatingCurveKey);
      });
    return () => {
      cancelled = true;
    };
    // The key includes each candidate's identity and fit-relevant metadata;
    // the arrays themselves are fresh each render and would refetch forever
    // if listed directly.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [alternatingCurveKey, curveFrozen, effectiveTag]);
  const alternatingModelsSettled = alternatingComputedFor === alternatingCurveKey;
  const alternatingInputs = {
    left: {
      model: alternatingModelsSettled ? alternatingModels.left : null,
      prKg: effortPeakKg(recordings, effectiveTag, "left", capacityModality),
    },
    right: {
      model: alternatingModelsSettled ? alternatingModels.right : null,
      prKg: effortPeakKg(recordings, effectiveTag, "right", capacityModality),
    },
  };

  // PR for the active exercise (+side) — the same best-peak the trend chart
  // marks as PR. Anchors presets whose target is a % of PR.
  // #298 round 5 (finding 3): read from the LOCKED gauge inputs, not
  // recomputed from `curveRecordings` here — that list grows on every
  // per-rep save, so a `pctBasis: "pr"` preset would otherwise move its
  // target mid-set the instant an early rep sets a new PR.
  const prKg = gaugeInputs.prKg;

  // Freeze the fit itself, independently of the fetch freeze. This makes the
  // prescription invariant explicit even if a previously-started async refit
  // resolves after Start; future runs see it only after the active run ends.
  const liveCapabilityFit = model?.capabilityFit ?? null;
  const [lockedCapabilityFit, setLockedCapabilityFit] = useState(liveCapabilityFit);
  const capabilityFit = nextLockedCapabilityFit(runActive, liveCapabilityFit, lockedCapabilityFit);
  if (capabilityFit !== lockedCapabilityFit) setLockedCapabilityFit(capabilityFit);

  // Force references a preset resolves its target against. `model` cannot
  // recompute while a run is active, so capabilityFit freezes atomically with
  // PR/tag/side and only refreshes after Stop.
  const presetRefs = {
    prKg,
    cf: model?.cf ?? null,
    wPrime: model?.wPrime ?? null,
    maxF: model?.maxF ?? null,
    capabilityFit,
  };

  // #298: `zoneSel` bakes its tag + kg at the moment a zone is picked, so it
  // goes stale the instant tag/side changes afterwards (the fullscreen's tag
  // chips, most visibly). Re-derive for the CURRENT tag/side/intensity on
  // every render — derive, don't sync — rather than reading `zoneSel`
  // directly below. While the curve is recomputing for a new tag `model` is
  // momentarily null; `rederiveSelection` HOLDS the current selection rather
  // than disarming on a null model (a still-fitting curve isn't a rejection —
  // see its own doc comment), so this keeps the guided UI/gauge band up
  // through the recompute and re-derives to the new tag once the model lands.
  // #298 round 4: reads `gaugeInputs.zoneSel`/`.intensityPct`, not the raw
  // `zoneSel`/`intensityPct` state — locked for the run's duration, so this
  // stays put mid-run exactly like `effectiveTag`/`chartSide` above.
  const armedZone = rederiveSelection(
    gaugeInputs.zoneSel,
    model,
    zoneTag,
    gaugeInputs.intensityPct,
    prKg,
  );
  const alternatingQuality = selectedQuality(gaugeInputs.zoneSel);
  const alternatingMaintenance =
    gaugeInputs.zoneSel?.protocol.id === "zone:warmup" ||
    gaugeInputs.zoneSel?.protocol.id === "zone:prehab";
  const liveAlternatingPrescription = gaugeInputs.preset?.alternateSides
    ? resolveAlternatingPreset(gaugeInputs.preset, alternatingInputs)
    : alternatingMaintenance && gaugeInputs.zoneSel && alternatingModelsSettled
      ? resolveAlternatingMaintenance(gaugeInputs.zoneSel.protocol, alternatingInputs)
      : alternatingArmed && alternatingQuality && effectiveTag && alternatingModelsSettled
        ? resolveAlternatingRecommendation(
            alternatingInputs,
            alternatingQuality,
            effectiveTag,
            gaugeInputs.intensityPct,
            gaugeInputs.zoneSel?.protocol.sets ?? 1,
          )
        : null;
  const alternatingTargetNeedsBoth =
    alternatingArmed &&
    (alternatingQuality !== null || alternatingMaintenance ||
      (gaugeInputs.preset !== null && needsHandReferences(gaugeInputs.preset)));
  const alternatingReferencesPending =
    alternatingTargetNeedsBoth && effectiveTag !== null && !alternatingModelsSettled;
  // Keep the exact two-hand snapshot used at Start for the entire run. This
  // mirrors the gauge-input lock above: while idle, the stored value follows
  // the live derivation; while active, rendering stays on the stored value.
  const [lockedAlternatingPrescription, setLockedAlternatingPrescription] =
    useState<AlternatingPrescription | null>(liveAlternatingPrescription);
  const alternatingPrescription = nextLockedAlternatingPrescription(
    runActive,
    liveAlternatingPrescription,
    lockedAlternatingPrescription,
  );
  if (alternatingPrescription !== lockedAlternatingPrescription) {
    setLockedAlternatingPrescription(alternatingPrescription);
  }
  // Async rep saves read this ref. `onStart` snapshots it synchronously before
  // starting the device, so there is no effect-lag window.
  const alternatingPrescriptionRef = useRef<AlternatingPrescription | null>(
    alternatingPrescription,
  );

  // #298 round 6 (finding 3): block Start while the armed zone was built
  // under a DIFFERENT tag than the one now live, and the curve for the new
  // tag is still fetching. Ticking "Alternate left ⇄ right" is the reliable
  // repro: it flips `chartSideFor` to null in the very next render, changing
  // `zoneTag` out from under a selection baked for one side — `armedZone`
  // above HOLDS that stale selection (a still-fitting curve isn't a
  // rejection, see `rederiveSelection`'s own doc), so a Start landing in this
  // window would freeze the curve fetch (`curveFrozen`) and run the WHOLE set
  // against the wrong tag's numbers. Gated on `curveComputing`, not just
  // "model is null" — a tag that will NEVER get a curve (0 recordings) must
  // not block Start forever; see `armedForDifferentTag`'s own doc.
  const zoneCurvePending = armedForDifferentTag(gaugeInputs.zoneSel, zoneTag) && curveComputing;

  // One guided-timer path: `selectZone`/`selectPreset` (#296) keep the two
  // selections mutually exclusive, so at most one of these is non-null — the
  // `??` here is just picking whichever is armed, not a precedence rule. The
  // chart band comes from the preset's target (kg, %-of-PR/CF, or the smart
  // curve — set 1 here; the fullscreen ramps it per set), else the zone.
  // `gaugeInputs.preset`, not raw `preset` (#298 round 4) — locked for the
  // run's duration alongside the zone selection above.
  const activeProtocol: TindeqPreset | null =
    gaugeInputs.preset ?? alternatingPrescription?.protocol ?? armedZone?.protocol ?? null;
  // The explicit protocol-list context owns the informational guide too, so
  // switching modes updates the guidance even before a preset is armed.
  const setupMode: ForceMeasurementMode =
    protocolModality === "reverse_action" ? "movement" : "static";
  const presetKgSet1 = gaugeInputs.preset ? presetTargetKg(gaugeInputs.preset, presetRefs, 1) : null;
  const reverseBand =
    gaugeInputs.preset?.protocolMode === "reverse_action"
      ? reverseActionTargetBand(
          presetKgSet1,
          gaugeInputs.preset.toleranceMode ?? "percent",
          gaugeInputs.preset.toleranceValue ?? 10,
        )
      : null;
  const bandTarget: GaugeTarget | null =
    gaugeInputs.preset && presetKgSet1 != null
      ? {
          kg: presetKgSet1,
          lowKg: reverseBand?.lowKg ?? presetKgSet1 * 0.9,
          highKg: reverseBand?.highKg ?? presetKgSet1 * 1.1,
          workS: prescriptionWorkS(gaugeInputs.preset, 1),
          label: gaugeInputs.preset.name,
        }
      : (armedZone?.target ?? null);
  const activeProtocolQuality = activeProtocol
    ? performedQuality(
        activeProtocol,
        presetKgSet1 ?? bandTarget?.kg ?? null,
        presetRefs,
        1,
      )
    : null;

  // The armed protocol selects the matching informational guide. The guide is
  // optional: it does not remember, approve, or gate a physical setup.

  // Move the global intensity dial (the slider on TargetZonesCard, #172):
  // persist + update state, and if a zone is currently armed, re-arm it at the
  // new pct so its baked target/timer numbers update immediately. Custom
  // presets are UNAFFECTED by this dial — their load is never rescaled, only
  // recommended zones respond to it (see `applyIntensity`).
  // #298 round 5: TargetZonesCard disables the slider (and every other
  // control that would touch this) for as long as `runActive`, so this is
  // unreachable mid-run in practice — even so, it writes the raw
  // `intensityPct` state, which `gaugeInputs` (and everything armed/timed
  // off it) ignores until the run ends, per the input lock above.
  function changeIntensity(pct: number) {
    const next = Math.min(ZONE_INTENSITY.max, Math.max(ZONE_INTENSITY.min, pct));
    if (next === intensityPct) return;
    setIntensityPct(next);
    saveIntensity(next);
    setZoneState((current) => ({
      ...current,
      selection: applyIntensity(current.selection, model, zoneTag, next),
    }));
  }

  // Get-ready countdown preference (5s PREPARE before the first hold).
  const [prepare, setPrepare] = useState(
    () => localStorage.getItem("sendmeter:gauge-prepare") !== "0",
  );
  function togglePrepare(on: boolean) {
    setPrepare(on);
    localStorage.setItem("sendmeter:gauge-prepare", on ? "1" : "0");
  }

  function toggleHandsFree(on: boolean) {
    setHandsFreeEnabled(on);
    localStorage.setItem("sendmeter:gauge-hands-free", on ? "1" : "0");
  }

  function toggleTargetCoach(on: boolean) {
    setTargetCoachEnabled(on);
    localStorage.setItem("sendmeter:gauge-zone-coach", on ? "1" : "0");
  }

  async function armHandsFree() {
    if (handsFreeArmInFlightRef.current || tindeq.status !== "connected") return;
    handsFreeArmInFlightRef.current = true;
    handsFreeControlRef.current = armedHandsFreeForce();
    setJustSaved(null);
    setProtoShiftS(0);
    setPausedAtS(null);
    protocolRunIdRef.current = null;
    if (timeline && activeProtocol && activeProtocol.protocolMode !== "reverse_action") {
      adaptiveHoldsRef.current = adaptiveStaticHolds(timeline as ProtocolSegment[]);
      adaptiveStaticRef.current = armAdaptiveStatic();
      setAdaptiveStaticState(adaptiveStaticRef.current);
      protocolRunIdRef.current = crypto.randomUUID();
      savedSegsRef.current = new Set();
      const runId = protocolRunIdRef.current ?? crypto.randomUUID();
      protocolRunIdRef.current = runId;
      adaptiveRunSnapshotRef.current = {
        protocol: activeProtocol,
        tag: gaugeInputs.pendingTag,
        side: gaugeInputs.pendingSide,
        refs: { ...presetRefs },
        alternatingPrescription,
        groupId: null,
        runId,
      };
    } else {
      adaptiveStaticRef.current = null;
      adaptiveRunSnapshotRef.current = null;
      setAdaptiveStaticState(null);
    }
    const didArm = await tindeq.arm();
    if (!didArm) {
      handsFreeControlRef.current = idleHandsFreeForce();
      adaptiveStaticRef.current = null;
      adaptiveRunSnapshotRef.current = null;
      setAdaptiveStaticState(null);
    }
    handsFreeArmInFlightRef.current = false;
  }

  function cancelHandsFreeArm() {
    // Claim cancellation synchronously; samples arriving while the BLE stop
    // command is in flight cannot re-trigger Start.
    handsFreeControlRef.current = idleHandsFreeForce();
    adaptiveStaticRef.current = null;
    adaptiveRunSnapshotRef.current = null;
    setAdaptiveStaticState(null);
    void tindeq.cancelArm();
  }

  function stopHandsFreeNow() {
    if (adaptiveStaticRef.current) {
      void handleStop();
      return;
    }
    if (handsFreeControlRef.current.phase === "recording") {
      handsFreeControlRef.current = { phase: "stopping" };
    }
    void handleStop();
  }

  // The expanded protocol timeline — built here (not in the fullscreen) so
  // the per-rep recorder below and the countdown display walk the SAME
  // segments and can never disagree. Cheap to rebuild per render. #298 round
  // 4: `activeProtocol` is itself derived from the LOCKED gauge inputs above,
  // so this is automatically stable for the whole run — one plan, nothing to
  // keep in sync separately.
  const timeline: ForceTimelineSegment[] | null = activeProtocol
    ? activeProtocol.protocolMode === "reverse_action"
      ? buildReverseActionTimeline({
          reps: activeProtocol.reps,
          sets: activeProtocol.sets,
          cadenceOutS: activeProtocol.cadenceOutS ?? 3,
          cadenceReturnS: activeProtocol.cadenceReturnS ?? 3,
          restSetsS: activeProtocol.restSetsS,
          prepareS: activeProtocol.prepareS ?? 5,
        })
      : buildTimeline(activeProtocol, {
          switchS: 3,
          prepareS: prepare ? 5 : 0,
          alternatingHolds: alternatingHoldDurations(alternatingPrescription),
        })
    : null;

  // Per-rep recorder: as the measurement clock passes each hold segment,
  // slice it out of the sample buffer and save it as its own recording.
  // Reset happens on the measuring rising edge (not on measuring→false) so an
  // involuntary disconnect can still flush the un-saved holds without
  // double-saving the ones this effect already wrote.
  const savedThroughRef = useRef(0);
  const wasMeasuringRef = useRef(false);
  const reverseCompletionClaimRef = useRef(false);
  // Protocol seconds = physical clock (frozen while paused) + Pause/Skip shift.
  const protoTS = (pausedAtS ?? tindeq.elapsedMs / 1000) + protoShiftS;
  const paused = pausedAtS !== null;
  const reverseSalvageStateRef = useRef<{
    protocol: TindeqPreset | null;
    timeline: ReverseActionSegment[] | null;
    refs: typeof presetRefs;
    tag: string;
    side: TindeqSide;
    groupId: string | null;
    protocolShiftS: number;
  }>({
    protocol: null,
    timeline: null,
    refs: presetRefs,
    tag: "",
    side: "",
    groupId: null,
    protocolShiftS: 0,
  });
  useLayoutEffect(() => {
    reverseSalvageStateRef.current = {
      protocol:
        activeProtocol?.protocolMode === "reverse_action" ? activeProtocol : null,
      timeline:
        activeProtocol?.protocolMode === "reverse_action"
          ? (timeline as ReverseActionSegment[])
          : null,
      refs: {
        prKg: presetRefs.prKg,
        cf: presetRefs.cf,
        wPrime: presetRefs.wPrime,
        maxF: presetRefs.maxF,
        capabilityFit: presetRefs.capabilityFit,
      },
      tag: gaugeInputs.pendingTag,
      side: gaugeInputs.pendingSide,
      groupId: gaugeSession?.groupId ?? null,
      protocolShiftS: protoShiftS,
    };
  }, [
    activeProtocol,
    gaugeInputs.pendingSide,
    gaugeInputs.pendingTag,
    gaugeSession,
    presetRefs.capabilityFit,
    presetRefs.cf,
    presetRefs.maxF,
    presetRefs.prKg,
    presetRefs.wPrime,
    protoShiftS,
    timeline,
  ]);

  function buildReverseSalvageRecordings(
    samples: readonly TindeqSample[],
  ): (NewTindeqRecording & { id: string })[] | null {
    const snapshot = reverseSalvageStateRef.current;
    const runId = protocolRunIdRef.current;
    if (!snapshot.protocol || !snapshot.timeline || !runId) return null;
    const protocol = snapshot.protocol;
    const reverseTimeline = snapshot.timeline;
    return buildUnclaimedReverseActionSalvage({
      samples,
      timeline: reverseTimeline,
      sets: protocol.sets,
      runId,
      claims: reverseSetClaimsRef.current,
      ids: reverseSetIdsRef.current,
      createId: () => crypto.randomUUID(),
      protocolShiftS: snapshot.protocolShiftS,
      cadenceOutS: protocol.cadenceOutS ?? 3,
      cadenceReturnS: protocol.cadenceReturnS ?? 3,
      targetBandForSet: (set) =>
        reverseActionTargetBand(
          presetTargetKg(protocol, snapshot.refs, set),
          protocol.toleranceMode ?? "percent",
          protocol.toleranceValue ?? 10,
        ),
      baseForSet: (set) => {
        const targetKg = presetTargetKg(protocol, snapshot.refs, set);
        return {
          note: "Recovered after sign-out",
          tag: snapshot.tag,
          side: snapshot.side,
          groupId: reverseRunGroupIdRef.current ?? snapshot.groupId,
          protocolRunId: runId,
          zone: performedQuality(
            protocol,
            targetKg,
            snapshot.refs,
            set,
          ),
          setupNote: protocol.setupNote ?? "",
          capacityEvidence: protocol.capacityEvidence ?? false,
        };
      },
    });
  }
  useEffect(() => {
    if (measuring && !wasMeasuringRef.current) {
      savedThroughRef.current = 0;
      savedSegsRef.current = new Set();
      reverseSetClaimsRef.current = new Set();
      reverseSetIdsRef.current = new Map();
      reverseCompletionClaimRef.current = false;
    }
    wasMeasuringRef.current = measuring;
    if (!measuring || !timeline || adaptiveStaticRef.current) return;
    const tS = protoTS;
    let idx = timeline.findIndex((s) => tS < s.startS + s.durS);
    if (idx === -1) idx = timeline.length;
    for (let i = savedThroughRef.current; i < idx; i++) {
      const seg = timeline[i]!;
      if (seg.phase === "hold") void saveHoldSlice(seg, i);
      if (
        activeProtocol?.protocolMode === "reverse_action" &&
        completesReverseActionSetAt(timeline as ReverseActionSegment[], i)
      ) {
        void saveReverseActionSet(seg.set);
      }
    }
    if (idx > savedThroughRef.current) savedThroughRef.current = idx;
    // saveHoldSlice is stable enough for this use (reads refs/state at call
    // time); depending on it would re-run every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [measuring, timeline, protoTS]);

  useEffect(() => {
    if (
      !measuring ||
      activeProtocol?.protocolMode !== "reverse_action" ||
      !timeline ||
      reverseCompletionClaimRef.current
    ) {
      return;
    }
    const last = timeline.at(-1);
    if (!last || protoTS < last.startS + last.durS) return;
    // Claim before calling the async Stop path. A completion tick, emergency
    // Stop and disconnect can all land together; only one may own the buffer.
    reverseCompletionClaimRef.current = true;
    void handleStop();
    // handleStop reads the current locked run snapshot and refs.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeProtocol?.protocolMode, measuring, protoTS, timeline]);

  useEffect(() => {
    const machine = adaptiveStaticRef.current;
    if (!handsFreeEnabled || !machine || (status !== "armed" && status !== "measuring")) return;
    const stepped = stepAdaptiveStatic(machine, adaptiveHoldsRef.current, {
      atMs: tindeq.elapsedMs,
      kg: tindeq.current,
    });
    adaptiveStaticRef.current = stepped.state;
    setAdaptiveStaticState(stepped.state);
    const action = stepped.action;
    if (!action) return;
    if (action.type === "start") {
      if (status === "armed") {
        const snapshot = adaptiveRunSnapshotRef.current;
        if (snapshot && snapshot.groupId === null) snapshot.groupId = ensureSession();
        if (!tindeq.beginArmedRecording()) {
          adaptiveStaticRef.current = null;
          adaptiveRunSnapshotRef.current = null;
          setAdaptiveStaticState(null);
          return;
        }
        // beginArmedRecording resets the physical sample clock.
        adaptiveStaticRef.current = { ...stepped.state, startedMs: 0, lastMs: 0 } as AdaptiveStaticState;
        setAdaptiveStaticState(adaptiveStaticRef.current);
      }
      return;
    }
    if (action.type === "save") {
      const hold = adaptiveHoldsRef.current[action.holdIndex];
      if (hold) void saveAdaptiveHold(hold, action.startedMs, action.endedMs, action.outcome);
      if (stepped.state.phase === "complete") {
        // `runStop` owns the final transport transition and preserves the
        // complete/failed display. The state-machine action already claimed
        // the final recording before this async path begins.
        void handleStop();
      }
    }
    // All actions were claimed in adaptiveStaticRef before persistence.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [handsFreeEnabled, status, tindeq.current, tindeq.elapsedMs]);

  // Pause / Skip during a guided run. Both first FINALIZE an in-progress hold
  // (save the rep-so-far, mark it done) so the recorder never has to slice a
  // hold across a shift change; then they mutate the protocol clock. Each
  // reads `timeline` (#298 round 4: derived from the LOCKED gauge inputs, so
  // it's already stable for the run's duration — nothing further to freeze).
  function finalizeHoldIfOpen() {
    if (!timeline) return;
    const pos = timelineAt(timeline, protoTS);
    if (!pos || pos.seg.phase !== "hold") return;
    let idx = timeline.findIndex((s) => protoTS < s.startS + s.durS);
    if (idx === -1) idx = timeline.length;
    const physNowMs = (pausedAtS ?? tindeq.elapsedMs / 1000) * 1000;
    // Slice the rep-so-far now; saveHoldSlice claims the index synchronously
    // (savedSegsRef), so the autosave effect's later pass over this index is a
    // harmless no-op — no need to advance savedThroughRef (which the compiler
    // won't allow us to write from here anyway).
    void saveHoldSlice(pos.seg, idx, physNowMs);
  }
  function skipSegment() {
    if (!measuring || !timeline || activeProtocol?.protocolMode === "reverse_action") return;
    const pos = timelineAt(timeline, protoTS);
    if (!pos) return;
    finalizeHoldIfOpen();
    // Jump protocol time to the end of the current segment (= next segment's
    // start); the physical clock is unchanged, so the next segment begins now.
    setProtoShiftS((s) => s + pos.remaining);
  }
  function togglePause() {
    if (!measuring || activeProtocol?.protocolMode === "reverse_action") return;
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
      // #298 round 6 (finding B2): the LOCKED gaugeInputs.pendingTag/
      // .pendingSide, not the raw state — this is the path a crash/disconnect
      // recovery falls back to, so it matters MORE than the others: reading
      // raw state here would file a mid-run salvage under whatever tag/side
      // happened to be typed at the moment things went wrong, not the tag/
      // side the run was actually armed under.
      tag: gaugeInputs.pendingTag,
      side: gaugeInputs.pendingSide,
      groupId: gaugeSession?.groupId ?? null,
      // The signed-in user, always known here — without this a salvaged
      // recording would fall to enqueueRecording's null-userId path, which
      // ANY signed-in user can drain (real risk on a shared device using
      // throwaway dev accounts, not just hypothetical).
      userId,
      stopInFlight: stopInFlightRef.current,
      buildSalvageRecordings: (samples) =>
        buildAdaptiveStaticSalvage(samples) ?? buildReverseSalvageRecordings(samples),
    }));
    // setSalvageContext itself is useCallback-stable ([] deps in useTindeq);
    // depending on the whole `tindeq` object instead would re-run this every
    // animation frame while measuring (its container is a fresh object each
    // TindeqProvider render, since current/peak/elapsedMs tick via rAF).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tindeq.setSalvageContext, gaugeInputs.pendingTag, gaugeInputs.pendingSide, gaugeSession, userId]);

  // Pop the gauge fullscreen the moment the Progressor connects (only on the
  // connecting→connected transition — a stop→connected change must not
  // override a user's minimize). And when it DISCONNECTS with an active
  // session, prompt to finish it (SL-58 #5) — the connection now persists
  // across tabs, so a disconnect is a deliberate end (or the device dying).
  useEffect(() => {
    const machine = handsFreeControlRef.current;
    if (status === "connected" || status === "idle" || status === "unsupported") {
      // `armHandsFree` claims `armed` before awaiting the transport. State
      // updates inside tindeq.arm() can render once with the OLD connected
      // status before its final setStatus("armed") lands; clearing that ref
      // here loses the claim and leaves a loaded fake/real device stuck ARMED.
      // Cancellation claims idle first, and failed arms reset it themselves,
      // so an armed ref while still connected belongs to the in-flight Arm.
      handsFreeControlRef.current = handsFreeForceAtInactiveStatus(machine, status);
      return;
    }
    const observingArmed = status === "armed" && machine.phase === "armed";
    const observingRecording = status === "measuring" && machine.phase === "recording";
    if (!handsFreeEnabled || adaptiveStaticRef.current || (!observingArmed && !observingRecording)) return;

    const releaseStartedMs = machine.phase === "recording" ? machine.belowSinceMs : null;
    const stepped = stepHandsFreeForce(machine, {
      atMs: tindeq.elapsedMs,
      kg: tindeq.current,
    });
    // Claim before either branch can enter an async path (#400 / #295 rule).
    handsFreeControlRef.current = stepped.state;
    if (stepped.action === "start") {
      if (!tindeq.beginArmedRecording()) {
        handsFreeControlRef.current = idleHandsFreeForce();
        return;
      }
      return;
    }
    if (stepped.action === "stop") void handleStop("", releaseStartedMs ?? undefined);
    // `handleStop` owns current refs and its own pre-await re-entrancy claim.
    // The hook callbacks are stable; force/elapsed/status are the sample clock.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status, tindeq.current, tindeq.elapsedMs, handsFreeEnabled]);
  // Keep the screen awake while the gauge is live so a short auto-lock doesn't
  // interrupt a hold/protocol mid-recording.
  useWakeLock(
    status === "connected" || status === "armed" || status === "measuring" || manualOpen || cadenceRun !== null,
  );
  const prevStatusRef = useRef(status);
  useEffect(() => {
    const prev = prevStatusRef.current;
    prevStatusRef.current = status;
    if (status === "connected" && prev === "connecting") {
      setGaugeMinimized(false);
    }
    if (
      status === "idle" &&
      (prev === "connected" || prev === "armed" || prev === "measuring")
    ) {
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
        <button className="btn-primary" onClick={() => {
          void tindeq.connect();
        }}>
          {activeProtocol?.protocolMode === "reverse_action"
            ? "Start with sensor"
            : "Connect Progressor"}
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

      {sensorlessLaunchAvailable(status) && <>
        <button
          className="btn-primary"
          style={{ marginTop: 10, background: "var(--surface-2)", color: "var(--primary)", border: "1px solid var(--primary)" }}
          disabled={!activeProtocol || !pendingTag.trim() || runActive}
          title={!activeProtocol ? "Choose a protocol preset first" : !pendingTag.trim() ? "Add an exercise first" : undefined}
          onClick={() => {
            if (!timeline || !activeProtocol || !pendingTag.trim()) return;
            if (activeProtocol.protocolMode === "reverse_action") {
              const next: CadenceOnlyRunState = {
                version: 1,
                preset: activeProtocol,
                userId,
                tag: pendingTag.trim(),
                side: pendingSide,
                groupId: crypto.randomUUID(),
                runId: crypto.randomUUID(),
                sessionId: crypto.randomUUID(),
                setRecordingIds: Array.from({ length: activeProtocol.sets }, () => crypto.randomUUID()),
                startedMs: Date.now(),
              };
              // Durable snapshot before opening the runtime: a refresh or app
              // background can resume the same wall clock and stable row ids.
              saveCadenceOnlyRun(next);
              setCadenceRun(next);
              return;
            }
            manualGroupRef.current = crypto.randomUUID();
            manualRunIdRef.current = crypto.randomUUID();
            manualAttemptIdsRef.current = new Map();
            manualAttemptClaimsRef.current = new Set();
            manualStartedRef.current = Date.now();
            setManualOpen(true);
          }}
        >
          {activeProtocol?.protocolMode === "reverse_action" ? "Start cadence only" : "Train without sensor"}
        </button>
        {!activeProtocol && <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", marginTop: 6 }}>Choose a Force protocol below to train without a sensor.</div>}
        {activeProtocol?.protocolMode === "reverse_action" && (
          <div style={{ marginTop: 6 }}>
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)" }}>Cadence only follows the clock; it does not detect movement or record force.</div>
            <button
              type="button"
              className="glass-pill"
              style={{ marginTop: 5, fontSize: "var(--t-xs)" }}
              onClick={() => {
                setSetupGuideSensor(false);
                setSetupGuideOpen(true);
              }}
            >
              How to set up cadence only
            </button>
          </div>
        )}
      </>}

      {/* Connected: the gauge lives fullscreen; this is the resume bar */}
      {isActiveTindeqStatus(status) && (
        <ForceConnectionCard
          status={status}
          locked={runActive}
          onOpenGauge={() => setGaugeMinimized(false)}
          onOpenSetup={() => {
            setSetupGuideSensor(true);
            setSetupGuideOpen(true);
          }}
        />
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
          locked={runActive}
        />
        {runActive && (
          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8 }}>
            Locked while armed or measuring — applies to your next run.
          </div>
        )}
        {!pendingTag.trim() &&
          (status === "connected" || status === "armed" || status === "measuring") && (
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
                {justSaved.peakKg?.toFixed(1)} kg
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
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, margin: "20px 0 10px" }}>
        <div style={{
          fontSize: "var(--t-2xs)",
          color: "var(--ink-faint)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
        }}>
          Protocol presets
        </div>
        <div role="group" aria-label="Protocol mode" style={{ display: "flex", gap: 4 }}>
          {([ ["static", "Static"], ["reverse_action", "Reverse Action"] ] as const).map(([mode, label]) => (
            <button
              key={mode}
              type="button"
              className="tag"
              disabled={runActive}
              aria-pressed={protocolModality === mode}
              onClick={() => selectProtocolModality(mode)}
              style={{
                background: protocolModality === mode
                  ? mode === "static" ? "var(--success)" : "var(--primary)"
                  : "var(--surface-1)",
                color: protocolModality === mode ? "#fff" : "var(--ink-muted)",
                border: `1px solid ${protocolModality === mode
                  ? mode === "static" ? "var(--success)" : "var(--primary)"
                  : "var(--border)"}`,
                fontFamily: "Inter, sans-serif",
              }}
            >{label}</button>
          ))}
        </div>
      </div>
      {zoneTag && capacityModality === "static" && (
        <TargetZonesCard
          tag={zoneTag}
          model={model}
          prKg={prKg}
          selected={armedZone}
          onSelect={selectZone}
          intensityPct={intensityPct}
          onIntensityChange={changeIntensity}
          locked={runActive}
          alternatingReady={
            alternatingModelsSettled &&
            effectiveTag !== null &&
            (armedZone?.protocol.id === "zone:warmup" || armedZone?.protocol.id === "zone:prehab"
              ? resolveAlternatingMaintenance(
                  { ...armedZone.protocol, alternateSides: true },
                  alternatingInputs,
                ) !== null
              : selectedQuality(armedZone) !== null &&
                resolveAlternatingRecommendation(
                  alternatingInputs,
                  selectedQuality(armedZone)!,
                  effectiveTag,
                  intensityPct,
                  armedZone?.protocol.sets ?? 1,
                ) !== null)
          }
          alternatingPrescription={alternatingPrescription}
          onClear={clearProtocol}
          unarmedNotice={zoneState.notice}
        />
      )}
      {effectiveTag && zoneTag && capacityModality === "static" && (
        <ZoneFocusCard
          recordings={recordings.filter((r) => r.tag === effectiveTag)}
          // The card is scoped to the TAG (both sides), not `zoneTag` — which
          // carries the selected side and would overclaim (#214).
          exercise={effectiveTag}
          model={model}
          onPick={(q) =>
            selectZone(
              buildZoneSelectionPreservingSides(
                model,
                q,
                zoneTag,
                armedZone,
                intensityPct,
              ),
            )
          }
          locked={runActive}
        />
      )}
      {zoneTag && capacityModality === "reverse_action" && (
        <div className="card" style={{ color: "var(--ink-muted)", fontSize: "var(--t-xs)" }}>
          Static recommendations are hidden in Reverse Action mode. Its PR, Hill/CF model, and targets use Reverse Action capacity evidence only.
        </div>
      )}
      <PresetManager
        // Remounting on a deliberate mode switch closes any add/edit draft,
        // so form state cannot leak into the other protocol context.
        key={protocolModality}
        // #298 round 6 (finding A2): the LOCKED preset id, not raw `preset` —
        // the highlight must never diverge from what's actually running.
        selectedId={gaugeInputs.preset?.id ?? null}
        onSelect={selectPreset}
        onRestore={(p) => {
          // #298 round 6 (finding A3): a presets fetch resolving mid-run must
          // not change the armed selection out from under an in-progress
          // run — skip the restore entirely while runActive, same as every
          // other write to zoneSel/preset.
          if (runActive) return;
          // #296: mount-time restore must never disarm a zone (or a preset)
          // armed since — restoredSelection reads the CURRENT zoneSel/preset
          // closed over by THIS render, so a zone armed while the presets
          // fetch was in flight still wins (forceSelection.test.ts covers
          // the race).
          const next = restoredSelection({ zoneSel, preset }, p);
          if (next.preset === p) {
            const restoredModality = presetModality(p);
            setProtocolModality(restoredModality);
            saveProtocolModality(restoredModality);
          }
          setZoneState((current) => ({
            selection: next.zoneSel,
            notice: null,
            revision: current.revision + 1,
          }));
          setPreset(next.preset);
        }}
        presetRefs={presetRefs}
        locked={runActive}
        modality={protocolModality}
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
              modality={capacityModality}
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
                modality={capacityModality}
              />
            )}
            {effectiveTag && (
              <SideAsymmetryCard
                recordings={recordings.filter((r) => r.tag === effectiveTag)}
                modality={capacityModality}
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
      {(status === "connected" || status === "armed" || status === "measuring") && !gaugeMinimized && (
        <ForceFullscreen
          tindeq={tindeq}
          protocol={activeProtocol}
          timeline={timeline}
          target={bandTarget}
          presetRefs={presetRefs}
          alternatingPrescription={alternatingPrescription}
          globalSide={gaugeInputs.pendingSide}
          tag={gaugeInputs.pendingTag}
          allTags={allTags}
          onTag={setPendingTag}
          onSide={setPendingSide}
          onOpenSetupGuide={() => {
            setSetupGuideSensor(true);
            setSetupGuideOpen(true);
          }}
          onClearProtocol={clearProtocol}
          canStart={
            !!gaugeInputs.pendingTag &&
            (activeProtocol?.protocolMode !== "reverse_action" || presetKgSet1 !== null) &&
            !zoneCurvePending &&
            !alternatingReferencesPending &&
            (!alternatingTargetNeedsBoth || alternatingPrescription !== null)
          }
          startBlockedReason={
            activeProtocol?.protocolMode === "reverse_action" && presetKgSet1 === null
              ? "This Reverse Action target cannot be resolved yet — add the required force reference or choose a fixed kg target."
            : zoneCurvePending
              ? "Updating this exercise's curve — try Start again in a moment, or tap Clear — free hold to start without a target."
              : alternatingReferencesPending
                ? "Updating both hands' force references — try Start again in a moment."
              : alternatingTargetNeedsBoth && alternatingPrescription === null
                ? alternatingQuality
                  ? "Alternating needs a fit for both hands before Start."
                  : "This maintenance protocol needs force references for both hands before Start."
                : null
          }
          saving={saving}
          handsFree={handsFreeEnabled}
          adaptiveState={adaptiveStaticState}
          onToggleHandsFree={toggleHandsFree}
          targetCoach={targetCoachEnabled}
          onToggleTargetCoach={toggleTargetCoach}
          onArm={() => void armHandsFree()}
          onCancelArm={cancelHandsFreeArm}
          prepare={prepare}
          onTogglePrepare={togglePrepare}
          onStop={stopHandsFreeNow}
          protoTS={protoTS}
          paused={paused}
          onPause={togglePause}
          onSkip={skipSegment}
          onStart={() => {
            // Snapshot provenance before the first async operation. Later rep
            // saves must never read a prescription from another render.
            // eslint-disable-next-line react-hooks/immutability -- intentional run-start ref snapshot consumed by async autosave
            alternatingPrescriptionRef.current = alternatingPrescription;
            setJustSaved(null);
            setProtoShiftS(0);
            setPausedAtS(null);
            // New run id for guided runs; free holds stay unstamped (SL-79).
            protocolRunIdRef.current =
              timeline && activeProtocol ? crypto.randomUUID() : null;
            reverseRunGroupIdRef.current =
              activeProtocol?.protocolMode === "reverse_action"
                ? ensureSession()
                : null;
            void tindeq.start();
            // Lock-screen card for guided runs: hand the whole segment
            // schedule to native up front — the countdown renders from
            // timestamps with no further JS involvement.
            if (
              timeline &&
              activeProtocol &&
              activeProtocol.protocolMode !== "reverse_action"
            ) {
              // #298 round 6 (finding B3): the LOCKED gaugeInputs.pendingTag —
              // cosmetic (lock-screen label) but the same "read the run's own
              // tag, not whatever's currently typed" rule as everywhere else.
              const tag = gaugeInputs.pendingTag;
              void startTindeqLiveActivity(
                tag ? `${activeProtocol.name} · ${tag}` : activeProtocol.name,
                // One static kg cannot describe an alternating per-hand run;
                // omit it until the native API accepts segment targets.
                alternatingArmed ? null : (presetKgSet1 ?? bandTarget?.kg ?? null),
                // Event-time timestamp, intentionally created only after the user taps Start.
                // eslint-disable-next-line react-hooks/purity
                Date.now(),
                timeline as ProtocolSegment[],
              );
            }
          }}
          onMinimize={() => setGaugeMinimized(true)}
          protocolQuality={activeProtocolQuality?.replace("-", " ").toUpperCase() ?? null}
        />
      )}
      {manualOpen && timeline && activeProtocol && activeProtocol.protocolMode !== "reverse_action" && (
        <ManualForceFullscreen
          name={`${activeProtocol.name} · ${gaugeInputs.pendingTag}`}
          timeline={timeline as ProtocolSegment[]}
          targetKg={(set) => presetTargetKg(activeProtocol, presetRefs, set)}
          onAttempt={async ({ seg, actualDurationMs, externalLoadKg, outcome }) => {
            const groupId = manualGroupRef.current;
            const runId = manualRunIdRef.current;
            if (!groupId || !runId) return false;
            const attemptIds = manualAttemptIdsRef.current;
            const attemptClaims = manualAttemptClaimsRef.current;
            const attemptKey = manualAttemptKey(seg.set, seg.rep, seg.side ?? gaugeInputs.pendingSide);
            const id = claimManualAttempt(
              attemptKey,
              attemptIds,
              attemptClaims,
              () => crypto.randomUUID(),
            );
            if (!id) return false;
            const rec: NewTindeqRecording & { id: string } = {
              id,
              source: "manual",
              durationMs: actualDurationMs,
              peakKg: null,
              avgKg: null,
              note: "Sensorless timed external-load attempt",
              tag: gaugeInputs.pendingTag,
              side: seg.side ?? gaugeInputs.pendingSide,
              groupId,
              protocolRunId: runId,
              setNo: seg.set,
              repNo: seg.rep,
              zone: performedQuality(activeProtocol, externalLoadKg, presetRefs, seg.set),
              externalLoadKg,
              outcome,
              plannedDurationMs: seg.durS * 1000,
              actualDurationMs,
              samples: [],
            };
            try {
              const saved = await insertRecording(rec);
              outageRef.current = false;
              setRecordings((list) => [saved, ...list]);
              return true;
            } catch {
              const durable = await queueFailedRecording(rec);
              if (!durable) attemptClaims.delete(attemptKey);
              return durable;
            }
          }}
          onFinish={async (rpe, completedMs) => {
            const groupId = manualGroupRef.current;
            if (!groupId) return false;
            const sessionClaims = manualSessionClaimsRef.current;
            const startedMs = manualStartedRef.current;
            const sessionTag = gaugeInputs.pendingTag;
            if (!claimManualSession(groupId, sessionClaims)) return false;
            const durationMin = Math.max(1, Math.round((completedMs - startedMs) / 60000));
            const ok = await onLogSession({
              durationMin,
              rpe,
              rpeConfirmed: true,
              typeLabel: "Force",
              groupId,
              note: `Sensorless Force · ${sessionTag}`,
            });
            if (ok) {
              if (manualGroupRef.current === groupId) {
                manualGroupRef.current = null;
                manualRunIdRef.current = null;
                setManualOpen(false);
                toast("Manual Force session logged to history");
              }
            } else {
              sessionClaims.delete(groupId);
            }
            return ok;
          }}
          onCancel={() => setManualOpen(false)}
        />
      )}
      {cadenceRun && (
        <CadenceOnlyReverseActionFullscreen
          run={cadenceRun}
          onRecording={async (rec) => {
            try {
              const saved = await insertRecording(rec);
              outageRef.current = false;
              setRecordings((list) => appendUniqueById(list, saved));
              return true;
            } catch {
              return await queueFailedRecording(rec);
            }
          }}
          onFinish={async (rpe, outcome, elapsedMs) => {
            // Stable sessionId was persisted before the runtime opened. A
            // lost response/reload retries the same primary key, not a second
            // session; insertTindeqSession treats that collision as success.
            const complete = cadenceOnlyRunComplete(cadenceRun, elapsedMs);
            return await onLogSession({
              id: cadenceRun.sessionId,
              durationMin: Math.max(1, Math.round(elapsedMs / 60_000)),
              rpe,
              rpeConfirmed: true,
              typeLabel: "Force",
              groupId: cadenceRun.groupId,
              note: `Reverse Action · cadence only · ${cadenceRun.tag} · ${complete ? "complete" : "partial"} · ${outcome.replace("_", " ")}${cadenceRun.preset.setupNote ? ` · equipment: ${cadenceRun.preset.setupNote}` : ""}`,
            });
          }}
          onClose={() => setCadenceRun(null)}
        />
      )}
      {setupGuideOpen && !runActive && (
        <ForceSetupGuide
          mode={setupMode}
          sensor={setupGuideSensor}
          onClose={() => setSetupGuideOpen(false)}
        />
      )}
    </div>
  );
}
