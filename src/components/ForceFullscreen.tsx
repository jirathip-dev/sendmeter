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
import {
  firstHoldSide,
  holdForSet,
  holdsSummary,
  prescriptionWorkS,
  presetTargetKg,
  presetTargetKgRange,
  protocolBandLabel,
  timelineAt,
  timelineDurationS,
} from "../lib/protocol";
import type { PresetRefs, ProtocolSegment } from "../lib/protocol";
import {
  reverseActionCadenceKey,
  reverseActionTargetBand,
  type ReverseActionSegment,
} from "../lib/reverseAction";
import { prepRemainingS, startsWithCountdown } from "../lib/forcePrepare";
import { DEFAULT_HANDS_FREE_FORCE_CONFIG } from "../lib/handsFreeForce";
import { adaptiveStaticHolds, type AdaptiveStaticState } from "../lib/adaptiveStaticProtocol";
import {
  idleTargetZoneCoach,
  stepTargetZoneCoach,
  targetZoneCoachActive,
  targetZoneAtForce,
  type TargetZone,
  type TargetZoneCue,
} from "../lib/targetZoneCoach";
import type { TindeqPreset, TindeqSide } from "../types";
import BoxChip from "./BoxChip";
import ForceGauge from "./ForceGauge";
import PresetPlanChart from "./PresetPlanChart";
import type { GaugeTarget } from "./ForceCurveCard";
import ReverseActionWorkDisplay from "./ReverseActionWorkDisplay";
import ProtocolBadge from "./ProtocolBadge";
import {
  prescriptionForSegment,
  targetHoldSegment,
  type AlternatingPrescription,
} from "../lib/alternatingProtocol";

interface Props {
  tindeq: ReturnType<typeof useTindeq>;
  /// The active guided protocol (custom preset or zone prescription) and its
  /// expanded timeline — built by the parent so the per-rep recorder and this
  /// display always agree. Null = free hold.
  protocol: TindeqPreset | null;
  timeline: (ProtocolSegment | ReverseActionSegment)[] | null;
  /// Fallback load band for the live chart (zone band / set-1 preset band —
  /// with a %-of-PR ramp the band is re-derived here per CURRENT set).
  target: GaugeTarget | null;
  /// Force references (PR / CF / W' / maxF) the preset resolves its target
  /// against — re-derived per CURRENT set for a %-ramp band.
  presetRefs: PresetRefs;
  alternatingPrescription: AlternatingPrescription | null;
  /// Tab-global side — shown during holds when the protocol doesn't alternate.
  globalSide: TindeqSide;
  /// Tab-global tag + existing tags, so a free hold can be armed right here
  /// (new tags are still typed in the tab).
  tag: string;
  allTags: string[];
  onTag: (t: string) => void;
  onSide: (s: TindeqSide) => void;
  onOpenSetupGuide: () => void;
  /// Unarm the active zone/preset (#298) — falls back to a free hold.
  onClearProtocol: () => void;
  canStart: boolean;
  /// Why Start is currently disabled, beyond the ordinary "no tag picked yet"
  /// (#298 round 6, finding 3) — e.g. an armed zone's curve is still fitting
  /// for a tag it wasn't built under. Null = no specific reason (the ordinary
  /// no-tag messages below still apply). Never a silent no-op: `canStart`
  /// false must always say why.
  startBlockedReason: string | null;
  saving: boolean;
  handsFree: boolean;
  adaptiveState: AdaptiveStaticState | null;
  onToggleHandsFree: (on: boolean) => void;
  targetCoach: boolean;
  onToggleTargetCoach: (on: boolean) => void;
  onArm: () => void;
  onCancelArm: () => void;
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
  protocolQuality: string | null;
}

const PHASE_META = {
  prepare: { label: "GET READY", color: "var(--warning)" },
  hold: { label: "HOLD", color: "var(--success)" },
  switch: { label: "SWITCH HANDS", color: "var(--warning)" },
  rest: { label: "REST", color: "var(--primary)" },
  setRest: { label: "SET REST", color: "var(--info)" },
  move: { label: "MOVE", color: "var(--success)" },
} as const;

interface CoachDisplay {
  active: boolean;
  zone: TargetZone;
  lowKg: number | null;
  highKg: number | null;
}

const IDLE_COACH_DISPLAY: CoachDisplay = {
  active: false,
  zone: "unknown",
  lowKg: null,
  highKg: null,
};

const COACH_PRESENTATION: Record<
  TargetZone,
  { label: string; symbol: string; color: string }
> = {
  unknown: { label: "COACHING…", symbol: "•", color: "var(--ink-muted)" },
  below: { label: "BELOW", symbol: "↓", color: "var(--info)" },
  "in-zone": { label: "IN ZONE", symbol: "✓", color: "var(--success)" },
  above: { label: "ABOVE", symbol: "↑", color: "var(--danger)" },
};

function playTargetZoneCue(ctx: AudioContext | null, cue: TargetZoneCue) {
  if (!ctx) return;
  const tones =
    cue === "below"
      ? [
          { hz: 360, offsetS: 0 },
          { hz: 260, offsetS: 0.09 },
        ]
      : cue === "above"
        ? [
            { hz: 1_120, offsetS: 0 },
            { hz: 1_420, offsetS: 0.09 },
          ]
        : [{ hz: 720, offsetS: 0 }];
  try {
    for (const tone of tones) {
      const oscillator = ctx.createOscillator();
      const gain = ctx.createGain();
      oscillator.type = "triangle";
      oscillator.connect(gain);
      gain.connect(ctx.destination);
      oscillator.frequency.value = tone.hz;
      const startsAt = ctx.currentTime + tone.offsetS;
      gain.gain.setValueAtTime(cue === "in-zone" ? 0.14 : 0.2, startsAt);
      gain.gain.exponentialRampToValueAtTime(0.001, startsAt + 0.07);
      oscillator.start(startsAt);
      oscillator.stop(startsAt + 0.075);
    }
  } catch {
    // Audio is optional; the visible state remains the source of truth.
  }
}

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
  alternatingPrescription,
  globalSide,
  tag,
  allTags,
  onTag,
  onSide,
  onOpenSetupGuide,
  onClearProtocol,
  canStart,
  startBlockedReason,
  saving,
  handsFree,
  adaptiveState,
  onToggleHandsFree,
  targetCoach,
  onToggleTargetCoach,
  onArm,
  onCancelArm,
  prepare,
  onTogglePrepare,
  protoTS,
  paused,
  onPause,
  onSkip,
  onStart,
  onStop,
  onMinimize,
  protocolQuality,
}: Props) {
  const measuring = tindeq.status === "measuring";
  const armed = tindeq.status === "armed";
  const handsFreeActive = handsFree && protocol?.protocolMode !== "reverse_action";
  const adaptive = handsFreeActive && protocol !== null;
  // Walk the timeline in protocol time (parent-owned; freezes while paused).
  const pos = timeline && measuring && !adaptive ? timelineAt(timeline, protoTS) : null;
  const done = adaptive ? adaptiveState?.phase === "complete" : timeline !== null && measuring && pos === null;
  const meta = pos ? PHASE_META[pos.seg.phase] : null;

  // Beep + haptic on segment transitions (AudioContext primed on the Start
  // tap so iOS allows playback).
  const audioRef = useRef<AudioContext | null>(null);
  const lastKeyRef = useRef<string | null>(null);
  function primeAudio() {
    try {
      if (!audioRef.current) audioRef.current = new AudioContext();
      void audioRef.current.resume().catch(() => {});
    } catch {
      // no audio
    }
  }
  const lastHandsFreeStatusRef = useRef<"idle" | "armed" | "measuring">("idle");
  useEffect(() => {
    const next = handsFreeActive ? (armed ? "armed" : measuring ? "measuring" : "idle") : "idle";
    const prev = lastHandsFreeStatusRef.current;
    if (next === prev) return;
    lastHandsFreeStatusRef.current = next;
    if (next === "idle") return;
    const ctx = audioRef.current;
    if (ctx) {
      try {
        const o = ctx.createOscillator();
        const g = ctx.createGain();
        o.connect(g);
        g.connect(ctx.destination);
        o.frequency.value = next === "armed" ? 440 : 990;
        g.gain.setValueAtTime(0.25, ctx.currentTime);
        o.start();
        o.stop(ctx.currentTime + 0.15);
      } catch {
        // no audio
      }
    }
    navigator.vibrate?.(next === "armed" ? 80 : 150);
  }, [armed, measuring, handsFreeActive]);
  useEffect(() => {
    if (!measuring || !timeline) {
      lastKeyRef.current = null;
      return;
    }
    const key = adaptive && adaptiveState
      ? `${adaptiveState.phase}-${"holdIndex" in adaptiveState ? adaptiveState.holdIndex : ""}-${adaptiveState.phase === "recovery" ? adaptiveState.failed : ""}`
      : done
        ? "done"
        : pos
          ? pos.seg.phase === "move"
            ? reverseActionCadenceKey(pos.seg)
            : `${pos.seg.phase}-${pos.seg.set}-${pos.seg.rep}-${pos.seg.side ?? ""}`
          : null;
    if (key === null || lastKeyRef.current === key) return;
    const isFirst = lastKeyRef.current === null;
    lastKeyRef.current = key;
    // Normal protocols do not re-cue their first visible segment. Reverse
    // Action does: the initial OUT command is an instruction, not ambient
    // phase state, and must be distinguishable from the following RETURN.
    if (isFirst && pos?.seg.phase !== "move") return;
    const ctx = audioRef.current;
    const phase = adaptive && adaptiveState
      ? adaptiveState.phase === "complete"
        ? "done"
        : adaptiveState.phase === "hold"
          ? "hold"
          : "rest"
      : done ? "done" : pos!.seg.phase;
    const failedTransition = adaptive && adaptiveState?.phase === "recovery" && adaptiveState.failed;
    const direction =
      pos?.seg.phase === "move" ? pos.seg.direction : null;
    if (ctx) {
      try {
        const freq =
          failedTransition
            ? 220
            : direction === "out"
            ? 880
            : direction === "return"
              ? 620
              : phase === "hold"
                ? 990
                : phase === "done"
                  ? 660
                  : 440;
        const beeps =
          phase === "done" ? 3 : failedTransition || phase === "switch" || direction === "return" ? 2 : 1;
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
    navigator.vibrate?.(
      failedTransition
        ? [120, 80, 120, 80, 120]
        : direction === "return"
        ? [70, 60, 70]
        : phase === "hold" || phase === "move"
          ? 150
          : [80, 60, 80],
    );
  }, [adaptive, adaptiveState, measuring, timeline, pos, done]);

  // Free-hold get-ready countdown (#312) — null while idle/measuring/guided.
  // `prepNow` is a ticked clock (never Date.now() in render, same pattern as
  // the workout timers' `now` state); `prepStartedMs` moves via the
  // Start/Cancel taps below, and is also reset to null by the fire effect
  // once the countdown completes (see below).
  const [prepStartedMs, setPrepStartedMs] = useState<number | null>(null);
  const [prepNow, setPrepNow] = useState(() => Date.now());
  const prepRemaining = prepRemainingS(prepStartedMs, prepNow);
  // Deliberately NOT `prepRemaining !== null && prepRemaining > 0` (that was
  // the pre-fix definition): on the exact tick `prepRemaining` clamps to 0,
  // that render happens BEFORE the fire effect below has run — so gating on
  // `prepRemaining > 0` flipped `counting` false a render early, reverting
  // the UI to idle (tag/side picker + checkbox + normal START button) for
  // one frame before flipping again to MEASURING (#312 tester finding).
  // Keying off `prepStartedMs` alone instead means `counting` only goes
  // false once the fire effect actually resets `prepStartedMs` (the same
  // effect pass that calls onStart), closing the gap.
  const counting = prepStartedMs !== null;

  useEffect(() => {
    if (prepStartedMs === null) return;
    const t = setInterval(() => setPrepNow(Date.now()), 200);
    return () => clearInterval(t);
  }, [prepStartedMs]);

  // Fire the hold-start cue + onStart exactly once when the countdown reaches
  // 0 — same beep/vibrate cue as a timeline hold transition above.
  useEffect(() => {
    if (prepStartedMs === null) return;
    if (prepRemaining === null || prepRemaining > 0) return;
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
    // Reset immediately after firing. This used to be missing, and the
    // component stays mounted across many consecutive free holds in one
    // connected session (it only unmounts on disconnect/minimize) — without
    // it, `prepStartedMs` stayed non-null forever after the first countdown,
    // so once that hold finished and `measuring` went back to false, the UI
    // fell through to the `counting` branch (stuck showing CANCEL, tag
    // picker/checkbox still hidden) instead of the normal idle state, and a
    // second free-hold countdown never gets a fresh `null` to start a new
    // 5-second run from (#312 regression found in review). Cancel already
    // does the same null-write above; this makes the natural-fire path reset
    // state the same way. No separate "already fired" guard is needed to
    // stop this same effect from re-firing before the reset lands: once
    // `prepRemaining` clamps to 0 it stays exactly 0 (see forcePrepare.ts),
    // so this effect's dependency array doesn't change again until a new
    // countdown writes a new `prepStartedMs`. Deferred via a microtask —
    // same "write state only inside an async callback" pattern as the curve
    // auto-compute effect in ForceView.tsx — because
    // react-hooks/set-state-in-effect flags a same-tick setState call here.
    queueMicrotask(() => setPrepStartedMs(null));
    // onStart is an owner callback read at fire time (mirrors
    // RoutineFullscreen's onFinish effect).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prepStartedMs, prepRemaining]);

  const bannerColor = adaptive && adaptiveState?.phase === "recovery"
    ? adaptiveState.failed ? "var(--danger)" : "var(--primary)"
    : adaptive && adaptiveState?.phase === "complete" && adaptiveState.failed
      ? "var(--danger)"
    : done
      ? "var(--warning)"
    : counting
      ? PHASE_META.prepare.color
      : armed
        ? "var(--warning)"
      : (meta?.color ?? (measuring ? "var(--success)" : "var(--primary)"));

  const adaptiveHolds = adaptive && timeline
    ? adaptiveStaticHolds(timeline as ProtocolSegment[])
    : [];
  const adaptiveHold = adaptiveState && adaptiveState.phase !== "complete"
    ? adaptiveHolds[adaptiveState.holdIndex]
    : null;
  const adaptiveSegment = adaptiveHold && timeline
    ? timeline[adaptiveHold.segmentIndex] as ProtocolSegment
    : null;
  const adaptiveRemainingS = adaptiveState?.phase === "hold" && adaptiveHold
    ? Math.max(
        0,
        (adaptiveState.startedMs + adaptiveHold.durationMs - adaptiveState.lastMs) / 1_000,
      )
    : adaptiveState?.phase === "recovery"
      ? Math.max(0, (adaptiveState.recoveryUntilMs - adaptiveState.lastMs) / 1_000)
      : null;

  // Side shown on a hold: the segment's own hand, else the global pick.
  const holdSide =
    adaptiveState?.phase === "hold" && adaptiveSegment
      ? (adaptiveSegment.side ??
        (globalSide === "left" || globalSide === "right" ? globalSide : null))
    : pos?.seg.phase === "hold" || pos?.seg.phase === "move"
      ? (pos.seg.side ??
        (globalSide === "left" || globalSide === "right" ? globalSide : null))
      : null;

  // Upcoming hand during a rest (alternating protocols): the next hold
  // segment's side. Every logical rep runs left then right, and the only idle
  // rest segments sit before the switch back to left.
  const nextHoldSide =
    pos && timeline
      ? (timeline.find(
          (s) => s.phase === "hold" && s.startS >= pos.seg.startS + pos.seg.durS,
        )?.side ?? null)
      : null;

  // #298: which hand an alternating protocol's side row highlights — the
  // current hold/switch segment's hand while measuring, the next hold's hand
  // during a rest, and the FIRST hold's hand before Start / after done
  // (nothing is "current" yet). Always the timeline's own pick, never a
  // stored preference.
  const autoSide =
    adaptiveSegment?.side ??
    pos?.seg.side ??
    nextHoldSide ??
    (timeline && protocol?.protocolMode !== "reverse_action"
      ? firstHoldSide(timeline as ProtocolSegment[])
      : null);

  // Tags only make sense to change before Start. The side row stays up
  // through an alternating run too (#298) — it's a live indicator there,
  // not a control — but a non-alternating run has nothing new to show once
  // measuring starts, so it keeps the original idle-only visibility.
  const showTagPicker = !measuring && !armed && !counting;
  const showSideRow = !armed && !counting && (!measuring || !!protocol?.alternateSides);

  // Per-set target band: a %-of-PR preset ramps up each set; the chart band
  // follows the CURRENT set live (set 1 while idle, last set once done).
  const currentSet = adaptiveSegment?.set ?? pos?.seg.set ?? (done ? (protocol?.sets ?? 1) : 1);
  const targetSegment =
    protocol?.protocolMode === "reverse_action"
      ? null
      : targetHoldSegment(
          timeline as ProtocolSegment[] | null,
          adaptiveSegment ?? pos?.seg as ProtocolSegment | null,
          done,
        );
  const protocolKg = protocol ? presetTargetKg(protocol, presetRefs, currentSet) : null;
  // #332: with a per-set hold list, a `targetCurve` preset resolves a
  // different kg per set (possibly non-monotonically), so a "set N: X kg"
  // snapshot understates the range every other set trains at — label with
  // the full min–max range instead. The drawn kg/lowKg/highKg band above
  // still tracks the CURRENT set (what to aim for right now); only the text
  // label changes to describe the whole protocol.
  const protocolKgRange = protocol?.targetCurve ? presetTargetKgRange(protocol, presetRefs) : null;
  const reverseBand =
    protocol?.protocolMode === "reverse_action"
      ? reverseActionTargetBand(
          protocolKg,
          protocol.toleranceMode ?? "percent",
          protocol.toleranceValue ?? 10,
        )
      : null;
  const handTarget = prescriptionForSegment(
    alternatingPrescription,
    targetSegment?.side,
    targetSegment?.set ?? currentSet,
  )?.target ?? null;
  const readyLeft = prescriptionForSegment(
    alternatingPrescription,
    "left",
    timeline?.find((s) => s.phase === "hold" && s.side === "left")?.set ?? 1,
  )?.target ?? null;
  const readyRight = prescriptionForSegment(
    alternatingPrescription,
    "right",
    timeline?.find((s) => s.phase === "hold" && s.side === "right")?.set ?? 1,
  )?.target ?? null;
  const resolvedAlternating =
    protocol?.alternateSides && alternatingPrescription
      ? Array.from({ length: protocol.sets }, (_, i) => {
          const set = i + 1;
          const left = prescriptionForSegment(alternatingPrescription, "left", set)?.target;
          const right = prescriptionForSegment(alternatingPrescription, "right", set)?.target;
          return {
            left: {
              holdS: left?.workS ?? holdForSet(protocol, set),
              targetKg: left?.kg ?? null,
            },
            right: {
              holdS: right?.workS ?? holdForSet(protocol, set),
              targetKg: right?.kg ?? null,
            },
          };
        })
      : undefined;
  const band: GaugeTarget | null =
    reverseBand && protocol
      ? {
          ...reverseBand,
          workS: prescriptionWorkS(protocol, currentSet),
          label: protocolBandLabel(protocol, reverseBand.kg, currentSet, protocolKgRange),
        }
    : handTarget ?? (protocol && protocolKg != null
      ? {
          kg: protocolKg,
          lowKg: protocolKg * 0.9,
          highKg: protocolKg * 1.1,
          workS: prescriptionWorkS(protocol, currentSet),
          label: protocolBandLabel(protocol, protocolKg, currentSet, protocolKgRange),
        }
      : target);

  // One shared coach for targeted free holds and guided hold segments. The
  // current per-set `band` above is deliberately the only target source.
  const coachBandValid =
    band !== null &&
    Number.isFinite(band.lowKg) &&
    Number.isFinite(band.highKg) &&
    band.lowKg < band.highKg;
  const coachingActive = targetZoneCoachActive({
    enabled: targetCoach,
    measuring,
    hasTarget: coachBandValid,
    guided: protocol !== null,
    guidedPhase: adaptive ? (adaptiveState?.phase === "hold" ? "hold" : "rest") : pos?.seg.phase ?? null,
    paused,
  });
  const currentKg = tindeq.current;
  const sampleTimestampMs = tindeq.elapsedMs;
  const targetLowKg = band?.lowKg ?? null;
  const targetHighKg = band?.highKg ?? null;
  const coachMachineRef = useRef(idleTargetZoneCoach());
  const [coachDisplay, setCoachDisplay] = useState<CoachDisplay>(IDLE_COACH_DISPLAY);
  const coachDisplayRef = useRef<CoachDisplay>(IDLE_COACH_DISPLAY);
  useEffect(() => {
    const stepped = stepTargetZoneCoach(coachMachineRef.current, {
      currentKg,
      targetLowKg,
      targetHighKg,
      timestampMs: sampleTimestampMs,
      active: coachingActive,
    });
    // Claim the transition before audio or the deferred React-state publish.
    coachMachineRef.current = stepped.state;

    const nextDisplay: CoachDisplay =
      coachingActive && targetLowKg !== null && targetHighKg !== null
      ? { active: true, zone: stepped.state.zone, lowKg: targetLowKg, highKg: targetHighKg }
      : IDLE_COACH_DISPLAY;
    const priorDisplay = coachDisplayRef.current;
    if (
      priorDisplay.active !== nextDisplay.active ||
      priorDisplay.zone !== nextDisplay.zone ||
      priorDisplay.lowKg !== nextDisplay.lowKg ||
      priorDisplay.highKg !== nextDisplay.highKg
    ) {
      coachDisplayRef.current = nextDisplay;
      const claimedState = stepped.state;
      queueMicrotask(() => {
        // This callback is asynchronous: only publish the snapshot if the refs
        // still identify the transition claimed above (#295 stale-closure rule).
        if (
          coachMachineRef.current !== claimedState ||
          coachDisplayRef.current !== nextDisplay
        ) return;
        setCoachDisplay(nextDisplay);
      });
    }

    if (stepped.cue) {
      playTargetZoneCue(audioRef.current, stepped.cue);
      navigator.vibrate?.(
        stepped.cue === "in-zone" ? 45 : stepped.cue === "below" ? [35, 45, 70] : [70, 45, 35],
      );
    }
  }, [
    coachingActive,
    currentKg,
    sampleTimestampMs,
    targetHighKg,
    targetLowKg,
  ]);

  const coachedZone =
    coachDisplay.active &&
    coachDisplay.lowKg === band?.lowKg &&
    coachDisplay.highKg === band?.highKg
      ? coachDisplay.zone
      : "unknown";
  const reverseWorking =
    measuring && protocol?.protocolMode === "reverse_action" && band !== null;
  const displayedCoachZone = reverseWorking && band
    ? targetZoneAtForce(tindeq.current, band.lowKg, band.highKg)
    : coachedZone;
  const coachPresentation = COACH_PRESENTATION[displayedCoachZone];
  const reverseSegment =
    reverseWorking && pos ? (pos.seg as ReverseActionSegment) : null;

  return createPortal(
    <div
      className="fullscreen-overlay"
      style={{
        // The whole screen takes the phase color, Timer-Plus style.
        background: `color-mix(in srgb, ${bannerColor} ${pos || done || counting || armed ? 13 : 6}%, var(--canvas))`,
        transition: "background 0.3s",
        display: "flex",
        justifyContent: "center",
        overflowY: reverseWorking ? "hidden" : "auto",
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
                  : armed
                    ? "var(--warning)"
                  : "var(--info)",
              animation:
                measuring && !paused ? "pulse 1.6s ease-in-out infinite" : undefined,
            }}
          />
          <span style={{ fontSize: "var(--t-sm)", color: "var(--ink)", flex: 1 }}>
            Progressor{" "}
            <span style={{ color: "var(--ink-muted)" }}>
              · {paused ? "paused" : measuring ? "measuring" : armed ? "armed" : "connected"}
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
          {!measuring && !armed && !counting && tindeq.capabilities.tare && (
            <button
              onClick={() => void tindeq.tare()}
              className="glass-pill"
              style={{ padding: "7px 13px", fontSize: "var(--t-2xs)" }}
            >
              Tare
            </button>
          )}
          {!measuring && !armed && !counting && (
            <button
              onClick={onOpenSetupGuide}
              className="glass-pill"
              style={{ padding: "7px 13px", fontSize: "var(--t-2xs)" }}
            >
              How to set up
            </button>
          )}
          <button
            onClick={tindeq.disconnect}
            className="glass-pill"
            style={{ padding: "7px 13px", fontSize: "var(--t-2xs)", "--pill-tint": "var(--danger)" } as CSSProperties}
          >
            Disconnect
          </button>
        </div>

        {reverseWorking && band && protocol && (
          <>
          <div style={{ display: "flex", alignItems: "center", gap: 7, flexWrap: "wrap", flexShrink: 0 }}>
            <span style={{ fontWeight: 850, fontSize: "var(--t-base)", overflowWrap: "anywhere" }}>{protocol.name}</span>
            <ProtocolBadge mode="reverse_action" quality={protocolQuality} />
          </div>
          <ReverseActionWorkDisplay
            currentKg={tindeq.current}
            targetKg={band.kg}
            lowKg={band.lowKg}
            highKg={band.highKg}
            zone={displayedCoachZone}
            segment={reverseSegment}
            remainingS={pos?.remaining ?? null}
            done={done}
            reps={protocol.reps}
            sets={protocol.sets}
            side={globalSide}
          /></>
        )}

        {!reverseWorking && coachingActive && band && (
          <div
            role="meter"
            aria-label="Force target zone"
            aria-valuemin={0}
            aria-valuemax={Math.max(1, band.highKg * 1.5, tindeq.current)}
            aria-valuenow={Math.max(0, tindeq.current)}
            aria-valuetext={`${coachPresentation.label}; target ${band.lowKg.toFixed(1)} to ${band.highKg.toFixed(1)} kilograms`}
            style={{
              borderRadius: 16,
              padding: "10px 14px",
              flexShrink: 0,
              textAlign: "center",
              background: `color-mix(in srgb, ${coachPresentation.color} 18%, var(--surface-1))`,
              border: `2px solid color-mix(in srgb, ${coachPresentation.color} 65%, transparent)`,
              transition: "background 0.2s, border-color 0.2s",
            }}
          >
            <div
              aria-live="polite"
              style={{
                color: coachPresentation.color,
                fontFamily: "Inter, sans-serif",
                fontWeight: 850,
                fontSize: "clamp(1.65rem, 8vw, 2.4rem)",
                letterSpacing: "0.08em",
                lineHeight: 1,
              }}
            >
              <span aria-hidden="true">{coachPresentation.symbol} </span>
              {coachPresentation.label}
            </div>
            <div
              style={{
                color: "var(--ink)",
                fontSize: "var(--t-sm)",
                fontWeight: 750,
                marginTop: 5,
                fontVariantNumeric: "tabular-nums",
              }}
            >
              TARGET {band.lowKg.toFixed(1)}–{band.highKg.toFixed(1)} kg
            </div>
          </div>
        )}

        {/* Colorful phase banner (Timer-Plus style) */}
        {!reverseWorking && <div
          style={{
            borderRadius: 18,
            padding: `${clampCss(BANNER_PAD_Y)} 16px`,
            background: `color-mix(in srgb, ${bannerColor} ${pos || done || counting || armed ? 22 : 12}%, var(--surface-1))`,
            border: `1px solid color-mix(in srgb, ${bannerColor} 50%, transparent)`,
            textAlign: "center",
            transition: "background 0.25s, border-color 0.25s",
            flexShrink: 0,
          }}
        >
          {adaptive && adaptiveState && protocol ? (
            <>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.12em", fontSize: "var(--t-lg)", color: bannerColor }}>
                {adaptiveState.phase === "armed"
                  ? "PULL TO START"
                  : adaptiveState.phase === "hold"
                    ? `HOLD${holdSide ? ` · ${holdSide.toUpperCase()}` : ""}`
                    : adaptiveState.phase === "complete"
                      ? adaptiveState.failed ? "FAILED · DONE" : "DONE"
                      : adaptiveState.lastMs >= adaptiveState.recoveryUntilMs
                        ? "WAITING FOR PULL"
                        : adaptiveState.failed ? "FAILED · REST" : "REST · UNLOAD"}
              </div>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, fontVariantNumeric: "tabular-nums", fontSize: heroFontCss(adaptiveRemainingS === null ? FORCE_HERO_SM_FONT : FORCE_TIMER_FONT), lineHeight: 1 }}>
                {adaptiveRemainingS === null ? (
                  <>{adaptiveState.phase === "complete" ? "✓" : tindeq.current.toFixed(1)}{adaptiveState.phase === "armed" && <span style={{ fontSize: "var(--t-xl)", color: "var(--ink-muted)" }}> kg</span>}</>
                ) : adaptiveState.phase === "recovery" && adaptiveRemainingS <= 0 ? (
                  "READY"
                ) : (
                  fmt(adaptiveRemainingS)
                )}
              </div>
              <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)", marginTop: 4 }}>
                {adaptiveState.phase === "complete"
                  ? "protocol complete"
                  : adaptiveSegment
                    ? `${adaptiveState.phase === "recovery" ? "next · " : ""}rep ${adaptiveSegment.rep}/${protocol.reps} · set ${adaptiveSegment.set}/${protocol.sets}${adaptiveSegment.side ? ` · ${adaptiveSegment.side.toUpperCase()}` : ""}`
                    : "load steadily to begin"}
              </div>
            </>
          ) : done && protocol ? (
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
                {pos.seg.phase === "move"
                  ? pos.seg.direction === "out"
                    ? "OUT"
                    : "RETURN"
                  : meta.label}
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
          ) : armed ? (
            <>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.12em", fontSize: "var(--t-lg)", color: bannerColor }}>
                ARMED
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
                {tindeq.current.toFixed(1)}
                <span style={{ fontSize: "var(--t-xl)", color: "var(--ink-muted)" }}> kg</span>
              </div>
              <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)", marginTop: 4 }}>
                Load to at least {DEFAULT_HANDS_FREE_FORCE_CONFIG.startKg.toFixed(1)} kg and hold steady
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
              {handsFreeActive && (
                <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginTop: 4 }}>
                  Release to {DEFAULT_HANDS_FREE_FORCE_CONFIG.stopKg.toFixed(1)} kg or less for {(DEFAULT_HANDS_FREE_FORCE_CONFIG.stopGraceMs / 1_000).toFixed(1)}s to save
                </div>
              )}
            </>
          ) : (
            <>
              <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, letterSpacing: "0.12em", fontSize: "var(--t-lg)", color: bannerColor }}>
                READY
              </div>
              <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginTop: 6, lineHeight: 1.5 }}>
                {protocol && timeline ? (
                  <>
                    <span style={{ color: "var(--ink)", fontWeight: 700, overflowWrap: "anywhere" }}>{protocol.name}</span>{" "}
                    <ProtocolBadge mode={protocol.protocolMode ?? "hold"} quality={protocolQuality} />{" "}
                    {protocol.protocolMode === "reverse_action" ? (
                      <>
                        · {protocol.cadenceOutS ?? 3}s OUT / {protocol.cadenceReturnS ?? 3}s RETURN · {protocol.reps} rep{protocol.reps === 1 ? "" : "s"} × {protocol.sets} set{protocol.sets === 1 ? "" : "s"} · ~
                        {Math.round(timelineDurationS(timeline) / 60)}min
                        <br />one continuous raw trace saves per set
                      </>
                    ) : (
                      <>
                        · {readyLeft && readyRight
                          ? `L ${fmt(readyLeft.workS)} / R ${fmt(readyRight.workS)}`
                          : holdsSummary(protocol)} × {protocol.reps} × {protocol.sets}
                        {protocol.alternateSides && " · L⇄R"} · ~
                        {Math.round(timelineDurationS(timeline) / 60)}min
                        <br />
                        {readyLeft && readyRight && (
                          <>
                            L {readyLeft.kg.toFixed(1)} kg · R {readyRight.kg.toFixed(1)} kg
                            <br />
                          </>
                        )}
                        each rep saves as its own recording
                      </>
                    )}
                  </>
                ) : band ? (
                  <>
                    Target: <span style={{ color: "var(--success)" }}>{band.label}</span>
                  </>
                ) : (
                  "Free hold — pick a zone or preset in the tab for a guided timer."
                )}
              </div>
              {protocol && timeline && protocol.protocolMode !== "reverse_action" && (
                <PresetPlanChart
                  preset={protocol}
                  refs={presetRefs}
                  resolvedAlternating={resolvedAlternating}
                />
              )}
              {/* #298: explicit unarm, in addition to re-tapping the same
                  chip in the tab — the fastest way out of a protocol from
                  right where it's shown. */}
              {protocol && (
                <button
                  onClick={onClearProtocol}
                  className="glass-pill"
                  style={{ marginTop: 10, padding: "7px 16px", fontSize: "var(--t-2xs)" }}
                >
                  Clear — free hold
                </button>
              )}
            </>
          )}
        </div>}

        {/* Quick exercise + side pickers — arm a free hold without leaving
            the gauge (brand-new tags are typed in the tab). Box chips, no
            dropdowns (SL-82); a freshly typed tag with no recordings yet is
            included so the armed tag shows (SL-81). Tags only make sense to
            change before Start; the side row (below) stays up through an
            alternating run too, as a live indicator. */}
        {(showTagPicker || showSideRow) && (
          <div style={{ display: "flex", flexDirection: "column", gap: 6, flexShrink: 0 }}>
            {showTagPicker && (
              // A user with many tags used to wrap this strip to four or five
              // rows and shove START off the bottom (#221). Cap it at roughly
              // two rows and let the strip scroll instead of the overlay.
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
            )}
            {showSideRow && (
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
                    // #298: this pick is a CURVE REFERENCE (it feeds
                    // ForceView's chartSide → zoneTag → the armed target,
                    // and filters which recordings fit the curve) as much
                    // as a display label. An alternating protocol trains
                    // BOTH hands, so ForceView derives that reference
                    // side-less for it already — this row can't offer a
                    // single-hand pick without contradicting that, so while
                    // one is armed it's auto-driven off the timeline's own
                    // hand and locked, rather than removed (removing it
                    // left an alternating run with no visible side at all).
                    active={protocol?.alternateSides ? v === autoSide : globalSide === v}
                    onClick={protocol?.alternateSides ? () => {} : () => onSide(v as TindeqSide)}
                    disabled={!!protocol?.alternateSides}
                    style={{ flex: 1 }}
                  />
                ))}
              </div>
            )}
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
            live={measuring || armed}
            target={band}
            fill
          />
        </div>

        {/* Big circular action (like the workout timer) */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8, flexShrink: 0 }}>
          {/* Pause / Skip — guided runs only. Both finalize the current rep in
              the parent before touching the protocol clock. */}
          {measuring && timeline && !done && protocol?.protocolMode !== "reverse_action" && !adaptive && (
            <div style={{ display: "flex", gap: 10, marginBottom: 2 }}>
              <button
                onClick={() => {
                  primeAudio();
                  onPause();
                }}
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
            aria-label={measuring && protocol?.protocolMode === "reverse_action" ? "Emergency stop and save partial Reverse Action set" : undefined}
            onClick={() => {
              if (measuring) {
                onStop();
                return;
              }
              if (armed) {
                onCancelArm();
                return;
              }
              if (counting) {
                // Cancel — nothing is measuring yet, so this must never
                // call onStop (#312).
                setPrepStartedMs(null);
                return;
              }
              primeAudio();
              if (handsFreeActive) {
                onArm();
                return;
              }
              if (!adaptive && startsWithCountdown(protocol, prepare)) {
                setPrepStartedMs(Date.now());
              } else {
                onStart();
              }
            }}
            disabled={measuring ? saving : armed ? false : counting ? false : !canStart}
            style={{
              width: clampCss(FORCE_ACTION_CIRCLE),
              height: clampCss(FORCE_ACTION_CIRCLE),
              flexShrink: 0,
              borderRadius: "50%",
              border: `3px solid ${measuring || armed || counting ? "var(--danger)" : "var(--success)"}`,
              background: `color-mix(in srgb, ${measuring || armed || counting ? "var(--danger)" : "var(--success)"} 16%, transparent)`,
              color: measuring || armed || counting ? "var(--danger)" : "var(--success)",
              cursor: "pointer",
              fontFamily: "Inter, sans-serif",
              fontWeight: 800,
              fontSize: "var(--t-md)",
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
              gap: 3,
              opacity: (measuring ? saving : armed ? false : counting ? false : !canStart) ? 0.45 : 1,
            }}
          >
            {measuring ? (
              <>
                <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
                {saving ? "SAVING…" : protocol?.protocolMode === "reverse_action" ? "STOP NOW" : "STOP"}
              </>
            ) : armed || counting ? (
              <>
                <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
                CANCEL
              </>
            ) : (
              <>
                <svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z" /></svg>
                {handsFreeActive ? "ARM" : "START"}
              </>
            )}
          </button>
          {!measuring && !armed && !counting && protocol?.protocolMode !== "reverse_action" && (
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
                checked={handsFree}
                onChange={(e) => onToggleHandsFree(e.target.checked)}
              />
              {protocol
                ? "Hands-free — pull to start each rep"
                : "Hands-free — load to start, release to save"}
            </label>
          )}
          {!measuring && !armed && !counting && coachBandValid && (
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
                checked={targetCoach}
                onChange={(e) => {
                  if (e.target.checked) primeAudio();
                  onToggleTargetCoach(e.target.checked);
                }}
              />
              Audio coach — cues below, in zone, and above
            </label>
          )}
          {!measuring && !armed && !counting && !handsFreeActive && protocol?.protocolMode !== "reverse_action" && (
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
          {!canStart && !measuring && !armed && !counting && (
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", textAlign: "center" }}>
              {startBlockedReason
                ? startBlockedReason
                : allTags.length
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
