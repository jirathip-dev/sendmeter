import { useEffect, useRef, useState } from "react";
import {
  cadenceOnlyPlannedEndMs,
  cadenceOnlyPosition,
  claimCadenceOnlyRows,
  clearCadenceOnlyRun,
  saveCadenceOnlyRun,
  type CadenceOnlyRunState,
} from "../lib/cadenceOnlyRun";
import type { NewTindeqRecording } from "../types";
import ProtocolBadge from "./ProtocolBadge";
import { SheetLayerProvider } from "./Sheet";

export default function CadenceOnlyReverseActionFullscreen({
  run,
  onRecording,
  onFinish,
  onClose,
}: {
  run: CadenceOnlyRunState;
  onRecording: (row: NewTindeqRecording & { id: string }) => Promise<boolean>;
  onFinish: (rpe: number, outcome: "too_easy" | "good" | "failed", elapsedMs: number) => Promise<boolean>;
  onClose: () => void;
}) {
  const plannedEndMs = cadenceOnlyPlannedEndMs(run);
  const [initialClock] = useState(() => {
    const wallNow = Date.now();
    const endMs = run.endedMs ?? (wallNow >= plannedEndMs ? plannedEndMs : null);
    return { nowMs: endMs ?? wallNow, endMs };
  });
  const initialEndMs = initialClock.endMs;
  const [now, setNow] = useState(initialClock.nowMs);
  const [endedAtMs, setEndedAtMs] = useState<number | null>(initialEndMs);
  const [stopped, setStopped] = useState(
    () => initialEndMs !== null && initialEndMs < plannedEndMs,
  );
  const [rpe, setRpe] = useState(5);
  const [outcome, setOutcome] = useState<"too_easy" | "good" | "failed">("good");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const claimsRef = useRef(new Set<number>());
  const persistenceRef = useRef(new Set<Promise<boolean>>());
  const finishingRef = useRef(false);
  const stopClaimRef = useRef(false);
  const endedAtRef = useRef<number | null>(initialEndMs);
  const lastCueRef = useRef("");
  const position = cadenceOnlyPosition(run, now);
  const finished = endedAtMs !== null;

  function persistDue(at: number, partial: boolean): Promise<boolean> {
    const rows = claimCadenceOnlyRows(run, at, partial, claimsRef.current);
    const task = (async () => {
      let allSaved = true;
      for (const row of rows) {
        const ok = await onRecording(row);
        if (!ok) {
          claimsRef.current.delete(row.setNo!);
          allSaved = false;
        }
      }
      return allSaved;
    })();
    persistenceRef.current.add(task);
    void task.finally(() => persistenceRef.current.delete(task)).catch(() => {});
    return task;
  }

  async function flushDue(at: number, partial: boolean): Promise<boolean> {
    const pending = [...persistenceRef.current];
    if (pending.length > 0) await Promise.allSettled(pending);
    // A failed in-flight write released its synchronous claim. Re-claim and
    // retry it before the stable session id is committed and the run cleared.
    return await persistDue(at, partial);
  }

  useEffect(() => {
    if (initialEndMs !== null) {
      if (run.endedMs !== initialEndMs) {
        saveCadenceOnlyRun({ ...run, endedMs: initialEndMs });
      }
      void persistDue(initialEndMs, initialEndMs < plannedEndMs);
      return;
    }
    void persistDue(Math.min(Date.now(), plannedEndMs), false);
    const timer = setInterval(() => {
      if (endedAtRef.current !== null) return;
      const at = Date.now();
      setNow(at);
      const persistenceTime = Math.min(at, plannedEndMs);
      void persistDue(persistenceTime, false);
      if (at >= plannedEndMs && endedAtRef.current === null) {
        endedAtRef.current = plannedEndMs;
        saveCadenceOnlyRun({ ...run, endedMs: plannedEndMs });
        setEndedAtMs(plannedEndMs);
      }
    }, 200);
    return () => clearInterval(timer);
    // `run` is the immutable persisted snapshot for this fullscreen lifetime.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [run.runId]);

  useEffect(() => {
    const segment = position.segment;
    if (!segment) return;
    const cue = `${segment.phase}:${segment.set}:${segment.rep}:${segment.direction}`;
    if (cue === lastCueRef.current) return;
    lastCueRef.current = cue;
    navigator.vibrate?.(segment.phase === "move" ? 120 : [70, 50, 70]);
    try {
      const context = new AudioContext();
      const oscillator = context.createOscillator();
      const gain = context.createGain();
      oscillator.connect(gain); gain.connect(context.destination);
      oscillator.frequency.value = segment.direction === "out" ? 880 : segment.direction === "return" ? 620 : 420;
      gain.gain.value = 0.15; oscillator.start(); oscillator.stop(context.currentTime + 0.12);
      oscillator.onended = () => void context.close();
    } catch { /* visible clock remains authoritative */ }
  }, [position.segment]);

  const segment = position.segment;
  const instruction = position.finished
    ? "COMPLETE"
    : segment?.phase === "move"
      ? segment.direction === "out" ? "CONCENTRIC" : "ECCENTRIC"
      : segment?.phase === "setRest" ? "SET REST" : "PREPARE";

  async function stop() {
    if (stopClaimRef.current) return;
    stopClaimRef.current = true;
    const stoppedAt = Math.min(Date.now(), plannedEndMs);
    // Durable end claim before the first await: a refresh from the outcome
    // screen must retry this same partial/completed run, never resume it.
    saveCadenceOnlyRun({ ...run, endedMs: stoppedAt });
    endedAtRef.current = stoppedAt;
    setNow(stoppedAt);
    setEndedAtMs(stoppedAt);
    setStopped(stoppedAt < plannedEndMs);
    await persistDue(stoppedAt, true);
  }

  return <SheetLayerProvider layer="fullscreen"><div style={{ position: "fixed", inset: 0, zIndex: 1200, background: "var(--canvas)", padding: "max(14px, env(safe-area-inset-top)) 16px max(14px, env(safe-area-inset-bottom))", display: "flex", flexDirection: "column", gap: 12, textAlign: "center" }}>
    <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
      <div style={{ minWidth: 0, flex: 1, textAlign: "left" }}>
        <div style={{ fontWeight: 850, fontSize: "var(--t-lg)", overflowWrap: "anywhere" }}>{run.preset.name}</div>
        <ProtocolBadge mode="reverse_action" quality="CADENCE ONLY" />
      </div>
      {!finished && <button className="header-btn" onClick={() => void stop()}>Stop</button>}
    </div>
    {!finished ? <>
      <div style={{ color: "var(--ink-muted)", fontSize: "var(--t-sm)" }}>
        Clock-guided cadence · movement is not detected
      </div>
      <div style={{ flex: 1, minHeight: 0, display: "grid", placeContent: "center", gap: 10 }}>
        <div aria-live="assertive" style={{ fontSize: "clamp(2.7rem, 15vw, 5rem)", lineHeight: .95, fontWeight: 900, letterSpacing: ".08em", color: segment?.phase === "move" ? "var(--success)" : "var(--warning)" }}>{instruction}</div>
        <div style={{ fontSize: "clamp(4rem, 24vw, 8rem)", fontWeight: 900, lineHeight: .9, fontVariantNumeric: "tabular-nums" }}>{position.remainingS.toFixed(1)}<span style={{ fontSize: "1.3rem", color: "var(--ink-muted)" }}>s</span></div>
        <div style={{ fontWeight: 800, color: "var(--ink-muted)" }}>
          SET {segment?.set ?? 1}/{run.preset.sets}
          {segment?.phase === "move" ? ` · REP ${segment.rep}/${run.preset.reps}` : ""}
          {run.side ? ` · ${run.side.toUpperCase()}` : ""}
        </div>
      </div>
      <div style={{ color: "var(--ink-faint)", fontSize: "var(--t-xs)" }}>
        Equipment resistance · {run.preset.setupNote || "no setup note"}
      </div>
      <button className="btn-danger" onClick={() => void stop()}>Emergency stop</button>
    </> : <div className="card" style={{ margin: "auto 0" }}>
      <div style={{ fontWeight: 850, fontSize: "var(--t-xl)" }}>{stopped ? "Partial protocol saved" : "Protocol complete"}</div>
      <div className="section-sub">Clock-guided dose only; no force capacity evidence was recorded.</div>
      <input aria-label="RPE" type="range" min="1" max="10" value={rpe} onChange={(event) => setRpe(Number(event.target.value))} style={{ width: "100%", marginTop: 20 }} />
      <div style={{ fontSize: 36, fontWeight: 850, marginBottom: 16 }}>RPE {rpe}</div>
      <div style={{ display: "flex", gap: 7, marginBottom: 14 }}>
        {(["too_easy", "good", "failed"] as const).map((value) => <button key={value} className={outcome === value ? "btn-primary" : "header-btn"} style={{ flex: 1 }} onClick={() => setOutcome(value)}>{value === "too_easy" ? "Too easy" : value === "good" ? "Good" : "Failed"}</button>)}
      </div>
      {saveError && <div style={{ color: "var(--danger)", fontSize: "var(--t-sm)", marginBottom: 10 }}>{saveError}</div>}
      <button className="btn-primary" disabled={saving} onClick={() => {
        if (finishingRef.current) return;
        finishingRef.current = true;
        setSaving(true);
        setSaveError(null);
        const endedAt = endedAtRef.current ?? Date.now();
        void flushDue(endedAt, endedAt < plannedEndMs).then(async (rowsSaved) => {
          if (!rowsSaved) return false;
          return await onFinish(rpe, outcome, Math.max(1, endedAt - run.startedMs));
        }).then((ok) => {
          setSaving(false);
          if (ok) {
            clearCadenceOnlyRun();
            onClose();
          } else {
            finishingRef.current = false;
            setSaveError("Could not safely save this run yet. Check your connection and try again.");
          }
        });
      }}>{saving ? "Saving…" : "Save session"}</button>
    </div>}
  </div></SheetLayerProvider>;
}
