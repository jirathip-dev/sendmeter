import { useEffect, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";
import type { useTindeq } from "../hooks/useTindeq";
import {
  BANNER_PAD_Y,
  FORCE_ACTION_CIRCLE,
  FORCE_HERO_SM_FONT,
  FORCE_TIMER_FONT,
  SECTION_GAP,
  TAG_STRIP_MAX,
  clampCss,
  heroFontCss,
} from "../lib/fullscreenLayout";
import { presetTargetKg, timelineAt, timelineDurationS } from "../lib/protocol";
import type { PresetRefs, ProtocolSegment } from "../lib/protocol";
import { prepRemainingS, startsWithCountdown } from "../lib/forcePrepare";
import type { TindeqPreset, TindeqSide } from "../types";
import BoxChip from "./BoxChip";
import ForceGauge from "./ForceGauge";
import type { GaugeTarget } from "./ForceCurveCard";

interface Props {
  tindeq: ReturnType<typeof useTindeq>;
  /// The active guided protocol (custom preset or zone prescription) and its
  /// expanded timeline — built by the parent so the per-rep recorder and this
  /// display always agree. Null = free hold.
  protocol: TindeqPreset | null;
  timeline: ProtocolSegment[] | null;
  /// Fallback load band for the live chart (zone band / set-1 preset band —
  /// with a %-of-PR ramp the band is re-derived here per CURRENT set).
  target: GaugeTarget | null;
  /// Force references (PR / CF / W' / maxF) the preset resolves its target
  /// against — re-derived per CURRENT set for a %-ramp band.
  presetRefs: PresetRefs;
  /// Tab-global side — shown during holds when the protocol doesn't alternate.
  globalSide: TindeqSide;
  /// Tab-global tag + existing tags, so a free hold can be armed right here
  /// (new tags are still typed in the tab).
  tag: string;
  allTags: string[];
  onTag: (t: string) => void;
  onSide: (s: TindeqSide) => void;
  canStart: boolean;
  saving: boolean;
  /// Get-ready countdown before the first hold (persisted preference).
  prepare: boolean;
  onTogglePrepare: (on: boolean) => void;
  /// Guided-protocol clock: PROTOCOL seconds (physical clock + Pause/Skip
  /// shift) and whether it's frozen. The parent owns the shift so the recorder
  /// and this display stay in lockstep.
  protoTS: number;
  paused: boolean;
  onPause: () => void;
  onSkip: () => void;
  onStart: () => void;
  onStop: () => void;
  onMinimize: () => void;
}

const PHASE_META = {
  prepare: { label: "GET READY", color: "var(--warning)" },
  hold: { label: "HOLD", color: "var(--success)" },
  switch: { label: "SWITCH HANDS", color: "var(--warning)" },
  rest: { label: "REST", color: "var(--primary)" },
  setRest: { label: "SET REST", color: "var(--info)" },
} as const;

function fmt(sec: number): string {
  const s = Math.max(0, Math.ceil(sec));
  return s >= 60 ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}` : `${s}`;
}

/// Immersive fullscreen gauge (Timer-Plus style): a big color-coded banner
/// walks the protocol timeline — GET READY / HOLD·LEFT / SWITCH HANDS /
/// REST — over the fullscreen live force chart, with a big circular
/// start/stop like the workout timer.
export default function ForceFullscreen({
  tindeq,
  protocol,
  timeline,
  target,
  presetRefs,
  globalSide,
  tag,
  allTags,
  onTag,
  onSide,
  canStart,
  saving,
  prepare,
  onTogglePrepare,
  protoTS,
  paused,
  onPause,
  onSkip,
  onStart,
  onStop,
  onMinimize,
}: Props) {
  const measuring = tindeq.status === "measuring";
  // Walk the timeline in protocol time (parent-owned; freezes while paused).
  const pos = timeline && measuring ? timelineAt(timeline, protoTS) : null;
  const done = timeline !== null && measuring && pos === null;
  const meta = pos ? PHASE_META[pos.seg.phase] : null;

  // Beep + haptic on segment transitions (AudioContext primed on the Start
  // tap so iOS allows playback).
  const audioRef = useRef<AudioContext | null>(null);
  const lastKeyRef = useRef<string | null>(null);
  function primeAudio() {
    try {
      if (!audioRef.current) audioRef.current = new AudioContext();
      void audioRef.current.resume();
    } catch {
      // no audio
    }
  }
  useEffect(() => {
    if (!measuring || !timeline) {
      lastKeyRef.current = null;
      return;
    }
    const key = done
      ? "done"
      : pos
        ? `${pos.seg.phase}-${pos.seg.set}-${pos.seg.rep}-${pos.seg.side ?? ""}`
        : null;
    if (key === null || lastKeyRef.current === key) return;
    const isFirst = lastKeyRef.current === null;
    lastKeyRef.current = key;
    if (isFirst) return;
    const ctx = audioRef.current;
    const phase = done ? "done" : pos!.seg.phase;
    if (ctx) {
      try {
        const freq = phase === "hold" ? 990 : phase === "done" ? 660 : 440;
        const beeps = phase === "done" ? 3 : phase === "switch" ? 2 : 1;
        for (let i = 0; i < beeps; i++) {
          const o = ctx.createOscillator();
          const g = ctx.createGain();
          o.connect(g);
          g.connect(ctx.destination);
          o.frequency.value = freq;
          const t0 = ctx.currentTime + i * 0.22;
          g.gain.setValueAtTime(0.25, t0);
          o.start(t0);
          o.stop(t0 + 0.15);
        }
      } catch {
        // ignore
      }
    }
    navigator.vibrate?.(phase === "hold" ? 150 : [80, 60, 80]);
  }, [measuring, timeline, pos, done]);

  // Free-hold get-ready countdown (#312) — null while idle/measuring/guided.
  // `prepNow` is a ticked clock (never Date.now() in render, same pattern as
  // the workout timers' `now` state); `prepStartedMs` only ever moves via the
  // Start/Cancel taps below, never from inside an effect.
  const [prepStartedMs, setPrepStartedMs] = useState<number | null>(null);
  const [prepNow, setPrepNow] = useState(() => Date.now());
  const prepRemaining = prepRemainingS(prepStartedMs, prepNow);
  const counting = prepRemaining !== null && prepRemaining > 0;

  useEffect(() => {
    if (prepStartedMs === null) return;
    const t = setInterval(() => setPrepNow(Date.now()), 200);
    return () => clearInterval(t);
  }, [prepStartedMs]);

  // Fire the hold-start cue + onStart exactly once when the countdown reaches
  // 0 — same beep/vibrate cue as a timeline hold transition above. Guarded by
  // a ref (not state) so this effect only ever calls the owner callback / Web
  // Audio, never setState, mirroring RoutineFullscreen's onFinish effect.
  const prepFiredRef = useRef(false);
  useEffect(() => {
    if (prepStartedMs === null) {
      prepFiredRef.current = false;
      return;
    }
    if (prepRemaining === null || prepRemaining > 0 || prepFiredRef.current) return;
    prepFiredRef.current = true;
    const ctx = audioRef.current;
    if (ctx) {
      try {
        const o = ctx.createOscillator();
        const g = ctx.createGain();
        o.connect(g);
        g.connect(ctx.destination);
        o.frequency.value = 990;
        g.gain.setValueAtTime(0.25, ctx.currentTime);
        o.start();
        o.stop(ctx.currentTime + 0.15);
      } catch {
        // ignore
      }
    }
    navigator.vibrate?.(150);
    onStart();
    // onStart is an owner callback read at fire time (mirrors
    // RoutineFullscreen's onFinish effect).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prepStartedMs, prepRemaining]);

  const bannerColor = done
    ? "var(--warning)"
    : counting
      ? PHASE_META.prepare.color
      : (meta?.color ?? (measuring ? "var(--success)" : "var(--primary)"));

  // Side shown on a hold: the segment's own hand, else the global pick.
  const holdSide =
    pos?.seg.phase === "hold"
      ? (pos.seg.side ??
        (globalSide === "left" || globalSide === "right" ? globalSide : null))
      : null;

  // Upcoming hand during a rest (alternating protocols): the next hold
  // segment's side — same hand within a set, the other one across a set rest.
  const nextHoldSide =
    pos && timeline
      ? (timeline.find(
          (s) => s.phase === "hold" && s.startS >= pos.seg.startS + pos.seg.durS,
        )?.side ?? null)
      : null;

  // Per-set target band: a %-of-PR preset ramps up each set; the chart band
  // follows the CURRENT set live (set 1 while idle, last set once done).
  const currentSet = pos?.seg.set ?? (done ? (protocol?.sets ?? 1) : 1);
  const protocolKg = protocol ? presetTargetKg(protocol, presetRefs, currentSet) : null;
  const band: GaugeTarget | null =
    protocol && protocolKg != null
      ? {
          kg: protocolKg,
          lowKg: protocolKg * 0.9,
          highKg: protocolKg * 1.1,
          workS: protocol.holdS,
          label:
            protocol.targetPct != null && protocol.sets > 1
              ? `${protocol.name} · set ${currentSet}: ${protocolKg.toFixed(1)} kg`
              : protocol.name,
        }
      : target;

  return createPortal(
    <div
      className="fullscreen-overlay"
      style={{
        // The whole screen takes the phase color, Timer-Plus style.
        background: `color-mix(in srgb, ${bannerColor} ${pos || done || counting ? 13 : 6}%, var(--canvas))`,
        transition: "background 0.3s",
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
          // Everything but the chart is intrinsically sized; minHeight:0 is
          // what lets the chart below actually give ground instead of the
          // column growing past the screen (#221).
          minHeight: 0,
          gap: clampCss(SECTION_GAP),
        }}
      >
        {/* Top bar */}
        <div style={{ display: "flex", alignItems: "center", gap: 8, flexShrink: 0 }}>
          <button onClick={onMinimize} aria-label="Minimize" className="glass-chip">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M6 9l6 6 6-6" />
            </svg>
          </button>
          <div
            aria-hidden="true"
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              background: paused
                ? "var(--warning)"
                : measuring
                  ? "var(--success)"
                  : "var(--info)",
              animation:
                measuring && !paused ? "pulse 1.6s ease-in-out infinite" : undefined,
            }}
          />
          <span style={{ fontSize: "var(--t-sm)", color: "var(--ink)", flex: 1 }}>
            Progressor{" "}
            <span style={{ color: "var(--ink-muted)" }}>
              · {paused ? "paused" : measuring ? "measuring" : "connected"}
            </span>
          </span>
          {tindeq.lowBattery && (
            <span
              className="tag"
              style={{
                background: "rgba(221,177,58,0.12)",
                color: "var(--warning)",
                border: "1px solid rgba(221,177,58,0.35)",
              }}
            >
              Low battery
            </span>
          )}
          <button
            onClick={() => void tindeq.tare()}
            disabled={measuring || counting}
            className="glass-pill"
            style={{ padding: "7px 13px", fontSize: "var(--t-2xs)" }}
          >
            Tare
          </button>
          <button
            onClick={tindeq.disconnect}
            className="glass-pill"
            style={{ padding: "7px 13px", fontSize: "var(--t-2xs)", "--pill-tint": "var(--danger)" } as CSSProperties}
          >
            Disconnect
          </button>
        </div>

        {/* Colorful phase banner (Timer-Plus style) */}
        <div
          style={{
            borderRadius: 18,
            padding: `${clampCss(BANNER_PAD_Y)} 16px`,
            background: `color-mix(in srgb, ${bannerColor} ${pos || done || counting ? 22 : 12}%, var(--surface-1))`,
            border: `1px solid color-mix(in srgb, ${bannerColor} 50%, transparent)`,
            textAlign: "center",
            transition: "background 0.25s, border-color 0.25s",
            flexShrink: 0,
          }}
        >
          {done && protocol ? (
            <>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.12em", fontSize: "var(--t-lg)", color: bannerColor }}>
                DONE
              </div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: heroFontCss(FORCE_HERO_SM_FONT),
                  lineHeight: 1,
                }}
              >
                ✓
              </div>
              <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)", marginTop: 4 }}>
                protocol complete — Stop to finish
              </div>
            </>
          ) : pos && meta && protocol ? (
            <>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  letterSpacing: "0.12em",
                  fontSize: "var(--t-lg)",
                  color: meta.color,
                }}
              >
                {meta.label}
                {holdSide && ` · ${holdSide.toUpperCase()}`}
                {pos.seg.phase === "switch" && pos.seg.side && ` → ${pos.seg.side.toUpperCase()}`}
              </div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontVariantNumeric: "tabular-nums",
                  fontSize: heroFontCss(FORCE_TIMER_FONT),
                  lineHeight: 1,
                }}
              >
                {fmt(pos.remaining)}
              </div>
              <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)", marginTop: 4 }}>
                {pos.seg.phase === "prepare"
                  ? "get on the hold…"
                  : `rep ${pos.seg.rep}/${protocol.reps} · set ${pos.seg.set}/${protocol.sets}`}
                {(pos.seg.phase === "rest" || pos.seg.phase === "setRest") &&
                  protocol.alternateSides &&
                  nextHoldSide && (
                    <span style={{ color: "var(--warning)", fontWeight: 700 }}>
                      {" "}
                      · next: {nextHoldSide.toUpperCase()}
                    </span>
                  )}
              </div>
            </>
          ) : counting ? (
            <>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.12em", fontSize: "var(--t-lg)", color: PHASE_META.prepare.color }}>
                {PHASE_META.prepare.label}
              </div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontVariantNumeric: "tabular-nums",
                  fontSize: heroFontCss(FORCE_TIMER_FONT),
                  lineHeight: 1,
                }}
              >
                {fmt(prepRemaining ?? 0)}
              </div>
              <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)", marginTop: 4 }}>
                get on the hold…
              </div>
            </>
          ) : measuring ? (
            <>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.12em", fontSize: "var(--t-lg)", color: bannerColor }}>
                MEASURING
              </div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontVariantNumeric: "tabular-nums",
                  fontSize: heroFontCss(FORCE_HERO_SM_FONT),
                  lineHeight: 1,
                }}
              >
                {(tindeq.elapsedMs / 1000).toFixed(1)}
                <span style={{ fontSize: "var(--t-xl)", color: "var(--ink-muted)" }}>s</span>
              </div>
            </>
          ) : (
            <>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.12em", fontSize: "var(--t-lg)", color: bannerColor }}>
                READY
              </div>
              <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginTop: 6, lineHeight: 1.5 }}>
                {protocol && timeline ? (
                  <>
                    <span style={{ color: "var(--ink)", fontWeight: 600 }}>{protocol.name}</span>{" "}
                    · {protocol.holdS}s × {protocol.reps} × {protocol.sets}
                    {protocol.alternateSides && " · L⇄R"} · ~
                    {Math.round(timelineDurationS(timeline) / 60)}min
                    <br />
                    each rep saves as its own recording
                  </>
                ) : band ? (
                  <>
                    Target: <span style={{ color: "var(--success)" }}>{band.label}</span>
                  </>
                ) : (
                  "Free hold — pick a zone or preset in the tab for a guided timer."
                )}
              </div>
            </>
          )}
        </div>

        {/* Quick exercise + side pickers — arm a free hold without leaving
            the gauge (brand-new tags are typed in the tab). Box chips, no
            dropdowns (SL-82); a freshly typed tag with no recordings yet is
            included so the armed tag shows (SL-81). */}
        {!measuring && !counting && (
          <div style={{ display: "flex", flexDirection: "column", gap: 6, flexShrink: 0 }}>
            {/* A user with many tags used to wrap this strip to four or five
                rows and shove START off the bottom (#221). Cap it at roughly
                two rows and let the strip scroll instead of the overlay. */}
            <div
              style={{
                display: "flex",
                gap: 6,
                flexWrap: "wrap",
                maxHeight: clampCss(TAG_STRIP_MAX),
                overflowY: "auto",
              }}
            >
              {(allTags.includes(tag.trim()) || !tag.trim()
                ? allTags
                : [tag.trim(), ...allTags]
              ).map((t) => (
                <BoxChip
                  key={t}
                  small
                  label={t}
                  active={t === tag.trim()}
                  onClick={() => onTag(t)}
                />
              ))}
              {allTags.length === 0 && !tag.trim() && (
                <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", alignSelf: "center" }}>
                  no tags yet — add one in the tab
                </span>
              )}
            </div>
            <div style={{ display: "flex", gap: 6 }}>
              {(
                [
                  ["", "—"],
                  ["left", "Left"],
                  ["right", "Right"],
                  ["both", "Both"],
                ] as const
              ).map(([v, label]) => (
                <BoxChip
                  key={v}
                  small
                  label={label}
                  active={globalSide === v}
                  onClick={() => onSide(v as TindeqSide)}
                  style={{ flex: 1 }}
                />
              ))}
            </div>
          </div>
        )}

        {/* Fullscreen live force chart — the ONE flexible block. Everything
            above and below is intrinsically sized, so the trace takes the
            leftover height (down to its own floor) and the overlay fits one
            screen instead of scrolling (#221). */}
        <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}>
          <ForceGauge
            current={tindeq.current}
            peak={tindeq.peak}
            avg={tindeq.avg}
            elapsedMs={tindeq.elapsedMs}
            samplesRef={tindeq.samplesRef}
            live={measuring}
            target={band}
            fill
          />
        </div>

        {/* Big circular action (like the workout timer) */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8, flexShrink: 0 }}>
          {/* Pause / Skip — guided runs only. Both finalize the current rep in
              the parent before touching the protocol clock. */}
          {measuring && timeline && !done && (
            <div style={{ display: "flex", gap: 10, marginBottom: 2 }}>
              <button
                onClick={onPause}
                className="glass-pill"
                style={
                  {
                    padding: "9px 18px",
                    fontSize: "var(--t-sm)",
                    display: "flex",
                    alignItems: "center",
                    gap: 6,
                    "--pill-tint": paused ? "var(--success)" : "var(--warning)",
                  } as CSSProperties
                }
              >
                {paused ? (
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z" /></svg>
                ) : (
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1" /><rect x="14" y="5" width="4" height="14" rx="1" /></svg>
                )}
                {paused ? "Resume" : "Pause"}
              </button>
              <button
                onClick={onSkip}
                className="glass-pill"
                style={
                  {
                    padding: "9px 18px",
                    fontSize: "var(--t-sm)",
                    display: "flex",
                    alignItems: "center",
                    gap: 6,
                    "--pill-tint": "var(--info)",
                  } as CSSProperties
                }
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M6 18l8.5-6L6 6v12zM16 6h2v12h-2z" /></svg>
                Skip
              </button>
            </div>
          )}
          <button
            onClick={() => {
              if (measuring) {
                onStop();
                return;
              }
              if (counting) {
                // Cancel — nothing is measuring yet, so this must never
                // call onStop (#312).
                setPrepStartedMs(null);
                return;
              }
              primeAudio();
              if (startsWithCountdown(protocol, prepare)) {
                setPrepStartedMs(Date.now());
              } else {
                onStart();
              }
            }}
            disabled={measuring ? saving : counting ? false : !canStart}
            style={{
              width: clampCss(FORCE_ACTION_CIRCLE),
              height: clampCss(FORCE_ACTION_CIRCLE),
              flexShrink: 0,
              borderRadius: "50%",
              border: `3px solid ${measuring || counting ? "var(--danger)" : "var(--success)"}`,
              background: `color-mix(in srgb, ${measuring || counting ? "var(--danger)" : "var(--success)"} 16%, transparent)`,
              color: measuring || counting ? "var(--danger)" : "var(--success)",
              cursor: "pointer",
              fontFamily: "Inter, sans-serif",
              fontWeight: 800,
              fontSize: "var(--t-md)",
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
              gap: 3,
              opacity: (measuring ? saving : counting ? false : !canStart) ? 0.45 : 1,
            }}
          >
            {measuring ? (
              <>
                <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
                {saving ? "SAVING…" : "STOP"}
              </>
            ) : counting ? (
              <>
                <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
                CANCEL
              </>
            ) : (
              <>
                <svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z" /></svg>
                START
              </>
            )}
          </button>
          {!measuring && !counting && (
            <label
              style={{
                display: "flex",
                alignItems: "center",
                gap: 6,
                fontSize: "var(--t-xs)",
                color: "var(--ink-muted)",
                cursor: "pointer",
              }}
            >
              <input
                type="checkbox"
                checked={prepare}
                onChange={(e) => onTogglePrepare(e.target.checked)}
              />
              5s get-ready countdown
            </label>
          )}
          {!canStart && !measuring && !counting && (
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", textAlign: "center" }}>
              {allTags.length
                ? "Pick an exercise above to start."
                : "Type your first exercise tag in the tab (minimize ⌄)."}
            </div>
          )}
        </div>
      </div>
    </div>,
    document.body,
  );
}
