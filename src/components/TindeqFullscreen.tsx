import { useEffect, useRef } from "react";
import type { useTindeq } from "../hooks/useTindeq";
import { protocolDurationS, protocolPhaseAt, repSide } from "../lib/protocol";
import type { TindeqPreset } from "../types";
import ForceGauge from "./ForceGauge";
import type { GaugeTarget } from "./ForceCurveCard";

interface Props {
  tindeq: ReturnType<typeof useTindeq>;
  preset: TindeqPreset | null;
  gaugeTarget: GaugeTarget | null;
  /// Tag is set outside (Next recording card); Start stays disabled without it.
  canStart: boolean;
  saving: boolean;
  onStart: () => void;
  onStop: () => void;
  onMinimize: () => void;
}

const PHASE_META = {
  hold: { label: "HOLD", color: "var(--success)" },
  rest: { label: "REST", color: "var(--primary)" },
  setRest: { label: "SET REST", color: "var(--info)" },
  done: { label: "DONE", color: "var(--warning)" },
} as const;

function fmt(sec: number): string {
  const s = Math.max(0, Math.ceil(sec));
  return s >= 60 ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}` : `${s}`;
}

/// Immersive fullscreen gauge (Timer-Plus style): a big color-coded phase
/// banner — HOLD / REST / SET REST countdowns from the selected protocol
/// preset — over the fullscreen live force chart.
export default function TindeqFullscreen({
  tindeq,
  preset,
  gaugeTarget,
  canStart,
  saving,
  onStart,
  onStop,
  onMinimize,
}: Props) {
  const measuring = tindeq.status === "measuring";
  const tS = tindeq.elapsedMs / 1000;
  const phase = preset && measuring ? protocolPhaseAt(preset, tS) : null;
  const meta = phase ? PHASE_META[phase.phase] : null;

  // Beep + haptic on protocol phase transitions (AudioContext primed on the
  // Start tap so iOS allows playback).
  const audioRef = useRef<AudioContext | null>(null);
  const lastPhaseKeyRef = useRef<string | null>(null);
  function primeAudio() {
    try {
      if (!audioRef.current) audioRef.current = new AudioContext();
      void audioRef.current.resume();
    } catch {
      // no audio
    }
  }
  useEffect(() => {
    if (!phase) {
      lastPhaseKeyRef.current = null;
      return;
    }
    const key = `${phase.phase}-${phase.set}-${phase.rep}`;
    if (lastPhaseKeyRef.current === key) return;
    const isFirst = lastPhaseKeyRef.current === null;
    lastPhaseKeyRef.current = key;
    if (isFirst) return;
    const ctx = audioRef.current;
    if (ctx) {
      try {
        const freq = phase.phase === "hold" ? 990 : phase.phase === "done" ? 660 : 440;
        const beeps = phase.phase === "done" ? 3 : 1;
        for (let i = 0; i < beeps; i++) {
          const o = ctx.createOscillator();
          const g = ctx.createGain();
          o.connect(g);
          g.connect(ctx.destination);
          o.frequency.value = freq;
          const t0 = ctx.currentTime + i * 0.25;
          g.gain.setValueAtTime(0.25, t0);
          o.start(t0);
          o.stop(t0 + 0.15);
        }
      } catch {
        // ignore
      }
    }
    navigator.vibrate?.(phase.phase === "hold" ? 150 : [80, 60, 80]);
  }, [phase]);

  const bannerColor = meta?.color ?? (measuring ? "var(--success)" : "var(--primary)");

  // Which hand this rep uses (only when the preset alternates sides).
  const side =
    preset?.alternateSides && phase && phase.phase !== "done"
      ? repSide(phase.rep)
      : null;
  // During a rest with alternation, show the side for the NEXT rep — that's
  // the hand you should be moving to.
  const nextSide =
    preset?.alternateSides && phase && (phase.phase === "rest" || phase.phase === "setRest")
      ? repSide(phase.phase === "setRest" ? 1 : phase.rep + 1)
      : null;

  // A preset's own target weight beats the zone-derived gauge target.
  const effectiveTarget: GaugeTarget | null =
    preset?.targetKg != null
      ? {
          kg: preset.targetKg,
          lowKg: preset.targetKg * 0.9,
          highKg: preset.targetKg * 1.1,
          workS: preset.holdS,
          label: preset.name,
        }
      : gaugeTarget;

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 900,
        background: "var(--canvas)",
        display: "flex",
        justifyContent: "center",
        overflowY: "auto",
      }}
    >
      <div
        style={{
          width: "100%",
          maxWidth: 520,
          display: "flex",
          flexDirection: "column",
          padding: "max(14px, env(safe-area-inset-top)) 16px max(16px, env(safe-area-inset-bottom))",
          boxSizing: "border-box",
          gap: 10,
        }}
      >
        {/* Top bar */}
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <button
            onClick={onMinimize}
            aria-label="Minimize"
            style={{ background: "none", border: "none", color: "var(--ink-muted)", cursor: "pointer", padding: 6 }}
          >
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M6 9l6 6 6-6" />
            </svg>
          </button>
          <div
            aria-hidden="true"
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              background: measuring ? "var(--success)" : "var(--info)",
              animation: measuring ? "pulse 1.6s ease-in-out infinite" : undefined,
            }}
          />
          <span style={{ fontSize: 12, color: "var(--ink)", flex: 1 }}>
            Progressor{" "}
            <span style={{ color: "var(--ink-muted)" }}>
              · {measuring ? "measuring" : "connected"}
            </span>
          </span>
          {tindeq.lowBattery && (
            <span
              className="tag"
              style={{
                background: "rgba(255,184,0,0.12)",
                color: "var(--warning)",
                border: "1px solid rgba(255,184,0,0.35)",
              }}
            >
              Low battery
            </span>
          )}
          <button
            onClick={() => void tindeq.tare()}
            disabled={measuring}
            style={{
              background: "none",
              border: "1px solid var(--ink-faint)",
              color: "var(--ink-muted)",
              padding: "6px 10px",
              borderRadius: 6,
              fontSize: 10,
              cursor: measuring ? "default" : "pointer",
              opacity: measuring ? 0.4 : 1,
              fontFamily: "Inter, sans-serif",
            }}
          >
            Tare
          </button>
          <button
            onClick={tindeq.disconnect}
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
            Disconnect
          </button>
        </div>

        {/* Colorful phase banner (Timer-Plus style) */}
        <div
          style={{
            borderRadius: 18,
            padding: "18px 16px",
            background: `color-mix(in srgb, ${bannerColor} ${phase ? 22 : 12}%, var(--surface-1))`,
            border: `1px solid color-mix(in srgb, ${bannerColor} 50%, transparent)`,
            textAlign: "center",
            transition: "background 0.25s, border-color 0.25s",
          }}
        >
          {phase && meta && preset ? (
            <>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  letterSpacing: "0.12em",
                  fontSize: 17,
                  color: meta.color,
                }}
              >
                {meta.label}
                {side && phase.phase === "hold" && ` · ${side.toUpperCase()}`}
              </div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontVariantNumeric: "tabular-nums",
                  fontSize: "clamp(64px, 20vw, 112px)",
                  lineHeight: 1,
                }}
              >
                {phase.phase === "done" ? "✓" : fmt(phase.remaining)}
              </div>
              <div style={{ fontSize: 13, color: "var(--ink-muted)", marginTop: 4 }}>
                rep {phase.rep}/{preset.reps} · set {phase.set}/{preset.sets}
                {phase.phase === "done" && " — Stop & Save"}
                {nextSide && (
                  <span style={{ color: "var(--warning)", fontWeight: 700 }}>
                    {" "}
                    · switch to {nextSide.toUpperCase()}
                  </span>
                )}
              </div>
            </>
          ) : measuring ? (
            <>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  letterSpacing: "0.12em",
                  fontSize: 17,
                  color: bannerColor,
                }}
              >
                MEASURING
              </div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontVariantNumeric: "tabular-nums",
                  fontSize: "clamp(56px, 18vw, 96px)",
                  lineHeight: 1,
                }}
              >
                {(tindeq.elapsedMs / 1000).toFixed(1)}
                <span style={{ fontSize: 20, color: "var(--ink-muted)" }}>s</span>
              </div>
            </>
          ) : (
            <>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  letterSpacing: "0.12em",
                  fontSize: 17,
                  color: bannerColor,
                }}
              >
                READY
              </div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)", marginTop: 6, lineHeight: 1.5 }}>
                {preset ? (
                  <>
                    <span style={{ color: "var(--ink)", fontWeight: 600 }}>{preset.name}</span>{" "}
                    · {preset.holdS}s × {preset.reps} × {preset.sets} · ~
                    {Math.round(protocolDurationS(preset) / 60)}min
                    <br />
                    guided timer starts with Start
                  </>
                ) : effectiveTarget ? (
                  <>
                    Target: <span style={{ color: "var(--success)" }}>{effectiveTarget.label}</span>
                  </>
                ) : (
                  "Free hold — pick a preset or target in the tab for a guided timer."
                )}
              </div>
            </>
          )}
        </div>

        {/* Fullscreen live force chart (preset target beats zone target) */}
        <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center" }}>
          <ForceGauge
            current={tindeq.current}
            peak={tindeq.peak}
            elapsedMs={tindeq.elapsedMs}
            samplesRef={tindeq.samplesRef}
            live={measuring}
            target={effectiveTarget}
            chartHeight={280}
          />
        </div>

        {/* One big action */}
        {measuring ? (
          <button
            className="btn-primary"
            disabled={saving}
            onClick={onStop}
            style={{ background: "var(--danger)", padding: "16px 20px", fontSize: 15 }}
          >
            {saving ? "Saving…" : "Stop & Save"}
          </button>
        ) : (
          <button
            className="btn-primary"
            disabled={!canStart}
            onClick={() => {
              primeAudio();
              onStart();
            }}
            style={{ background: "var(--success)", padding: "16px 20px", fontSize: 15 }}
          >
            Start
          </button>
        )}
        {!canStart && !measuring && (
          <div style={{ fontSize: 10, color: "var(--ink-faint)", textAlign: "center" }}>
            Set the exercise tag in the tab first (minimize ⌄).
          </div>
        )}
      </div>
    </div>
  );
}
