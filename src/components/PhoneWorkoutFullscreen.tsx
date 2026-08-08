import { useEffect, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";
import {
  WORKOUT_ACTION_CIRCLE,
  WORKOUT_TIMER_FONT,
  clampCss,
  heroFontCss,
} from "../lib/fullscreenLayout";
import { syncWorkoutActivity } from "../lib/liveActivity";
import type { PhoneWorkoutAction, PhoneWorkoutState } from "../lib/phoneWorkout";
import { SheetLayerProvider } from "./Sheet";

type Running = Extract<PhoneWorkoutState, { phase: "running" }>;

interface Props {
  state: Running;
  dispatch: (action: PhoneWorkoutAction) => void;
  onMinimize: () => void;
}

const REST_TARGETS = [60, 120, 180, 300]; // 1 / 2 / 3 / 5 min
const REST_KEY = "sendmeter:rest-target-s";

function fmt(sec: number): string {
  const s = Math.max(0, Math.round(sec));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function loadTarget(): number {
  const v = Number(localStorage.getItem(REST_KEY));
  return REST_TARGETS.includes(v) ? v : 180;
}

/// Immersive full-screen timer for a running phone workout (SL-41 follow-up).
/// Free-form: tap Start boulder when you get on the wall, Done when you drop
/// off. While resting it counts DOWN from a rest target (auto-starting the
/// moment you drop off) and alerts at zero — the "separate rest countdown".
export default function PhoneWorkoutFullscreen({ state, dispatch, onMinimize }: Props) {
  const [now, setNow] = useState(() => Date.now());
  const [restTarget, setRestTarget] = useState(loadTarget);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(t);
  }, []);

  const climbing = state.climbingSince !== null;
  const startedMs = new Date(state.startedAt).getTime();
  const totalElapsed = (now - startedMs) / 1000;
  const boulders = state.attempts.length;

  // When the current rest period began: the end of the last attempt, or the
  // workout start if no attempt has been logged yet.
  const last = state.attempts[state.attempts.length - 1];
  const restStartedMs = last
    ? new Date(last.startedAt).getTime() + last.durationS * 1000
    : startedMs;
  const restElapsed = (now - restStartedMs) / 1000;
  const restRemaining = restTarget - restElapsed;
  const restProgress = Math.max(0, Math.min(1, restElapsed / restTarget));

  const onWall = climbing
    ? (now - new Date(state.climbingSince!).getTime()) / 1000
    : 0;

  // Alert once when the rest countdown hits zero — best-effort audio +
  // vibration (both are gated/unsupported on iOS web, so the big red flashing
  // 0:00 is the reliable cross-platform signal). The AudioContext is created
  // and resumed on button taps (a user gesture) so it has a chance on iOS.
  const audioRef = useRef<AudioContext | null>(null);
  const alertedForRef = useRef<number | null>(null);
  const restOver = !climbing && restRemaining <= 0;

  function primeAudio() {
    try {
      if (!audioRef.current) audioRef.current = new AudioContext();
      void audioRef.current.resume();
    } catch {
      // no audio available
    }
  }

  useEffect(() => {
    if (!restOver) return;
    if (alertedForRef.current === restStartedMs) return;
    alertedForRef.current = restStartedMs;
    const ctx = audioRef.current;
    if (ctx) {
      try {
        const o = ctx.createOscillator();
        const g = ctx.createGain();
        o.connect(g);
        g.connect(ctx.destination);
        o.frequency.value = 880;
        g.gain.setValueAtTime(0.25, ctx.currentTime);
        o.start();
        o.stop(ctx.currentTime + 0.18);
      } catch {
        // ignore
      }
    }
    navigator.vibrate?.([200, 100, 200]);
  }, [restOver, restStartedMs]);

  const accent = climbing ? "var(--success)" : restOver ? "var(--danger)" : "var(--primary)";
  const R = 54;
  const C = 2 * Math.PI * R;

  return createPortal(
    <SheetLayerProvider layer="fullscreen">
      <div
        className="fullscreen-overlay"
        style={{
          // Whole screen takes the phase color, Timer-Plus style.
          background: `color-mix(in srgb, ${accent} 12%, var(--canvas))`,
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
        minHeight: 0,
      }}
    >
      {/* Top bar — glass chip (minimize) · centered timer · glass pill (End) */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, flexShrink: 0 }}>
        <button onClick={onMinimize} aria-label="Minimize" className="glass-chip">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M6 9l6 6 6-6" />
          </svg>
        </button>
        <div style={{ textAlign: "center" }}>
          <div className="label-eyebrow">Workout</div>
          <div style={{ fontWeight: 800, fontSize: "var(--t-lg)", letterSpacing: "-0.02em" }}>
            {fmt(totalElapsed)}
          </div>
        </div>
        <button
          className="glass-pill"
          onClick={() => dispatch({ type: "end", at: new Date().toISOString() })}
          style={{ "--pill-tint": "var(--danger)" } as CSSProperties}
        >
          End
        </button>
      </div>

      {/* Phase banner + big timer */}
      <div
        style={{
          flex: 1,
          margin: "12px 0",
          borderRadius: 20,
          background: `color-mix(in srgb, ${accent} 18%, var(--surface-1))`,
          border: `1px solid color-mix(in srgb, ${accent} 45%, transparent)`,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: 4,
          animation: restOver ? "pulse 0.8s ease-in-out infinite" : undefined,
        }}
      >
        <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.08em", fontSize: "var(--t-lg)", color: accent }}>
          {climbing ? "CLIMBING" : restOver ? "REST OVER" : "RESTING"}
        </div>
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontWeight: 800,
            fontVariantNumeric: "tabular-nums",
            fontSize: heroFontCss(WORKOUT_TIMER_FONT),
            lineHeight: 1,
            color: "var(--ink)",
          }}
        >
          {climbing ? fmt(onWall) : fmt(Math.max(0, restRemaining))}
        </div>
        <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)" }}>
          {climbing ? "on the wall" : `rest target ${fmt(restTarget)}`}
          {" · "}
          <span style={{ color: "var(--ink)", fontWeight: 600 }}>
            {boulders} attempt{boulders === 1 ? "" : "s"}
          </span>
        </div>

        {/* Rest target chips — only while resting */}
        {!climbing && (
          <div style={{ display: "flex", gap: 6, marginTop: 10, flexWrap: "wrap", justifyContent: "center" }}>
            {REST_TARGETS.map((s) => (
              <button
                key={s}
                onClick={() => {
                  setRestTarget(s);
                  localStorage.setItem(REST_KEY, String(s));
                  alertedForRef.current = null; // allow a fresh alert for the new target
                  // Lock-screen card reads the target from state — re-sync it.
                  void syncWorkoutActivity(state);
                }}
                style={{
                  padding: "5px 11px",
                  borderRadius: 999,
                  fontFamily: "Inter, sans-serif",
                  fontSize: "var(--t-sm)",
                  fontWeight: 600,
                  cursor: "pointer",
                  border: `1px solid ${restTarget === s ? accent : "var(--border)"}`,
                  background: restTarget === s ? `color-mix(in srgb, ${accent} 20%, transparent)` : "transparent",
                  color: restTarget === s ? "var(--ink)" : "var(--ink-muted)",
                }}
              >
                {fmt(s)}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Big centered action — End lives in the top bar */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
        {/* Big circular action button — ring shows rest progress */}
        <button
          onClick={() => {
            primeAudio();
            dispatch({
              type: climbing ? "endBoulder" : "beginBoulder",
              at: new Date().toISOString(),
            });
          }}
          style={{
            position: "relative",
            // Shrinks with the viewport so it can never leave the screen on a
            // small phone (#221); pinned to the 132px design size above ~776px.
            width: clampCss(WORKOUT_ACTION_CIRCLE),
            height: clampCss(WORKOUT_ACTION_CIRCLE),
            borderRadius: "50%",
            border: "none",
            background: "transparent",
            cursor: "pointer",
            flexShrink: 0,
          }}
        >
          {/* Sized by the button, not in px — the viewBox keeps the ring maths
              (r=54 of 132) intact at any resolved diameter. */}
          <svg width="100%" height="100%" viewBox="0 0 132 132" style={{ position: "absolute", inset: 0, transform: "rotate(-90deg)" }}>
            <circle cx="66" cy="66" r={R} fill="none" stroke="var(--surface-2)" strokeWidth="8" />
            {!climbing && (
              <circle
                cx="66"
                cy="66"
                r={R}
                fill="none"
                stroke={accent}
                strokeWidth="8"
                strokeLinecap="round"
                strokeDasharray={C}
                strokeDashoffset={C * (1 - restProgress)}
              />
            )}
          </svg>
          <span
            style={{
              position: "absolute",
              inset: 0,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              flexDirection: "column",
              gap: 2,
              color: accent,
              fontFamily: "Inter, sans-serif",
              fontWeight: 800,
              fontSize: "var(--t-md)",
            }}
          >
            {climbing ? (
              <>
                <svg width="26" height="26" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
                DONE
              </>
            ) : (
              <>
                <svg width="30" height="30" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z" /></svg>
                BOULDER
              </>
            )}
          </span>
        </button>

      </div>
      </div>
      </div>
    </SheetLayerProvider>,
    document.body,
  );
}
