import { useEffect, useRef, useState } from "react";
import { useTindeqSession } from "../hooks/useTindeqSession";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import {
  deleteRecording,
  fetchRecordings,
  fetchRecordingSamples,
  insertRecording,
} from "../lib/repo";
import { computeForceCurve } from "../lib/force-curve";
import type { ForceCurveModel } from "../lib/force-curve";
import { buildTimeline, presetTargetKg, timelineAt } from "../lib/protocol";
import type { ProtocolSegment } from "../lib/protocol";
import {
  endTindeqLiveActivity,
  startTindeqLiveActivity,
  updateTindeqLivePeak,
} from "../lib/liveActivity";
import type { TindeqPreset, TindeqRecordingMeta, TindeqSide } from "../types";
import ForceCurveCard from "./ForceCurveCard";
import type { GaugeTarget } from "./ForceCurveCard";
import PresetManager from "./PresetManager";
import SideAsymmetryCard from "./SideAsymmetryCard";
import TagSideEditor from "./TagSideEditor";
import TargetZonesCard from "./TargetZonesCard";
import type { ZoneSelection } from "./TargetZonesCard";
import ForceFullscreen from "./ForceFullscreen";
import ForceTrendChart from "./ForceTrendChart";

interface ForceViewProps {
  onLogSession: (input: {
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
  }) => Promise<void>;
}

export default function ForceView({ onLogSession }: ForceViewProps) {
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
  // The just-auto-saved recording, shown as a confirmation so the user can
  // eyeball its tag (and undo if it was wrong). Replaces the old discard/save
  // prompt — a rep now saves the moment you stop, using the tag set beforehand.
  const [justSaved, setJustSaved] = useState<TindeqRecordingMeta | null>(null);
  const [pendingTag, setPendingTag] = useState("");
  const [pendingSide, setPendingSide] = useState<TindeqSide>("");
  const [endingSession, setEndingSession] = useState<{
    id: string;
    durationMin: number;
    rpe: number;
  } | null>(null);
  const [loggingSession, setLoggingSession] = useState(false);
  const [saving, setSaving] = useState(false);
  const [recordings, setRecordings] = useState<TindeqRecordingMeta[]>([]);
  const [listError, setListError] = useState<string | null>(null);
  const [zoneSel, setZoneSel] = useState<ZoneSelection | null>(null);
  const [preset, setPreset] = useState<TindeqPreset | null>(null);
  // Force-curve model for the selected tag/side — auto-computed (no button)
  // and shared by the curve card + the target-zones picker.
  const [curveModel, setCurveModel] = useState<ForceCurveModel | null>(null);
  const [curveComputedFor, setCurveComputedFor] = useState<string | null>(null);
  const [curveError, setCurveError] = useState<string | null>(null);
  const realtimeVersion = useRealtimeVersion();

  // Every tag ever used, most frequent first; top 6 become one-tap chips,
  // the full list feeds the input's autocomplete datalist.
  const allTags = (() => {
    const counts = new Map<string, number>();
    for (const r of recordings) {
      if (r.tag) counts.set(r.tag, (counts.get(r.tag) ?? 0) + 1);
    }
    return [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([t]) => t);
  })();
  const recentTags = allTags.slice(0, 6);

  const sessionCount = gaugeSession
    ? recordings.filter((r) => r.groupId === gaugeSession.groupId).length
    : 0;

  function endSession() {
    if (!gaugeSession) return;
    const durationMin = Math.max(
      1,
      Math.round((Date.now() - gaugeSession.startedAt) / 60000),
    );
    // A session only exists because a recording created it (lazy mint), so
    // there's always ≥1 recording to log — always open the RPE prompt. The
    // sheet re-fetches the group's recordings itself, so it doesn't depend on
    // ForceView's (possibly not-yet-loaded) `recordings` state.
    setEndingSession({ id: gaugeSession.groupId, durationMin, rpe: 5 });
    clearSession();
  }

  async function logEndedSession() {
    if (!endingSession) return;
    setLoggingSession(true);
    const recs = recordings.filter((r) => r.groupId === endingSession.id);
    const tags = [...new Set(recs.map((r) => r.tag).filter(Boolean))];
    const note = [
      `${recs.length} recording${recs.length === 1 ? "" : "s"}`,
      ...(tags.length ? [tags.join(", ")] : []),
    ].join(" · ");
    await onLogSession({
      durationMin: endingSession.durationMin,
      rpe: endingSession.rpe,
      note,
      groupId: endingSession.id,
    });
    setLoggingSession(false);
    setEndingSession(null);
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
  async function saveHoldSlice(
    seg: ProtocolSegment,
    segIdx: number,
    endMsOverride?: number,
  ) {
    if (savedSegsRef.current.has(segIdx)) return;
    savedSegsRef.current.add(segIdx);
    const startMs = seg.startS * 1000;
    const endMs = endMsOverride ?? (seg.startS + seg.durS) * 1000;
    const slice = tindeq.samplesRef.current
      .filter((s) => s.t >= startMs && s.t <= endMs)
      .map((s) => ({ t: Math.round((s.t - startMs) * 10) / 10, kg: s.kg }));
    if (slice.length < 2) {
      savedSegsRef.current.delete(segIdx); // nothing saved — allow a retry
      return;
    }
    const kgs = slice.map((s) => s.kg);
    try {
      const saved = await insertRecording({
        durationMs: Math.max(1, Math.round(slice[slice.length - 1]!.t)),
        peakKg: Math.max(...kgs),
        avgKg: Math.round((kgs.reduce((a, b) => a + b, 0) / kgs.length) * 100) / 100,
        note: "",
        tag: pendingTag.trim(),
        side: seg.side ?? pendingSide,
        groupId: ensureSession(),
        samples: slice,
      });
      setRecordings((list) => [saved, ...list]);
      setJustSaved(saved);
    } catch (e) {
      savedSegsRef.current.delete(segIdx); // insert failed — allow a retry
      setListError(e instanceof Error ? e.message : "Failed to save recording");
    }
  }

  // Stop always saves — the tag was required before Start, so there's nothing
  // to decide here. Guided protocols save PER REP (each hold is already its
  // own recording); a free hold saves the whole pull as one recording.
  // Re-entrancy guard: a manual Stop and the BLE-disconnect auto-save (or a
  // double tap) could both call this — the first claim wins so a free hold is
  // never inserted twice.
  const stopInFlightRef = useRef(false);
  async function handleStop() {
    if (stopInFlightRef.current) return;
    stopInFlightRef.current = true;
    try {
      await runStop();
    } finally {
      stopInFlightRef.current = false;
    }
  }

  async function runStop() {
    if (timeline) {
      const tMs = tindeq.elapsedMs;
      setSaving(true);
      try {
        // Flush any completed-but-unflushed holds, then a ≥1s partial hold.
        const tS = tMs / 1000;
        let idx = timeline.findIndex((s) => tS < s.startS + s.durS);
        if (idx === -1) idx = timeline.length;
        for (let i = savedThroughRef.current; i < idx; i++) {
          const seg = timeline[i]!;
          if (seg.phase === "hold") await saveHoldSlice(seg, i);
        }
        savedThroughRef.current = idx;
        const pos = timelineAt(timeline, tS);
        // idx is the current (in-progress) segment — same key the autosave
        // effect would use, so the guard dedupes the two paths.
        if (pos && pos.seg.phase === "hold" && tMs - pos.seg.startS * 1000 >= 1000) {
          await saveHoldSlice(pos.seg, idx, tMs);
        }
      } finally {
        setSaving(false);
      }
      await tindeq.stop();
      void endTindeqLiveActivity();
      return;
    }
    const summary = await tindeq.stop();
    void endTindeqLiveActivity();
    if (!summary) return;
    setSaving(true);
    try {
      const saved = await insertRecording({
        durationMs: summary.durationMs,
        peakKg: summary.peakKg,
        avgKg: summary.avgKg,
        note: "",
        tag: pendingTag.trim(),
        side: pendingSide,
        groupId: ensureSession(),
        samples: summary.samples,
      });
      setRecordings((list) => [saved, ...list]);
      setJustSaved(saved);
      // keep tag and side — set once, tweak side between reps
    } catch (e) {
      setListError(e instanceof Error ? e.message : "Failed to save recording");
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
  const curveKey = `${effectiveTag ?? ""}|${chartSide ?? "all"}|${curveRecordings.length}`;
  const canComputeCurve = effectiveTag !== null && curveRecordings.length > 0;
  useEffect(() => {
    if (!canComputeCurve) return;
    let cancelled = false;
    const recs = curveRecordings.slice(0, 15);
    Promise.all(recs.map((r) => fetchRecordingSamples(r.id)))
      .then((all) => {
        if (cancelled) return;
        const m = computeForceCurve(all);
        setCurveModel(m);
        setCurveError(m ? null : "No usable samples in these recordings.");
        setCurveComputedFor(curveKey);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setCurveError(e instanceof Error ? e.message : "Failed to compute curve");
        setCurveModel(null);
        setCurveComputedFor(curveKey);
      });
    return () => {
      cancelled = true;
    };
    // curveKey encodes tag/side/count — the actual deps of this computation.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [curveKey, canComputeCurve]);
  const curveReady = curveComputedFor === curveKey;
  const model = canComputeCurve && curveReady ? curveModel : null;
  const curveComputing = canComputeCurve && !curveReady;

  // PR for the active exercise (+side) — the same best-peak the trend chart
  // marks as PR. Anchors presets whose target is a % of PR.
  const prKg = curveRecordings.length
    ? Math.max(...curveRecordings.map((r) => r.peakKg))
    : null;

  // One guided-timer path: a custom preset wins; else an armed zone runs its
  // prescription. The chart band comes from the preset's target (absolute kg
  // or %-of-PR, set 1 here — the fullscreen ramps it per set), else the zone.
  const activeProtocol: TindeqPreset | null = preset ?? zoneSel?.protocol ?? null;
  const presetKgSet1 = preset ? presetTargetKg(preset, prKg, 1) : null;
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
  useEffect(() => {
    if (measuring && !wasMeasuringRef.current) {
      savedThroughRef.current = 0;
      savedSegsRef.current = new Set();
    }
    wasMeasuringRef.current = measuring;
    if (!measuring || !timeline) return;
    const tS = tindeq.elapsedMs / 1000;
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
  }, [measuring, timeline, tindeq.elapsedMs]);

  // Connection dropped mid-measurement (device died, walked out of range,
  // phone locked): the samples survive in samplesRef, so run the exact same
  // stop/save path a manual Stop would — the interrupted recording is saved
  // instead of lost. Deferred to a task so no state writes happen
  // synchronously inside the effect.
  const handledInterruptionsRef = useRef(tindeq.interruptions);
  useEffect(() => {
    if (tindeq.interruptions === handledInterruptionsRef.current) return;
    handledInterruptionsRef.current = tindeq.interruptions;
    const t = setTimeout(() => void handleStop(), 0);
    return () => clearTimeout(t);
    // handleStop reads current state/refs at call time; depending on it
    // would re-arm this effect every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tindeq.interruptions]);

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

  // Pop the gauge fullscreen the moment the Progressor connects (only on the
  // connecting→connected transition — a stop→connected change must not
  // override a user's minimize). And when it DISCONNECTS with an active
  // session, prompt to finish it (SL-58 #5) — the connection now persists
  // across tabs, so a disconnect is a deliberate end (or the device dying).
  const { status } = tindeq;
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
      const t = setTimeout(() => endSession(), 150);
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
          <span style={{ fontSize: 10, color: "var(--warning)" }}>(fake mode)</span>
        )}
      </div>
      <div className="section-sub">
        Grip-force analysis &amp; training — Tindeq Progressor via Bluetooth.
      </div>

      {/* Gauge session bar — appears once the first recording auto-creates a
          session (SL-58 #5, no manual Start). Finish logs it (RPE prompt). */}
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
          <span style={{ fontSize: 12, color: "var(--ink)", flex: 1 }}>
            Gauge session{" "}
            <span style={{ color: "var(--ink-muted)" }}>
              · {sessionCount} recording{sessionCount === 1 ? "" : "s"}
            </span>
          </span>
          <button
            onClick={endSession}
            style={{
              background: "none",
              border: "1px solid var(--ink-faint)",
              color: "var(--ink-muted)",
              padding: "6px 10px",
              borderRadius: 6,
              fontSize: 10,
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
              fontSize: 16,
              fontWeight: 800,
              marginBottom: 8,
            }}
          >
            Bluetooth not available
          </div>
          <div style={{ fontSize: 12, color: "var(--ink-muted)", lineHeight: 1.5 }}>
            {tindeq.secure
              ? "This browser doesn't support Web Bluetooth. Use Chrome or Edge on desktop or Android — iOS Safari can't connect to Bluetooth devices."
              : "Web Bluetooth requires a secure (HTTPS) connection."}
          </div>
        </div>
      )}

      {/* Log the just-ended gauge session into History / ACWR */}
      {endingSession && (
        <div className="card" style={{ marginBottom: 10 }}>
          <div className="label-eyebrow" style={{ marginBottom: 10 }}>
            Log session to history
          </div>
          {/* Duration is the actual session wall-clock time — only RPE is asked */}
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
              padding: "10px 2px",
            }}
          >
            <span className="field-label" style={{ margin: 0 }}>
              Duration
            </span>
            <span style={{ fontSize: 15, fontWeight: 700 }}>
              {endingSession.durationMin} min{" "}
              <span style={{ fontSize: 10, color: "var(--ink-faint)", fontWeight: 400 }}>
                actual time
              </span>
            </span>
          </div>
          <span className="field-label">RPE (1–10)</span>
          <div className="stepper">
            <button
              className="stepper-btn"
              onClick={() =>
                setEndingSession((s) =>
                  s ? { ...s, rpe: Math.max(1, s.rpe - 1) } : s,
                )
              }
            >
              −
            </button>
            <span className="stepper-val">{endingSession.rpe}</span>
            <button
              className="stepper-btn"
              onClick={() =>
                setEndingSession((s) =>
                  s ? { ...s, rpe: Math.min(10, s.rpe + 1) } : s,
                )
              }
            >
              +
            </button>
          </div>
          <div className="grid-2" style={{ marginTop: 12 }}>
            <button
              className="btn-ghost"
              disabled={loggingSession}
              onClick={() => setEndingSession(null)}
            >
              Skip
            </button>
            <button
              className="btn-primary"
              disabled={loggingSession}
              onClick={() => void logEndedSession()}
            >
              {loggingSession ? "Logging…" : "Log Session"}
            </button>
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
        <div style={{ fontSize: 11, color: "var(--danger)", marginTop: 10 }}>
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
          <span style={{ fontSize: 13, color: "var(--ink)", flex: 1 }}>
            Progressor{" "}
            <span style={{ color: "var(--ink-muted)" }}>
              · {status === "measuring" ? "measuring" : "connected"}
            </span>
          </span>
          <span style={{ color: "var(--primary)", fontWeight: 700, fontSize: 13 }}>
            Open gauge ›
          </span>
        </button>
      )}

      {/* GLOBAL exercise + side: labels the next recording AND drives the
          target zones, trend and curve below. Always visible — this is also
          the only place a brand-new tag can be typed. */}
      <div className="card" style={{ marginTop: 10 }}>
        <div className="label-eyebrow" style={{ marginBottom: 8 }}>
          Exercise &amp; Side
        </div>
        <TagSideEditor
          tag={pendingTag}
          side={pendingSide}
          recentTags={recentTags}
          allTags={allTags}
          onTag={setPendingTag}
          onSide={setPendingSide}
        />
        {!pendingTag.trim() &&
          (status === "connected" || status === "measuring") && (
            <div style={{ fontSize: 11, color: "var(--ink-faint)", marginTop: 8 }}>
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
              <span style={{ fontSize: 12, color: "var(--success)", fontWeight: 700, flex: 1 }}>
                Saved · {justSaved.tag || "untagged"}
                {justSaved.side ? ` · ${justSaved.side}` : ""}
              </span>
              <span style={{ fontSize: 12, color: "var(--ink)", fontFamily: "Inter, sans-serif", fontWeight: 800 }}>
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
                  fontSize: 10,
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
        <div style={{ fontSize: 11, color: "var(--danger)", marginTop: 10 }}>
          {listError}
        </div>
      )}

      {/* Protocols: the zone target is the recommended/default protocol
          (from your force curve); custom presets follow. */}
      <div
        style={{
          fontSize: 10,
          color: "var(--ink-faint)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          margin: "20px 0 10px",
        }}
      >
        Protocol presets
      </div>
      {effectiveTag && (
        <TargetZonesCard
          tag={chartSide ? `${effectiveTag} · ${chartSide}` : effectiveTag}
          model={model}
          selected={zoneSel}
          onSelect={setZoneSel}
        />
      )}
      <PresetManager selectedId={preset?.id ?? null} onSelect={setPreset} />

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
          <div style={{ fontSize: 11, color: "var(--ink-faint)" }}>
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
          prKg={prKg}
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
          onStart={() => {
            setJustSaved(null);
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
