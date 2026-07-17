import { useMemo, useState } from "react";
import type {
  AcwrData,
  AcwrStatus,
  Phase,
  Session,
  WeeklyLoad,
} from "../types";
import ContributionHeatmap from "./ContributionHeatmap";
import InfoDot from "./InfoDot";
import ReadinessCard from "./ReadinessCard";
import RecoverySheet from "./RecoverySheet";
import { phaseAcwrFit } from "../lib/metrics";

interface Props {
  phase: Phase;
  phaseDays: number;
  acwrData: AcwrData;
  weeklyLoads: WeeklyLoad[];
  status: AcwrStatus;
  sessions: Session[];
  onOpenPhases: () => void;
}

/// Home: phase banner + ACWR with the full training-load detail inline
/// (acute/chronic, weekly totals, daily heatmap — formerly the LoadSheet
/// drill-in) + readiness. Sessions live in History; logging lives in Workout.
export default function Dashboard({
  phase,
  phaseDays,
  acwrData,
  weeklyLoads,
  status,
  sessions,
  onOpenPhases,
}: Props) {
  const [showRecovery, setShowRecovery] = useState(false);
  const maxW = Math.max(...weeklyLoads.map((w) => w.total), 1);
  // Week-over-week delta: the windows are rolling 7-day sums, so "Now" vs
  // "1w" is a fair full-window comparison. No baseline (prev 0) hides it.
  const curWeek = weeklyLoads[weeklyLoads.length - 1]?.total ?? 0;
  const prevWeek = weeklyLoads[weeklyLoads.length - 2]?.total ?? 0;
  const weekDeltaPct = prevWeek > 0 ? ((curWeek - prevWeek) / prevWeek) * 100 : null;
  const daily = useMemo(() => {
    const m = new Map<string, number>();
    for (const s of sessions) m.set(s.date, (m.get(s.date) ?? 0) + s.load);
    return m;
  }, [sessions]);

  return (
    <div>
      {/* Phase strip — tap to change phase */}
      <div
        className="phase-banner"
        title="Change training phase"
        onClick={onOpenPhases}
        style={{
          background: phase.bg,
          border: `1px solid ${phase.border}`,
          marginBottom: 10,
          cursor: "pointer",
        }}
      >
        <div
          style={{
            fontSize: 9,
            color: phase.color,
            textTransform: "uppercase",
            letterSpacing: "0.12em",
            marginBottom: 4,
          }}
        >
          Current Phase — Day {phaseDays}
        </div>
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "flex-start",
          }}
        >
          <div>
            <div
              style={{
                fontFamily: "Inter, sans-serif",
                fontSize: 26,
                fontWeight: 800,
                color: phase.color,
                letterSpacing: "-0.02em",
                lineHeight: 1,
              }}
            >
              {phase.name.toUpperCase()}
            </div>
            <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 5 }}>
              {phase.desc}
            </div>
          </div>
          <div style={{ textAlign: "right", flexShrink: 0, marginLeft: 12 }}>
            <div
              style={{
                fontSize: 9,
                color: "var(--ink-muted)",
                textTransform: "uppercase",
              }}
            >
              Target ACWR
            </div>
            <div
              style={{
                fontSize: 20,
                color: phase.color,
                fontFamily: "Inter, sans-serif",
                fontWeight: 800,
              }}
            >
              {phase.acwr}
            </div>
          </div>
        </div>
      </div>

      <div
        style={{
          display: "flex",
          flexDirection: "column",
          gap: 10,
        }}
      >
        {/* ACWR — the load detail now lives right below, no drill-in */}
        <div className="card">
          <div
            className="label-eyebrow"
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
          <div style={{ fontSize: 11, color: status.color, marginTop: 4 }}>
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
              <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 2 }}>
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
                background:
                  "linear-gradient(to right, var(--info) 0%,var(--info) 15%,var(--success) 30%,var(--success) 68%,var(--warning) 80%,var(--danger) 100%)",
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
              display: "flex",
              justifyContent: "space-between",
              fontSize: 9,
              color: "var(--ink-faint)",
            }}
          >
            <span>0</span>
            <span>1.0</span>
            <span>1.5</span>
            <span>2</span>
          </div>

          {/* Acute / chronic (formerly the LoadSheet drill-in) */}
          <div
            style={{
              display: "flex",
              gap: 24,
              marginTop: 12,
              paddingTop: 10,
              borderTop: "1px solid var(--hairline)",
              fontSize: 12,
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

        {/* Weekly totals */}
        <div className="card">
          <div
            className="label-eyebrow"
            style={{
              marginBottom: 12,
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
            }}
          >
            <span>Weekly load</span>
            {weekDeltaPct !== null && (
              <span
                style={{
                  fontSize: 10,
                  fontVariantNumeric: "tabular-nums",
                  color:
                    Math.abs(weekDeltaPct) < 1
                      ? "var(--ink-muted)"
                      : weekDeltaPct > 0
                        ? "var(--success)"
                        : "var(--danger)",
                }}
              >
                {weekDeltaPct > 0 ? "▲" : weekDeltaPct < 0 ? "▼" : ""}{" "}
                {Math.abs(weekDeltaPct).toFixed(0)}% vs prior wk
              </span>
            )}
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "flex-end", height: 72 }}>
            {weeklyLoads.map((w, i) => (
              <div
                key={i}
                style={{
                  flex: 1,
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 4,
                  height: "100%",
                  justifyContent: "flex-end",
                }}
              >
                <span style={{ fontSize: 9, color: "var(--ink-muted)" }}>
                  {w.total.toLocaleString()}
                </span>
                <div
                  style={{
                    width: "100%",
                    height: Math.max((w.total / maxW) * 48, 2),
                    background: i === weeklyLoads.length - 1 ? "var(--success)" : "var(--border)",
                    borderRadius: 3,
                  }}
                />
                <span style={{ fontSize: 8, color: "var(--ink-faint)" }}>{w.label}</span>
              </div>
            ))}
          </div>
        </div>

        {/* Daily AU heatmap */}
        <div className="card">
          <div className="label-eyebrow" style={{ marginBottom: 12 }}>Daily load</div>
          <ContributionHeatmap values={daily} />
        </div>

        {/* Readiness (still drills into the recovery detail) */}
        <ReadinessCard onClick={() => setShowRecovery(true)} />
      </div>

      {showRecovery && <RecoverySheet onClose={() => setShowRecovery(false)} />}
    </div>
  );
}
