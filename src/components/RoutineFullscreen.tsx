import { useEffect, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";
import type { RoutineStep } from "../types";

interface Props {
  /// Name of the routine — shown in the top-bar eyebrow.
  name: string;
  /// The routine to run — from the selected preset (RoutineCard).
  steps: RoutineStep[];
  onClose: () => void;
}

function fmt(sec: number): string {
  const s = Math.max(0, Math.ceil(sec));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/// Immersive guided routine timer (Workout tab). No data is saved — it's a
/// utility, not a session. Steps auto-advance off pure elapsed-time
/// derivation; Skip fast-forwards to the next step boundary.
export default function RoutineFullscreen({ name, steps: STEPS, onClose }: Props) {
  const TOTAL_S = STEPS.reduce((sum, st) => sum + st.s, 0);
  const [startedMs] = useState(() => Date.now());
  const [now, setNow] = useState(() => Date.now());
  // Seconds fast-forwarded by Skip presses (adds to real elapsed).
  const [skippedS, setSkippedS] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(t);
  }, []);

  const elapsed = (now - startedMs) / 1000 + skippedS;
  const done = elapsed >= TOTAL_S;

  // Derive the current step + time position inside it from elapsed.
  let stepIndex = 0;
  let stepStartS = 0;
  for (let i = 0; i < STEPS.length; i++) {
    if (elapsed < stepStartS + STEPS[i]!.s) {
      stepIndex = i;
      break;
    }
    stepStartS += STEPS[i]!.s;
    stepIndex = i;
  }
  const step = STEPS[stepIndex]!;
  const stepRemaining = done ? 0 : stepStartS + step.s - elapsed;
  const next = STEPS[stepIndex + 1];

  // Beep + vibrate on each step change (and at done) — same best-effort
  // audio pattern as the workout timer: context primed on user taps.
  const audioRef = useRef<AudioContext | null>(null);
  const lastBeepStepRef = useRef(0);
  function primeAudio() {
    try {
      if (!audioRef.current) audioRef.current = new AudioContext();
      void audioRef.current.resume();
    } catch {
      // no audio available
    }
  }
  const beepKey = done ? STEPS.length : stepIndex;
  useEffect(() => {
    if (beepKey === lastBeepStepRef.current) return;
    lastBeepStepRef.current = beepKey;
    const ctx = audioRef.current;
    if (ctx) {
      try {
        const o = ctx.createOscillator();
        const g = ctx.createGain();
        o.connect(g);
        g.connect(ctx.destination);
        o.frequency.value = done ? 660 : 880;
        g.gain.setValueAtTime(0.25, ctx.currentTime);
        o.start();
        o.stop(ctx.currentTime + 0.18);
      } catch {
        // ignore
      }
    }
    navigator.vibrate?.(done ? [200, 100, 200] : 150);
  }, [beepKey, done]);

  function skip() {
    primeAudio();
    if (done) return;
    setSkippedS((s) => s + stepRemaining);
  }

  const accent = done ? "var(--success)" : "var(--primary)";

  return createPortal(
    <div
      className="fullscreen-overlay"
      style={{
        background: `color-mix(in srgb, ${accent} 10%, var(--canvas))`,
        transition: "background 0.3s",
        display: "flex",
        justifyContent: "center",
      }}
    >
      <div
        style={{
          width: "100%",
          maxWidth: 520,
          display: "flex",
          flexDirection: "column",
          padding: "max(16px, env(safe-area-inset-top)) 16px max(16px, env(safe-area-inset-bottom))",
          boxSizing: "border-box",
        }}
      >
        {/* Top bar — glass chip (close) · title + total remaining · Skip pill */}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
          <button onClick={onClose} aria-label="Close routine" className="glass-chip">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
          <div style={{ textAlign: "center", minWidth: 0 }}>
            <div className="label-eyebrow" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
              {name}
            </div>
            <div style={{ fontWeight: 800, fontSize: 17, letterSpacing: "-0.02em" }}>
              {done ? "0:00" : fmt(TOTAL_S - elapsed)}
            </div>
          </div>
          <button
            className="glass-pill"
            onClick={skip}
            disabled={done}
            style={{ "--pill-tint": "var(--primary)" } as CSSProperties}
          >
            Skip
          </button>
        </div>

        {/* Step banner + countdown */}
        <div
          style={{
            flex: 1,
            margin: "12px 0",
            borderRadius: 20,
            background: `color-mix(in srgb, ${accent} 16%, var(--surface-1))`,
            border: `1px solid color-mix(in srgb, ${accent} 45%, transparent)`,
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            gap: 8,
            padding: "0 20px",
            textAlign: "center",
          }}
        >
          <div style={{ fontWeight: 800, letterSpacing: "0.08em", fontSize: 13, color: accent, textTransform: "uppercase" }}>
            {done ? "Complete" : `Step ${stepIndex + 1} / ${STEPS.length}`}
          </div>
          <div style={{ fontWeight: 800, fontSize: 26, letterSpacing: "-0.02em" }}>
            {done ? "All done 🤘" : step.label}
          </div>
          {!done && step.detail && (
            <div style={{ fontSize: 13, color: "var(--ink-muted)", lineHeight: 1.5 }}>
              {step.detail}
            </div>
          )}
          <div
            style={{
              fontWeight: 800,
              fontSize: "clamp(56px, 20vw, 120px)",
              lineHeight: 1.1,
              color: "var(--ink)",
            }}
          >
            {done ? "✓" : fmt(stepRemaining)}
          </div>
          {!done && next && (
            <div style={{ fontSize: 12, color: "var(--ink-faint)" }}>
              Next: {next.label} · {fmt(next.s)}
            </div>
          )}
          {done && (
            <button className="btn-primary" style={{ marginTop: 10, width: "auto", padding: "12px 28px" }} onClick={onClose}>
              Done
            </button>
          )}
        </div>

        {/* Segmented step progress bar */}
        <div style={{ display: "flex", gap: 4, paddingBottom: 4 }} onClick={primeAudio}>
          {STEPS.map((st, i) => {
            const startS = STEPS.slice(0, i).reduce((sum, x) => sum + x.s, 0);
            const frac = Math.max(0, Math.min(1, (elapsed - startS) / st.s));
            return (
              <div
                key={i}
                style={{
                  flex: st.s,
                  height: 5,
                  borderRadius: 3,
                  background: "var(--surface-2)",
                  overflow: "hidden",
                }}
              >
                <div
                  style={{
                    width: `${frac * 100}%`,
                    height: "100%",
                    background: accent,
                    borderRadius: 3,
                  }}
                />
              </div>
            );
          })}
        </div>
      </div>
    </div>,
    document.body,
  );
}
