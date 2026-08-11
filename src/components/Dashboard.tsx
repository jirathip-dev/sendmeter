import { useState, type CSSProperties } from "react";
import type {
  AcwrData,
  AcwrStatus,
  HealthMetric,
  Phase,
  Session,
  WeeklyLoad,
} from "../types";
import AcwrProjectionCard from "./AcwrProjectionCard";
import InfoDot from "./InfoDot";
import ReadinessCard from "./ReadinessCard";
import RecoverySheet from "./RecoverySheet";
import SendConditionsCard from "./SendConditionsCard";
import ForceConsistencyCard from "./ForceConsistencyCard";
import TrainingLoadSheet from "./TrainingLoadSheet";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { daysAgo } from "../lib/dates";
import { ACWR_TRACK_GRADIENT, phaseAcwrFit, suggestPhaseStepBack } from "../lib/metrics";
import { fetchHealthMetrics } from "../lib/repo";

// A dismissal is keyed to the streak's oldest day (not just "true/false"), so
// declining the nudge sticks for the rest of THIS low streak but reappears
// on a fresh one — e.g. readiness recovers, phase stays in power, then slides
// low again later. Persisted (SL-23), like the app's other one-shot prompts.
const STEP_BACK_DISMISS_KEY = "sendmeter:phase-step-back-dismissed";

interface Props {
  phase: Phase;
  phaseDays: number | null;
  todayLabel: string;
  acwrData: AcwrData;
  weeklyLoads: WeeklyLoad[];
  status: AcwrStatus;
  sessions: Session[];
  onOpenPhases: () => void;
  onChangePhase: () => void;
}

/// Home: phase banner, readiness and ACWR summary. Detailed load views open
/// from the ACWR card so the dashboard stays focused on today's status.
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
  const [showTrainingLoad, setShowTrainingLoad] = useState(false);

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

  return (
    <div>
      {/* Phase strip (SL-60, 2/3) + send conditions (SL-69, 1/3), side by side.
          Both are slim/neutral context; the phase name carries the color. */}
      <div style={{ display: "flex", gap: 10, marginBottom: 10, alignItems: "stretch" }}>
        <div
          className="phase-banner surface-context"
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
            // Restrained phase-color wash (#547) — see .phase-banner in
            // index.css for the theme-tuned tint recipe this drives.
            "--phase-accent": phase.color,
          } as CSSProperties}
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
              Phase · Day {phaseDays ?? "—"} · {todayLabel}
            </div>
            <div
              className="phase-banner-name"
              style={{
                maxWidth: "100%",
                color: phase.textColor,
                // #557 round 2: the banner's own tint (--phase-accent at
                // --phase-tint-alpha) fades to ~transparent by the time it
                // reaches the name, so in LIGHT mode the darkened, less
                // saturated text (esp. Strength's gold, which reads brown at
                // AA-legible lightness) is the only identity signal left —
                // reintroduce it the same way History's session-type tags do,
                // with the phase's own identity bg/border. Passed as custom
                // properties, not literal `background`/`border`: dark mode's
                // `.phase-banner` is already a flat 12% identity wash
                // (index.css .phase-banner-name dark override zeroes these
                // out there), so a second 12% layered on top would compound
                // to ~22.6% and fail AA for three of four phases (round-2
                // review, measured live) — the class resolves per theme
                // instead of a literal value baked in from JS.
                "--phase-name-bg": phase.bg,
                "--phase-name-border": phase.border,
              } as CSSProperties}
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
              className="phase-control-button"
              data-phase={phase.id}
              onClick={(e) => {
                e.stopPropagation();
                onChangePhase();
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
          className="phase-suggestion"
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            marginBottom: 10,
            padding: "9px 12px",
            "--phase-accent": phase.color,
          } as CSSProperties}
        >
          <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.4, flex: 1 }}>
            Readiness has been low for {stepBack.streakDays} days — consider
            stepping back to Capacity.
          </span>
          <InfoDot topic="phaseStepBack" />
          <button
            className="phase-control-button phase-control-button-accent"
            data-phase={phase.id}
            onClick={onChangePhase}
          >
            Step back
          </button>
          <button
            className="phase-dismiss-button"
            aria-label="Dismiss suggestion"
            onClick={dismissStepBack}
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

        {/* The summary remains visible; tapping anywhere except InfoDot opens detail. */}
        <div
          className="card surface-load"
          role="button"
          aria-label="Open training load details"
          tabIndex={0}
          data-haptic="light"
          onClick={() => setShowTrainingLoad(true)}
          onKeyDown={(event) => {
            // The nested InfoDot is its own keyboard target. Its click handler
            // stops propagation, but its keydown reaches this card first.
            if (event.target !== event.currentTarget) return;
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              setShowTrainingLoad(true);
            }
          }}
          style={{ cursor: "pointer" }}
        >
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
            <span style={{ display: "flex", alignItems: "center", gap: 10 }}>
              <InfoDot topic="acwr" />
              <span
                aria-hidden="true"
                style={{ color: "var(--ink-faint)", fontSize: 22, lineHeight: 1 }}
              >
                ›
              </span>
            </span>
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

          {/* Keep the two numbers that explain the ratio on the dashboard. */}
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

        <AcwrProjectionCard phase={phase} sessions={sessions} />

        {/* Weekly Tindeq-training consistency (#311) — self-fetching, no
            props needed from here. */}
        <ForceConsistencyCard />
      </div>

      {showRecovery && <RecoverySheet onClose={() => setShowRecovery(false)} />}
      {showTrainingLoad && (
        <TrainingLoadSheet
          weeklyLoads={weeklyLoads}
          sessions={sessions}
          onClose={() => setShowTrainingLoad(false)}
        />
      )}
    </div>
  );
}
