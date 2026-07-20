import { useEffect, useRef, type CSSProperties } from "react";
import { createPortal } from "react-dom";
import type { useTindeq } from "../hooks/useTindeq";
import { presetTargetKg, timelineAt, timelineDurationS } from "../lib/protocol";
import type { PresetRefs, ProtocolSegment } from "../lib/protocol";
import type { TindeqPreset, TindeqSide } from "../types";
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

  const bannerColor = done
    ? "var(--warning)"
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
        background: `color-mix(in srgb, ${bannerColor} ${pos || done ? 13 : 6}%, var(--canvas))`,
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
          gap: 10,
        }}
      >
        {/* Top bar */}
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
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
            disabled={measuring}
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
            padding: "18px 16px",
            background: `color-mix(in srgb, ${bannerColor} ${pos || done ? 22 : 12}%, var(--surface-1))`,
            border: `1px solid color-mix(in srgb, ${bannerColor} 50%, transparent)`,
            textAlign: "center",
            transition: "background 0.25s, border-color 0.25s",
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
                  fontSize: "clamp(56px, 18vw, 96px)",
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
                  fontSize: "clamp(64px, 20vw, 112px)",
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
                  fontSize: "clamp(56px, 18vw, 96px)",
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
            the gauge (brand-new tags are typed in the tab). A freshly typed
            tag has no recordings yet, so it isn't in allTags — include it as
            an option so the armed tag actually shows instead of "exercise…"
            (SL-81). */}
        {!measuring && (
          <div style={{ display: "flex", gap: 8 }}>
            <select
              className="field"
              value={tag.trim()}
              onChange={(e) => onTag(e.target.value)}
              style={{ padding: "9px 10px", fontSize: "var(--t-base)", flex: 2 }}
            >
              <option value="" disabled>
                {allTags.length ? "exercise…" : "no tags yet"}
              </option>
              {(allTags.includes(tag.trim()) || !tag.trim()
                ? allTags
                : [tag.trim(), ...allTags]
              ).map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
            <select
              className="field"
              value={globalSide}
              onChange={(e) => onSide(e.target.value as TindeqSide)}
              style={{ padding: "9px 10px", fontSize: "var(--t-base)", flex: 1 }}
            >
              <option value="">— side</option>
              <option value="left">Left</option>
              <option value="right">Right</option>
              <option value="both">Both</option>
            </select>
          </div>
        )}

        {/* Fullscreen live force chart */}
        <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center" }}>
          <ForceGauge
            current={tindeq.current}
            peak={tindeq.peak}
            avg={tindeq.avg}
            elapsedMs={tindeq.elapsedMs}
            samplesRef={tindeq.samplesRef}
            live={measuring}
            target={band}
            chartHeight={240}
          />
        </div>

        {/* Big circular action (like the workout timer) */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
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
              } else {
                primeAudio();
                onStart();
              }
            }}
            disabled={measuring ? saving : !canStart}
            style={{
              width: 118,
              height: 118,
              borderRadius: "50%",
              border: `3px solid ${measuring ? "var(--danger)" : "var(--success)"}`,
              background: `color-mix(in srgb, ${measuring ? "var(--danger)" : "var(--success)"} 16%, transparent)`,
              color: measuring ? "var(--danger)" : "var(--success)",
              cursor: "pointer",
              fontFamily: "Inter, sans-serif",
              fontWeight: 800,
              fontSize: "var(--t-md)",
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
              gap: 3,
              opacity: (measuring ? saving : !canStart) ? 0.45 : 1,
            }}
          >
            {measuring ? (
              <>
                <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
                {saving ? "SAVING…" : "STOP"}
              </>
            ) : (
              <>
                <svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z" /></svg>
                START
              </>
            )}
          </button>
          {!measuring && (
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
          {!canStart && !measuring && (
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
