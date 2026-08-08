import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ROUTINE_TIMER_FONT, heroFontCss } from "../lib/fullscreenLayout";
import { useWakeLock } from "../hooks/useWakeLock";
import { ROUTINE_PREPARE_S, expandRoutine, routineDurationS } from "../lib/routine";
import {
  HEARTBEAT_MS,
  STALE_GAP_S,
  classifyElapsed,
  clearRoutineRun,
  loggedMinutes,
  saveRoutineRun,
  type RoutineLogOutcome,
  type RoutineRunState,
} from "../lib/routineRun";
import type { RoutineStep } from "../types";
import { SheetLayerProvider } from "./Sheet";

interface Props {
  /// Name of the routine — shown in the top-bar eyebrow.
  name: string;
  /// Preset id — persisted so an interrupted run can resume the right routine.
  presetId: string;
  /// The routine to run — from the selected preset (RoutineCard).
  steps: RoutineStep[];
  /// Resume an interrupted run (SL-97) — seeds the clock so a refresh mid-
  /// routine continues where it left off. Undefined = a fresh start.
  initial?: RoutineRunState;
  /// Plain close after the Done button — the run already logged via onFinish.
  onClose: () => void;
  /// Exited before completion (X button) — the owner decides whether to log a
  /// partial session. Passes the routine seconds elapsed at exit (SL-97).
  onExitEarly: (elapsedS: number) => void;
  /// Fired once when the routine completes (Done) — the owner logs it to
  /// History (SL-83). Routine minutes elapsed (pauses AND skips excluded,
  /// capped at the routine's own total — #483: never wall clock since start,
  /// and never fast-forwarded time — see F4 in the #483 review).
  onFinish?: (durationMin: number) => void;
  /// Fired INSTEAD of onFinish when `done` flips true after a long,
  /// unobserved gap — the interval resumed (JS execution was suspended, not
  /// reloaded, so RoutineCard's mount-time resume/abandonment check never
  /// ran) and nobody was present to see it actually finish (#483 review F3).
  /// The owner classifies via the same completed/partial/discarded logic as
  /// the mount-time resume decision and should always close the fullscreen —
  /// there's nobody there to see "All done" or tap the manual Done button.
  /// Required, not optional (#483 re-review N2): an owner that forgets to
  /// wire this loses the run silently — `finishedRef` is already set and
  /// `clearRoutineRun()` already ran by the time it would fire, so a no-op
  /// here means nothing is logged and no toast appears. TypeScript alone
  /// can't catch a missing optional prop; making it required at least means
  /// omitting it is a visible diff, and routineResumeInvariants.test.ts pins
  /// the call site itself.
  onStaleFinish: (outcome: RoutineLogOutcome) => void;
}

function fmt(sec: number): string {
  const s = Math.max(0, Math.ceil(sec));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/// Immersive guided routine timer (Workout tab). Steps expand to work×reps
/// with rests between repetitions (SL-83); a short GET READY leads in, and
/// Pause freezes the clock. Completing the routine logs it to History via
/// onFinish. Skip fast-forwards to the next segment boundary.
export default function RoutineFullscreen({
  name,
  presetId,
  steps,
  initial,
  onClose,
  onExitEarly,
  onFinish,
  onStaleFinish,
}: Props) {
  const SEGS = expandRoutine(steps, { prepareS: ROUTINE_PREPARE_S });
  const TOTAL_S = routineDurationS(SEGS);
  // Seed from a resumed run when present (SL-97), else start now.
  const [startedMs] = useState(() => initial?.startedMs ?? Date.now());
  const [now, setNow] = useState(() => Date.now());
  // Seconds fast-forwarded by Skip presses (adds to real elapsed).
  const [skippedS, setSkippedS] = useState(() => initial?.skippedS ?? 0);
  // Pause freezes the routine clock: while paused, elapsed derives from the
  // moment Pause was hit; accumulated pause time is subtracted after resume.
  const [pausedAtMs, setPausedAtMs] = useState<number | null>(
    () => initial?.pausedAtMs ?? null,
  );
  const [pausedTotalMs, setPausedTotalMs] = useState(
    () => initial?.pausedTotalMs ?? 0,
  );
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(t);
  }, []);

  const paused = pausedAtMs !== null;
  const elapsed =
    ((pausedAtMs ?? now) - startedMs - pausedTotalMs) / 1000 + skippedS;
  // Real seconds actually spent — `elapsed` above includes skippedS on
  // purpose (it drives segment position / the done flag below, and Skip must
  // be able to fast-forward to completion); a LOGGED duration must not
  // inherit that fast-forwarded credit (#483 review F4).
  const realElapsed = ((pausedAtMs ?? now) - startedMs - pausedTotalMs) / 1000;
  const done = elapsed >= TOTAL_S;

  // Keep the screen awake while the routine is actually running (#483
  // re-review N1, gated per F-B): without this, an ordinary iOS auto-lock
  // suspends the WebView mid-routine, the lastSeenMs heartbeat freezes at the
  // lock instant, and a routine the user actually COMPLETED classifies as a
  // 1-2 minute partial (or is discarded outright) purely as a function of
  // the auto-lock timeout — worse than the bug this fix replaced. Same
  // treatment ForceView already gives its own fullscreen timer, and same
  // conditional shape: not while paused (an indefinite, deliberate pause
  // shouldn't force the screen on) and not once `done` (the "All done"
  // screen, waiting on a manual Done tap, has nothing left to measure). The
  // hook's own cleanup releases the lock on unmount regardless
  // (onClose/onExitEarly/onFinish→Done/onStaleFinish all unmount this
  // component via `running`).
  useWakeLock(!done && !paused);

  // Last confirmed-on-screen-and-ticking instant (#483 review F1/F3/F5) —
  // seeded from a resumed run's own heartbeat, else "just started".
  const lastSeenRef = useRef(initial?.lastSeenMs ?? startedMs);

  // Persist the running clock (SL-97) so a refresh / relaunch resumes it, and
  // stamp the current heartbeat into the same record. Only while genuinely in
  // progress — the finish + close paths clear the key. Fires immediately on
  // structural changes (pause/resume, skip); cheap and infrequent.
  useEffect(() => {
    if (done) return;
    saveRoutineRun({
      presetId,
      startedMs,
      skippedS,
      pausedAtMs,
      pausedTotalMs,
      lastSeenMs: lastSeenRef.current,
    });
  }, [done, presetId, startedMs, skippedS, pausedAtMs, pausedTotalMs]);

  // Heartbeat (#483 review F1/F3/F5): advances lastSeenMs and re-persists
  // every ~HEARTBEAT_MS while genuinely ticking (not paused, not done) —
  // throttled off the existing 250ms tick via a ref rather than its own
  // interval, so a live run doesn't hit localStorage 4x/second.
  useEffect(() => {
    if (done || paused) return;
    if (now - lastSeenRef.current < HEARTBEAT_MS) return;
    lastSeenRef.current = now;
    saveRoutineRun({ presetId, startedMs, skippedS, pausedAtMs, pausedTotalMs, lastSeenMs: now });
  }, [now, done, paused, presetId, startedMs, skippedS, pausedAtMs, pausedTotalMs]);

  // X button: log a partial session if it ran long enough (owner decides),
  // else just close. The Done button (post-completion) uses onClose directly —
  // onFinish already logged the full session. Uses realElapsed, not elapsed,
  // so a run exited early after some Skips isn't over-credited (#483 F4).
  function handleClose() {
    clearRoutineRun();
    if (done) {
      onClose();
    } else {
      onExitEarly(realElapsed);
    }
  }

  // Derive the current segment from elapsed.
  let segIndex = 0;
  for (let i = 0; i < SEGS.length; i++) {
    if (elapsed < SEGS[i]!.startS + SEGS[i]!.durS) {
      segIndex = i;
      break;
    }
    segIndex = i;
  }
  const seg = SEGS[segIndex]!;
  const segRemaining = done ? 0 : seg.startS + seg.durS - elapsed;
  const next = SEGS[segIndex + 1];
  const stepCount = steps.length;

  // Log exactly once on completion — real routine minutes (skip-exclusive,
  // #483 F4), capped at TOTAL_S so a run left mounted (or resumed) well past
  // its own total never reports more than the routine could actually have
  // taken (#483). If `done` flipped after a long, unobserved gap since the
  // last heartbeat, the interval just resumed after a suspend (not a
  // reload — RoutineCard's mount-time check never ran for this run) and
  // nobody was present to see it finish (#483 review F3): fall back to
  // whatever the heartbeat last confirmed, classified the same way the
  // mount-time resume decision would.
  const finishedRef = useRef(false);
  useEffect(() => {
    if (!done || finishedRef.current) return;
    finishedRef.current = true;
    clearRoutineRun();
    const gapS = (now - lastSeenRef.current) / 1000;
    if (gapS <= STALE_GAP_S) {
      onFinish?.(loggedMinutes(realElapsed, TOTAL_S));
    } else {
      const seenRealElapsed = (lastSeenRef.current - startedMs - pausedTotalMs) / 1000;
      onStaleFinish(classifyElapsed(seenRealElapsed, TOTAL_S));
    }
    // Reads `now`/`realElapsed`/etc. from the same render `done` flipped in —
    // deliberately keyed on [done] only, not each of its inputs.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [done]);

  // Beep + vibrate on each segment change (and at done) — same best-effort
  // audio pattern as the workout timer: context primed on user taps.
  const audioRef = useRef<AudioContext | null>(null);
  const lastBeepRef = useRef(0);
  function primeAudio() {
    try {
      if (!audioRef.current) audioRef.current = new AudioContext();
      void audioRef.current.resume();
    } catch {
      // no audio available
    }
  }
  const beepKey = done ? SEGS.length : segIndex;
  useEffect(() => {
    if (beepKey === lastBeepRef.current) return;
    lastBeepRef.current = beepKey;
    const ctx = audioRef.current;
    if (ctx) {
      try {
        const o = ctx.createOscillator();
        const g = ctx.createGain();
        o.connect(g);
        g.connect(ctx.destination);
        o.frequency.value = done ? 660 : seg.kind === "rest" ? 440 : 880;
        g.gain.setValueAtTime(0.25, ctx.currentTime);
        o.start();
        o.stop(ctx.currentTime + 0.18);
      } catch {
        // ignore
      }
    }
    navigator.vibrate?.(done ? [200, 100, 200] : 150);
  }, [beepKey, done, seg.kind]);

  function skip() {
    primeAudio();
    if (done) return;
    setSkippedS((s) => s + segRemaining);
  }

  function togglePause() {
    primeAudio();
    if (done) return;
    if (pausedAtMs !== null) {
      setPausedTotalMs((t) => t + (Date.now() - pausedAtMs));
      setPausedAtMs(null);
    } else {
      setPausedAtMs(Date.now());
    }
  }

  const accent = done
    ? "var(--success)"
    : paused
      ? "var(--warning)"
      : seg.kind === "rest"
        ? "var(--info)"
        : seg.kind === "prepare"
          ? "var(--warning)"
          : "var(--primary)";

  return createPortal(
    <SheetLayerProvider layer="fullscreen">
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
          <button onClick={handleClose} aria-label="Close routine" className="glass-chip">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
          <div style={{ textAlign: "center", minWidth: 0 }}>
            <div className="label-eyebrow" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
              {name}
            </div>
            <div style={{ fontWeight: 800, fontSize: "var(--t-lg)", letterSpacing: "-0.02em" }}>
              {done ? "0:00" : fmt(TOTAL_S - elapsed)}
            </div>
          </div>
          <button
            className="glass-pill glass-pill-primary"
            onClick={skip}
            disabled={done}
          >
            Skip
          </button>
        </div>

        {/* Segment banner + countdown */}
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
          <div style={{ fontWeight: 800, letterSpacing: "0.08em", fontSize: "var(--t-base)", color: accent, textTransform: "uppercase" }}>
            {done
              ? "Complete"
              : paused
                ? "Paused"
                : seg.kind === "prepare"
                  ? "Get ready"
                  : seg.kind === "rest"
                    ? "Rest"
                    : `Step ${seg.stepIndex} / ${stepCount}`}
          </div>
          <div style={{ fontWeight: 800, fontSize: 26, letterSpacing: "-0.02em" }}>
            {done ? "All done 🤘" : seg.kind === "rest" && next ? `next: ${next.label}` : seg.label}
          </div>
          {!done && seg.kind === "work" && seg.reps > 1 && (
            <div style={{ fontSize: "var(--t-sm)", color: accent, fontWeight: 700 }}>
              rep {seg.rep} / {seg.reps}
            </div>
          )}
          {!done && seg.kind === "work" && seg.detail && (
            <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)", lineHeight: 1.5 }}>
              {seg.detail}
            </div>
          )}
          <div
            style={{
              fontWeight: 800,
              // Height-aware (#221): this overlay already fits 375×667, but a
              // width-only clamp would still overflow a short viewport.
              fontSize: heroFontCss(ROUTINE_TIMER_FONT),
              lineHeight: 1.1,
              color: "var(--ink)",
            }}
          >
            {done ? "✓" : fmt(segRemaining)}
          </div>
          {!done && next && (
            <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-faint)" }}>
              Next: {next.kind === "rest" ? "rest" : next.label} · {fmt(next.durS)}
            </div>
          )}
          {!done && (
            <button
              className={`glass-pill ${paused ? "glass-pill-success" : "glass-pill-warning"}`}
              onClick={togglePause}
              style={{ marginTop: 6 }}
            >
              {paused ? "Resume" : "Pause"}
            </button>
          )}
          {done && (
            <button className="btn-primary" style={{ marginTop: 10, width: "auto", padding: "12px 28px" }} onClick={handleClose}>
              Done
            </button>
          )}
        </div>

        {/* Segmented progress bar (one cell per runtime segment) */}
        <div style={{ display: "flex", gap: 4, paddingBottom: 4 }} onClick={primeAudio}>
          {SEGS.map((s, i) => {
            const frac = Math.max(0, Math.min(1, (elapsed - s.startS) / s.durS));
            return (
              <div
                key={i}
                style={{
                  flex: s.durS,
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
                    background: s.kind === "rest" ? "var(--info)" : accent,
                    borderRadius: 3,
                  }}
                />
              </div>
            );
          })}
        </div>
      </div>
      </div>
    </SheetLayerProvider>,
    document.body,
  );
}
