import { useState } from "react";
import type {
  AcwrData,
  AcwrStatus,
  Phase,
  Session,
  WeeklyLoad,
} from "../types";
import ReadinessCard from "./ReadinessCard";
import LoadSheet from "./LoadSheet";
import RecoverySheet from "./RecoverySheet";
import SessionRow from "./SessionRow";
import { useRipple } from "../hooks/useRipple";
import { phaseAcwrFit } from "../lib/metrics";

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
  const [detail, setDetail] = useState<null | "load" | "recovery">(null);
  const { ripples: acwrRipples, spawnRipple: spawnAcwrRipple } = useRipple();

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

      {/* ACWR + Readiness stacked full-width */}
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          gap: 10,
          marginBottom: 10,
        }}
      >
        <div
          className="card tappable"
          onPointerDown={spawnAcwrRipple}
          onClick={() => setDetail("load")}
        >
          {acwrRipples}
          <div
            className="label-eyebrow"
            style={{ marginBottom: 8, display: "flex", justifyContent: "space-between", alignItems: "center" }}
          >
            <span>ACWR</span>
            <span style={{ fontSize: 13, color: "var(--ink-faint)" }}>›</span>
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
        </div>

        {/* Readiness below ACWR; acute/chronic numbers live in the
            Training Load page the ACWR card drills into */}
        <ReadinessCard onClick={() => setDetail("recovery")} />
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

      {detail === "load" && (
        <LoadSheet
          acwrData={acwrData}
          status={status}
          sessions={sessions}
          weeklyLoads={weeklyLoads}
          onClose={() => setDetail(null)}
        />
      )}
      {detail === "recovery" && <RecoverySheet onClose={() => setDetail(null)} />}
    </div>
  );
}
