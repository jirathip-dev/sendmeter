import { useEffect, useRef, useState } from "react";
import type { ProtocolSegment } from "../lib/protocol";
import {
  confirmManualHold,
  canFailManualHold,
  currentManualSegment,
  failManualHold,
  startManualRun,
  tickManualRun,
  type ManualOutcome,
  type ManualRunState,
} from "../lib/manualForceRuntime";

interface Attempt {
  seg: ProtocolSegment;
  actualDurationMs: number;
  externalLoadKg: number;
  outcome: ManualOutcome;
}

export default function ManualForceFullscreen({
  name,
  timeline,
  targetKg,
  onAttempt,
  onFinish,
  onCancel,
}: {
  name: string;
  timeline: ProtocolSegment[];
  targetKg: (set: number) => number | null;
  onAttempt: (attempt: Attempt) => Promise<boolean>;
  onFinish: (rpe: number, completedMs: number) => Promise<boolean>;
  onCancel: () => void;
}) {
  const [now, setNow] = useState(() => Date.now());
  const [state, setState] = useState<ManualRunState>(() => startManualRun(Date.now()));
  const stateRef = useRef(state);
  const [load, setLoad] = useState("");
  const [outcome, setOutcome] = useState<ManualOutcome>("good");
  const [saving, setSaving] = useState(false);
  const [rpe, setRpe] = useState(5);
  const audioRef = useRef<AudioContext | null>(null);
  const lastIndexRef = useRef(-1);
  const attemptSubmittingRef = useRef(false);
  const finishSubmittingRef = useRef(false);
  useEffect(() => { stateRef.current = state; }, [state]);

  useEffect(() => {
    const timer = setInterval(() => {
      const at = Date.now();
      setNow(at);
      setState((current) => {
        const next = tickManualRun(current, timeline, at);
        if (current.status === "running" && !current.pending && next.status === "running" && next.pending) {
          const hold = timeline[next.pending.index];
          const suggested = hold ? targetKg(hold.set) : null;
          setLoad(suggested == null ? "" : String(Math.round(suggested * 10) / 10));
          setOutcome("good");
        }
        stateRef.current = next;
        return next;
      });
    }, 100);
    return () => clearInterval(timer);
  }, [timeline, targetKg]);

  const seg = currentManualSegment(state, timeline);
  // Transition cue. Audio is primed by the opening user action where the
  // browser permits it; vibration remains available elsewhere.
  useEffect(() => {
    if (state.status !== "running" || lastIndexRef.current === state.index) return;
    lastIndexRef.current = state.index;
    try {
      if (!audioRef.current) audioRef.current = new AudioContext();
      const ctx = audioRef.current;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.connect(gain); gain.connect(ctx.destination);
      osc.frequency.value = seg?.phase === "hold" ? 990 : 440;
      gain.gain.value = 0.2; osc.start(); osc.stop(ctx.currentTime + 0.15);
    } catch { /* no audio */ }
    navigator.vibrate?.(seg?.phase === "hold" ? 150 : [80, 60, 80]);
  }, [state, seg]);

  const remaining = state.status === "running" && seg
    ? Math.max(0, seg.durS - (now - state.startedMs) / 1000)
    : 0;

  async function confirm() {
    const current = stateRef.current;
    if (current.status !== "running" || !current.pending || attemptSubmittingRef.current) return;
    attemptSubmittingRef.current = true;
    const hold = timeline[current.pending.index];
    if (!hold) { attemptSubmittingRef.current = false; return; }
    const kg = Number(load);
    if (!Number.isFinite(kg) || kg < 0) { attemptSubmittingRef.current = false; return; }
    setSaving(true);
    const ok = await onAttempt({ seg: hold, actualDurationMs: current.pending.actualDurationMs, externalLoadKg: kg, outcome });
    setSaving(false);
    if (ok) {
      const next = confirmManualHold(current, timeline, Date.now());
      stateRef.current = next;
      setState(next);
    }
    attemptSubmittingRef.current = false;
  }

  return (
    <div style={{ position: "fixed", inset: 0, zIndex: 1000, background: "var(--canvas)", padding: 20, overflowY: "auto" }}>
      <div style={{ maxWidth: 620, margin: "0 auto" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <button className="header-btn" disabled={saving} onClick={onCancel}>Cancel</button>
          <div style={{ flex: 1, fontWeight: 800, textAlign: "center" }}>{name}</div>
        </div>
        {state.status === "running" && seg && (
          <div className="card" style={{ textAlign: "center", marginTop: 18 }}>
            <div className="label-eyebrow">Set {seg.set} · Rep {seg.rep}{seg.side ? ` · ${seg.side}` : ""}</div>
            <div style={{ fontSize: 30, fontWeight: 800, margin: "18px 0 4px", textTransform: "uppercase" }}>{seg.phase}</div>
            <div style={{ fontSize: 64, fontWeight: 800 }}>{Math.ceil(remaining)}</div>
            {seg.phase === "hold" && state.pending && (
              <div style={{ color: "var(--warning)", fontWeight: 700 }}>Waiting for the prior attempt confirmation</div>
            )}
            {canFailManualHold(state, timeline) && <button className="btn-primary" onClick={() => {
              const failed = failManualHold(stateRef.current, timeline, Date.now());
              const suggested = targetKg(seg.set);
              setLoad(suggested == null ? "" : String(Math.round(suggested * 10) / 10));
              setOutcome("failed");
              stateRef.current = failed;
              setState(failed);
            }}>Failed early</button>}
          </div>
        )}
        {state.status === "running" && state.pending && (() => {
          const hold = timeline[state.pending.index]!;
          return (
          <div className="card" style={{ marginTop: 18 }}>
            <div style={{ fontWeight: 800, fontSize: 20 }}>Confirm attempt</div>
            <div className="section-sub">Set {hold.set} · Rep {hold.rep}{hold.side ? ` · ${hold.side}` : ""} · {(state.pending.actualDurationMs / 1000).toFixed(1)}s actual</div>
            <label className="label-eyebrow" style={{ display: "block", marginTop: 16 }}>External load (kg)</label>
            <input className="input" inputMode="decimal" type="number" min="0" step="0.5" value={load} onChange={(e) => setLoad(e.target.value)} autoFocus />
            <div style={{ display: "flex", gap: 8, margin: "14px 0" }}>
              {(["too_easy", "good", "failed"] as ManualOutcome[]).map((value) => <button key={value} className={outcome === value ? "btn-primary" : "header-btn"} style={{ flex: 1 }} onClick={() => setOutcome(value)}>{value === "too_easy" ? "Too easy" : value === "good" ? "Good" : "Failed"}</button>)}
            </div>
            <button className="btn-primary" disabled={saving || load === ""} onClick={() => void confirm()}>{saving ? "Saving…" : "Confirm & continue"}</button>
          </div>
          );
        })()}
        {state.status === "finished" && (
          <div className="card" style={{ marginTop: 18, textAlign: "center" }}>
            <div style={{ fontWeight: 800, fontSize: 24 }}>Session complete</div>
            <div className="section-sub">How hard was the whole session?</div>
            <input type="range" min="1" max="10" value={rpe} onChange={(e) => setRpe(Number(e.target.value))} style={{ width: "100%" }} />
            <div style={{ fontSize: 40, fontWeight: 800, marginBottom: 12 }}>RPE {rpe}</div>
            <button className="btn-primary" disabled={saving} onClick={() => {
              if (finishSubmittingRef.current) return;
              finishSubmittingRef.current = true;
              setSaving(true);
              void onFinish(rpe, state.completedMs).then((ok) => {
                setSaving(false);
                if (!ok) finishSubmittingRef.current = false;
              });
            }}>{saving ? "Saving…" : "Finish session"}</button>
          </div>
        )}
        <div className="card" style={{ marginTop: 12 }}>
          <div className="label-eyebrow">Plan</div>
          {timeline.filter((s) => s.phase === "hold").map((s, i) => <div key={`${s.set}-${s.rep}-${s.side}-${i}`} style={{ padding: "5px 0", color: state.status !== "finished" && timeline.indexOf(s) === state.index ? "var(--primary)" : "var(--ink-muted)" }}>Set {s.set} · Rep {s.rep}{s.side ? ` · ${s.side}` : ""} · {s.durS}s{targetKg(s.set) != null ? ` · ${targetKg(s.set)!.toFixed(1)} kg` : ""}</div>)}
        </div>
      </div>
    </div>
  );
}
