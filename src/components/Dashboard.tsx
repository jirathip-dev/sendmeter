import type {
  AcwrData,
  AcwrStatus,
  Phase,
  Session,
  WeeklyLoad,
} from "../types";
import ReadinessCard from "./ReadinessCard";
import RecoveryStatsCard from "./RecoveryStatsCard";
import SessionRow from "./SessionRow";
import ChartTooltip from "./ChartTooltip";
import { useChartHover } from "../hooks/useChartHover";

interface Props {
  phase: Phase;
  phaseDays: number;
  acwrData: AcwrData;
  weeklyLoads: WeeklyLoad[];
  status: AcwrStatus;
  sessions: Session[];
  onDelete: (id: string) => void;
  onLog: () => void;
  onOpenPhases: () => void;
}

export default function Dashboard({
  phase,
  phaseDays,
  acwrData,
  weeklyLoads,
  status,
  sessions,
  onDelete,
  onLog,
  onOpenPhases,
}: Props) {
  const recent = sessions.slice(0, 6);
  const maxW = Math.max(...weeklyLoads.map((w) => w.total), 1);
  const [hoveredWeek, hoverWeekProps] = useChartHover<number>();

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

      {/* ACWR + Load grid */}
      <div className="grid-2" style={{ marginBottom: 10 }}>
        <div className="card">
          <div
            style={{
              fontSize: 9,
              color: "var(--ink-muted)",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 8,
            }}
          >
            ACWR
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
          <div className="acwr-track">
            <div
              style={{
                position: "absolute",
                left: 0,
                top: 0,
                width: "100%",
                height: "100%",
                background:
                  "linear-gradient(to right, #7B83EB 0%,#7B83EB 15%,#34C759 30%,#34C759 68%,#FFB800 80%,#FF453A 100%)",
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
        </div>

        <div className="card">
          <div
            style={{
              fontSize: 9,
              color: "var(--ink-muted)",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 10,
            }}
          >
            Load (AU)
          </div>
          <div style={{ marginBottom: 12 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                fontSize: 11,
                marginBottom: 5,
              }}
            >
              <span style={{ color: "var(--ink-muted)" }}>Acute 7d</span>
              <span style={{ color: "var(--ink)" }}>
                {acwrData.acute.toFixed(0)}
              </span>
            </div>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                fontSize: 11,
              }}
            >
              <span style={{ color: "var(--ink-muted)" }}>Chronic avg</span>
              <span style={{ color: "var(--ink)" }}>
                {acwrData.chronic.toFixed(0)}
              </span>
            </div>
          </div>
          <div style={{ position: "relative" }}>
            {/* axis gridline at the max of the visible weeks */}
            <div
              style={{
                position: "absolute",
                left: 0,
                right: 0,
                top: 8,
                borderTop: "1px dashed var(--hairline)",
              }}
            >
              <span
                style={{
                  position: "absolute",
                  left: 0,
                  top: -8,
                  fontSize: 8,
                  color: "var(--ink-faint)",
                  background: "var(--surface-1)",
                  paddingRight: 3,
                }}
              >
                {Math.round(maxW)}
              </span>
            </div>
            {hoveredWeek !== null && (
              <div
                style={{
                  position: "absolute",
                  left: `${((hoveredWeek + 0.5) / weeklyLoads.length) * 100}%`,
                  top: 0,
                  bottom: 0,
                  width: 0,
                  borderLeft: "1px dashed var(--ink-faint)",
                  pointerEvents: "none",
                }}
              />
            )}
            <div
              style={{
                display: "flex",
                gap: 4,
                alignItems: "flex-end",
                height: 40,
              }}
            >
              {weeklyLoads.map((w, i) => (
                <div
                  key={i}
                  style={{
                    flex: 1,
                    display: "flex",
                    flexDirection: "column",
                    alignItems: "center",
                    gap: 3,
                    position: "relative",
                  }}
                >
                  {hoveredWeek === i && (
                    <ChartTooltip
                      align={
                        i === 0
                          ? "start"
                          : i === weeklyLoads.length - 1
                            ? "end"
                            : "center"
                      }
                    >
                      {w.label} · {w.total.toLocaleString()} AU
                    </ChartTooltip>
                  )}
                  <div
                    style={{
                      width: "100%",
                      height: Math.max((w.total / maxW) * 32, 2),
                      background: i === 3 ? "#34C759" : "var(--border)",
                      borderRadius: 2,
                      transition: "height 0.4s, opacity 0.1s",
                      opacity: hoveredWeek === null || hoveredWeek === i ? 1 : 0.5,
                      boxShadow: hoveredWeek === i ? "0 0 0 1.5px var(--ink)" : "none",
                      cursor: "pointer",
                    }}
                    {...hoverWeekProps(i)}
                  />
                  <div style={{ fontSize: 8, color: "var(--ink-faint)" }}>{w.label}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Readiness + the raw inputs behind it */}
      <div className="grid-2-desktop" style={{ marginBottom: 10 }}>
        <ReadinessCard />
        <RecoveryStatsCard />
      </div>

      {/* Log button */}
      <button
        className="btn-primary"
        style={{ marginBottom: 16 }}
        onClick={onLog}
      >
        + Log Session
      </button>

      {/* Recent */}
      <div
        style={{
          fontSize: 10,
          color: "var(--ink-faint)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 10,
        }}
      >
        Recent Sessions
      </div>
      {recent.length === 0 && (
        <div
          style={{
            textAlign: "center",
            color: "var(--ink-faint)",
            fontSize: 13,
            padding: "32px 0",
          }}
        >
          No sessions yet. Tap + Log Session to start.
        </div>
      )}
      {recent.map((s) => (
        <SessionRow key={s.id} s={s} onDelete={onDelete} />
      ))}
    </div>
  );
}
