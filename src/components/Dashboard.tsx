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
  onChangePhase: () => void;
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
  onChangePhase,
}: Props) {
  const [showRecovery, setShowRecovery] = useState(false);
  const maxW = Math.max(...weeklyLoads.map((w) => w.total), 1);
  // Week-over-week delta: the windows are rolling 7-day sums, so "Now" vs
  // "1w" is a fair full-window comparison. No baseline (prev 0) hides it.
  const curWeek = weeklyLoads[weeklyLoads.length - 1]?.total ?? 0;
  const prevWeek = weeklyLoads[weeklyLoads.length - 2]?.total ?? 0;
  const weekDeltaPct = prevWeek > 0 ? ((curWeek - prevWeek) / prevWeek) * 100 : null;
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
      {/* Phase strip — slim + neutral context (SL-60): only the phase name
          carries color; it no longer fills the screen as a big colored box. */}
      <div
        className="phase-banner"
        title="Phase details"
        onClick={onOpenPhases}
        style={{
          marginBottom: 10,
          padding: "10px 14px",
          cursor: "pointer",
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          gap: 10,
        }}
      >
        <div style={{ minWidth: 0 }}>
          <div
            style={{
              fontSize: 9,
              color: "var(--ink-muted)",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
            }}
          >
            Current phase · Day {phaseDays}
          </div>
          <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginTop: 2 }}>
            <span
              style={{
                fontSize: 15,
                fontWeight: 700,
                color: phase.color,
                letterSpacing: "-0.01em",
              }}
            >
              {phase.name}
            </span>
            <span
              style={{
                fontSize: 10,
                color: "var(--ink-faint)",
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              }}
            >
              {phase.desc}
            </span>
          </div>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 12, flexShrink: 0 }}>
          <div style={{ textAlign: "right" }}>
            <div style={{ fontSize: 9, color: "var(--ink-muted)", textTransform: "uppercase" }}>
              Target
            </div>
            <div style={{ fontSize: 13, fontWeight: 700, color: "var(--ink)" }}>
              {phase.acwr}
            </div>
          </div>
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
              padding: "6px 10px",
              fontFamily: "Inter, sans-serif",
              fontSize: 10,
              fontWeight: 600,
              color: "var(--ink-muted)",
              cursor: "pointer",
            }}
          >
            Change
          </button>
        </div>
      </div>

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
            className="card-title"
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
          <div style={{ display: "flex", gap: 8, alignItems: "flex-end", height: 88 }}>
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
                    height: Math.max((w.total / maxW) * 64, 2),
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
          <div className="card-title" style={{ marginBottom: 12 }}>Daily load</div>
          <ContributionHeatmap values={daily} />
        </div>
      </div>

      {showRecovery && <RecoverySheet onClose={() => setShowRecovery(false)} />}
    </div>
  );
}
