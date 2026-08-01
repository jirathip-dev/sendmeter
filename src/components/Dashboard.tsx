import { useMemo, useState } from "react";
import type {
  AcwrData,
  AcwrStatus,
  HealthMetric,
  Phase,
  Session,
  WeeklyLoad,
} from "../types";
import AcwrProjectionCard from "./AcwrProjectionCard";
import ChartTooltip from "./ChartTooltip";
import ContributionHeatmap from "./ContributionHeatmap";
import InfoDot from "./InfoDot";
import ReadinessCard from "./ReadinessCard";
import RecoverySheet from "./RecoverySheet";
import SendConditionsCard from "./SendConditionsCard";
import ForceConsistencyCard from "./ForceConsistencyCard";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useChartHover } from "../hooks/useChartHover";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { daysAgo } from "../lib/dates";
import { ACWR_TRACK_GRADIENT, phaseAcwrFit, suggestPhaseStepBack } from "../lib/metrics";
import { fetchHealthMetrics } from "../lib/repo";

// A dismissal is keyed to the streak's oldest day (not just "true/false"), so
// declining the nudge sticks for the rest of THIS low streak but reappears
// on a fresh one — e.g. readiness recovers, phase stays in power, then slides
// low again later. Persisted (SL-23), like the app's other one-shot prompts.
const STEP_BACK_DISMISS_KEY = "sendmeter:phase-step-back-dismissed";

// Sign convention/formatting for a week-over-week AU delta, shared by the
// "Weekly load" header badge and the per-bar tooltip.
function weekDelta(cur: number, prev: number): { pct: number; arrow: string; color: string } | null {
  if (prev <= 0) return null;
  const pct = ((cur - prev) / prev) * 100;
  return {
    pct,
    arrow: pct > 0 ? "▲" : pct < 0 ? "▼" : "",
    color: Math.abs(pct) < 1 ? "var(--ink-muted)" : pct > 0 ? "var(--success)" : "var(--danger)",
  };
}

interface Props {
  phase: Phase;
  phaseDays: number;
  todayLabel: string;
  acwrData: AcwrData;
  weeklyLoads: WeeklyLoad[];
  status: AcwrStatus;
  sessions: Session[];
  onOpenPhases: () => void;
  onChangePhase: () => void;
}

/// Home: phase banner + ACWR with the full training-load detail inline
/// (acute/chronic, weekly totals, daily heatmap — formerly the LoadSheet
/// drill-in) + readiness. Sessions live in History; logging lives in Workout.
export default function Dashboard({
  phase,
  phaseDays,
  todayLabel,
  acwrData,
  weeklyLoads,
  status,
  sessions,
  onOpenPhases,
  onChangePhase,
}: Props) {
  const [showRecovery, setShowRecovery] = useState(false);
  const [hoveredWeek, hoverWeekProps] = useChartHover<number>();

  // Recovery-adjusted phase suggestion (SL-23): reuses the same 14-day
  // readiness fetch shape ReadinessCard uses (its own instance — components
  // here each fetch independently, same pattern as RecoveryStatsCard).
  const realtimeVersion = useRealtimeVersion();
  const readinessHistory = useCancellableFetch<HealthMetric[]>(
    () => fetchHealthMetrics(14),
    [],
    realtimeVersion,
  );
  const stepBack = suggestPhaseStepBack(readinessHistory, phase.id);
  const [dismissedStreakStart, setDismissedStreakStart] = useState<string | null>(() =>
    typeof localStorage !== "undefined" ? localStorage.getItem(STEP_BACK_DISMISS_KEY) : null,
  );
  // The streak's oldest day, in absolute date terms — stable while the streak
  // continues (even as streakDays grows day over day), so it doubles as the
  // dismissal's identity key.
  const streakStart = stepBack.suggested ? daysAgo(stepBack.streakDays - 1) : null;
  const showStepBack = streakStart !== null && streakStart !== dismissedStreakStart;
  function dismissStepBack() {
    if (streakStart === null) return;
    localStorage.setItem(STEP_BACK_DISMISS_KEY, streakStart);
    setDismissedStreakStart(streakStart);
  }

  const maxW = Math.max(...weeklyLoads.map((w) => w.total), 1);
  // Week-over-week delta: the windows are rolling 7-day sums, so "Now" vs
  // "1w" is a fair full-window comparison. No baseline (prev 0) hides it.
  const curWeek = weeklyLoads[weeklyLoads.length - 1]?.total ?? 0;
  const prevWeek = weeklyLoads[weeklyLoads.length - 2]?.total ?? 0;
  const curWeekDelta = weekDelta(curWeek, prevWeek);
  // Per-day total load AND the day's dominant activity type (most load) — the
  // heatmap hues each cell by type (SL-60).
  const daily = useMemo(() => {
    const acc = new Map<string, { total: number; byType: Map<string, number> }>();
    for (const s of sessions) {
      let e = acc.get(s.date);
      if (!e) {
        e = { total: 0, byType: new Map() };
        acc.set(s.date, e);
      }
      e.total += s.load;
      e.byType.set(s.type, (e.byType.get(s.type) ?? 0) + s.load);
    }
    const out = new Map<string, { total: number; type: string }>();
    for (const [date, e] of acc) {
      let type = "";
      let best = -1;
      for (const [t, load] of e.byType) {
        if (load > best) {
          best = load;
          type = t;
        }
      }
      out.set(date, { total: e.total, type });
    }
    return out;
  }, [sessions]);

  return (
    <div>
      {/* Phase strip (SL-60, 2/3) + send conditions (SL-69, 1/3), side by side.
          Both are slim/neutral context; the phase name carries the color. */}
      <div style={{ display: "flex", gap: 10, marginBottom: 10, alignItems: "stretch" }}>
        <div
          className="phase-banner"
          title="Phase details"
          // #171: tappable strip, not a button — opt into the delegated tick.
          data-haptic="light"
          onClick={onOpenPhases}
          style={{
            flex: 2,
            minWidth: 0,
            margin: 0,
            padding: "10px 14px",
            cursor: "pointer",
            display: "flex",
            flexDirection: "column",
            justifyContent: "space-between",
            gap: 6,
            // Tinted with the current phase's color, matching the phase cards
            // in the info sheet.
            background: phase.bg,
            border: `1px solid ${phase.border}`,
          }}
        >
          <div style={{ minWidth: 0 }}>
            <div
              style={{
                fontSize: "var(--t-eyebrow)",
                color: "var(--ink-muted)",
                textTransform: "uppercase",
                letterSpacing: "0.1em",
              }}
            >
              Phase · Day {phaseDays} · {todayLabel}
            </div>
            <div
              style={{
                fontSize: "var(--t-md)",
                fontWeight: 700,
                color: phase.color,
                letterSpacing: "-0.01em",
                marginTop: 2,
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              }}
            >
              {phase.name}
            </div>
          </div>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              gap: 8,
            }}
          >
            <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", whiteSpace: "nowrap" }}>
              Target{" "}
              <span style={{ color: "var(--ink)", fontWeight: 700 }}>{phase.acwr}</span>
            </span>
            {/* The actual phase switcher — the strip/sheet are reference only. */}
            <button
              onClick={(e) => {
                e.stopPropagation();
                onChangePhase();
              }}
              style={{
                flexShrink: 0,
                background: "var(--surface-1)",
                border: "1px solid var(--border)",
                borderRadius: 8,
                padding: "5px 9px",
                fontFamily: "Inter, sans-serif",
                fontSize: "var(--t-2xs)",
                fontWeight: 600,
                color: "var(--ink-muted)",
                cursor: "pointer",
              }}
            >
              Change
            </button>
          </div>
        </div>

        <SendConditionsCard />
      </div>

      {/* Recovery-adjusted phase suggestion (SL-23) — soft, dismissible;
          tinted with the current phase's colors so it reads as attached to
          the banner above rather than a new alert. */}
      {showStepBack && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            marginBottom: 10,
            padding: "9px 12px",
            borderRadius: 12,
            background: phase.bg,
            border: `1px solid ${phase.border}`,
          }}
        >
          <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.4, flex: 1 }}>
            Readiness has been low for {stepBack.streakDays} days — consider
            stepping back to Capacity.
          </span>
          <InfoDot topic="phaseStepBack" />
          <button
            onClick={onChangePhase}
            style={{
              flexShrink: 0,
              background: "var(--surface-1)",
              border: "1px solid var(--border)",
              borderRadius: 8,
              padding: "5px 9px",
              fontFamily: "Inter, sans-serif",
              fontSize: "var(--t-2xs)",
              fontWeight: 600,
              color: phase.color,
              cursor: "pointer",
              whiteSpace: "nowrap",
            }}
          >
            Step back
          </button>
          <button
            aria-label="Dismiss suggestion"
            onClick={dismissStepBack}
            style={{
              flexShrink: 0,
              width: 22,
              height: 22,
              borderRadius: "50%",
              border: "1px solid transparent",
              background: "transparent",
              color: "var(--ink-faint)",
              fontSize: "var(--t-sm)",
              lineHeight: 1,
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              padding: 0,
            }}
          >
            ×
          </button>
        </div>
      )}

      <div
        style={{
          display: "flex",
          flexDirection: "column",
          gap: 10,
        }}
      >
        {/* Readiness is the hero (SL-60): the day's actionable number leads. */}
        <ReadinessCard onClick={() => setShowRecovery(true)} />

        {/* ACWR — the load detail now lives right below, no drill-in */}
        <div className="card">
          <div
            className="card-title"
            style={{
              marginBottom: 8,
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
            }}
          >
            <span>ACWR</span>
            <InfoDot topic="acwr" />
          </div>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 38,
              fontWeight: 800,
              color: status.color,
              letterSpacing: "-0.04em",
              lineHeight: 1,
            }}
          >
            {acwrData.acwr !== null ? acwrData.acwr.toFixed(2) : "—"}
          </div>
          <div style={{ fontSize: "var(--t-xs)", color: status.color, marginTop: 4 }}>
            {status.label}
          </div>
          {(() => {
            const fit = phaseAcwrFit(acwrData.acwr, phase);
            if (!fit) return null;
            const text =
              fit === "on"
                ? `On target for ${phase.name}`
                : `${fit === "below" ? "Below" : "Above"} ${phase.name} target (${phase.acwr})`;
            return (
              <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 2 }}>
                {text}
              </div>
            );
          })()}
          <div className="acwr-track">
            <div
              style={{
                position: "absolute",
                left: 0,
                top: 0,
                width: "100%",
                height: "100%",
                // See ACWR_TRACK_GRADIENT (src/lib/metrics.ts) for the band-edge
                // derivation and the #189/#213 history behind it.
                background: ACWR_TRACK_GRADIENT,
                opacity: 0.55,
                borderRadius: 3,
              }}
            />
            {acwrData.acwr !== null && (
              <div
                style={{
                  position: "absolute",
                  top: "50%",
                  left: `${Math.min(Math.max((acwrData.acwr / 2) * 100, 0), 100)}%`,
                  transform: "translate(-50%,-50%)",
                  width: 12,
                  height: 12,
                  borderRadius: "50%",
                  background: status.color,
                  border: "2px solid var(--canvas)",
                  zIndex: 1,
                }}
              />
            )}
          </div>
          <div
            style={{
              position: "relative",
              height: "1.4em",
              fontSize: "var(--t-eyebrow)",
              color: "var(--ink-faint)",
            }}
          >
            {/* Absolutely positioned at each tick's true fraction of the
                0-2 scale (issue #189) — `justify-content: space-between`
                spaced these evenly regardless of value, so "1.5" sat at
                ~66% while the marker it was meant to label rendered at 75%.
                0/50/75/100% below is exactly 0/1.0/1.5/2 ÷ 2 × 100. */}
            <span style={{ position: "absolute", left: "0%", transform: "translateX(0%)" }}>0</span>
            <span style={{ position: "absolute", left: "50%", transform: "translateX(-50%)" }}>1.0</span>
            <span style={{ position: "absolute", left: "75%", transform: "translateX(-50%)" }}>1.5</span>
            <span style={{ position: "absolute", left: "100%", transform: "translateX(-100%)" }}>2</span>
          </div>

          {/* Acute / chronic (formerly the LoadSheet drill-in) */}
          <div
            style={{
              display: "flex",
              gap: 24,
              marginTop: 12,
              paddingTop: 10,
              borderTop: "1px solid var(--hairline)",
              fontSize: "var(--t-sm)",
            }}
          >
            <span>
              <span style={{ color: "var(--ink-muted)" }}>Acute 7d </span>
              <span style={{ color: "var(--ink)", fontWeight: 600 }}>
                {acwrData.acute.toFixed(0)}
              </span>
            </span>
            <span>
              <span style={{ color: "var(--ink-muted)" }}>Chronic avg </span>
              <span style={{ color: "var(--ink)", fontWeight: 600 }}>
                {acwrData.chronic.toFixed(0)}
              </span>
            </span>
          </div>
        </div>

        {/* Where that ratio goes with no training (#224) — sits directly
            under the ACWR it extends, and reuses this component's readiness
            fetch rather than opening a third one. */}
        <AcwrProjectionCard
          phase={phase}
          sessions={sessions}
          latestReadiness={readinessHistory[readinessHistory.length - 1] ?? null}
        />

        {/* Weekly totals */}
        <div className="card">
          <div
            className="card-title"
            style={{
              marginBottom: 12,
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
            }}
          >
            <span>Weekly load</span>
            {curWeekDelta !== null && (
              <span
                style={{
                  fontSize: "var(--t-2xs)",
                  fontVariantNumeric: "tabular-nums",
                  color: curWeekDelta.color,
                }}
              >
                {curWeekDelta.arrow} {Math.abs(curWeekDelta.pct).toFixed(0)}% vs prior wk
              </span>
            )}
          </div>
          <div
            className="chart-scrub"
            style={{ display: "flex", gap: 8, alignItems: "flex-end", height: 88 }}
          >
            {weeklyLoads.map((w, i) => {
              const delta = i > 0 ? weekDelta(w.total, weeklyLoads[i - 1]!.total) : null;
              return (
                <div
                  key={i}
                  style={{
                    flex: 1,
                    position: "relative",
                    display: "flex",
                    flexDirection: "column",
                    alignItems: "center",
                    gap: 4,
                    height: "100%",
                    justifyContent: "flex-end",
                  }}
                  {...hoverWeekProps(i)}
                >
                  {hoveredWeek === i && (
                    <ChartTooltip
                      align={i < 2 ? "start" : i > weeklyLoads.length - 3 ? "end" : "center"}
                    >
                      <div style={{ fontWeight: 600 }}>{w.label}</div>
                      <div style={{ color: "var(--ink-muted)" }}>{w.total.toLocaleString()} AU</div>
                      {delta !== null && (
                        <div style={{ color: delta.color }}>
                          {delta.arrow} {Math.abs(delta.pct).toFixed(0)}% vs prior wk
                        </div>
                      )}
                    </ChartTooltip>
                  )}
                  <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>
                    {w.total.toLocaleString()}
                  </span>
                  <div
                    style={{
                      width: "100%",
                      height: Math.max((w.total / maxW) * 64, 2),
                      background: i === weeklyLoads.length - 1 ? "var(--success)" : "var(--border)",
                      borderRadius: 3,
                      opacity: hoveredWeek === null || hoveredWeek === i ? 1 : 0.5,
                      boxShadow: hoveredWeek === i ? "0 0 0 1.5px var(--ink)" : "none",
                      cursor: "pointer",
                      transition: "opacity 0.1s",
                    }}
                  />
                  <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)" }}>{w.label}</span>
                </div>
              );
            })}
          </div>
        </div>

        {/* Daily AU heatmap */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 12 }}>Daily load</div>
          <ContributionHeatmap values={daily} />
        </div>

        {/* Weekly Tindeq-training consistency (#311) — self-fetching, no
            props needed from here. */}
        <ForceConsistencyCard />
      </div>

      {showRecovery && <RecoverySheet onClose={() => setShowRecovery(false)} />}
    </div>
  );
}
