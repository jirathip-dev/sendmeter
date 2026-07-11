import { PHASES } from "../constants";
import { today } from "../lib/dates";
import type { PhaseId, PhasePeriod } from "../types";

interface Props {
  currentPhase: PhaseId;
  phasePeriods: PhasePeriod[];
  onSetPhase: (id: PhaseId) => void;
}

function periodDays(p: PhasePeriod): number {
  const end = p.endedOn ?? today();
  return (
    Math.floor(
      (new Date(end).getTime() - new Date(p.startedOn).getTime()) / 86400000,
    ) + 1
  );
}

const ZONES = [
  { range: "< 0.7", label: "Under-training", color: "#818cf8" },
  { range: "0.7–0.8", label: "Low — build carefully", color: "#60a5fa" },
  { range: "0.8–1.3", label: "Optimal — safe progression", color: "#4ade80" },
  { range: "1.3–1.5", label: "Caution — monitor closely", color: "#facc15" },
  { range: "> 1.5", label: "Danger — injury risk", color: "#f87171" },
];

export default function PhasesView({
  currentPhase,
  phasePeriods,
  onSetPhase,
}: Props) {
  const chronological = [...phasePeriods].sort((a, b) =>
    a.startedOn.localeCompare(b.startedOn),
  );
  const totalDays = chronological.reduce((s, p) => s + periodDays(p), 0);

  function phaseHistory(id: PhaseId): string | null {
    const mine = phasePeriods.filter((p) => p.phase === id);
    if (mine.length === 0) return null;
    const days = mine.reduce((s, p) => s + periodDays(p), 0);
    const wks = (days / 7).toFixed(1);
    return `${mine.length} period${mine.length === 1 ? "" : "s"} · ${wks} wks total`;
  }

  return (
    <div>
      <div className="section-head">PHASES</div>
      <div className="section-sub">Tap to set your current training phase.</div>

      {PHASES.map((p) => (
        <div
          key={p.id}
          className="phase-card"
          style={{
            background: p.bg,
            border: `1px solid ${currentPhase === p.id ? p.color : p.border}`,
          }}
          onClick={() => onSetPhase(p.id)}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "flex-start",
            }}
          >
            <div style={{ flex: 1 }}>
              <div
                style={{
                  display: "flex",
                  gap: 8,
                  alignItems: "center",
                  marginBottom: 6,
                }}
              >
                <span
                  style={{
                    fontFamily: "'Syne', sans-serif",
                    fontSize: 18,
                    fontWeight: 800,
                    color: p.color,
                  }}
                >
                  {p.name.toUpperCase()}
                </span>
                {currentPhase === p.id && (
                  <span
                    className="tag"
                    style={{ background: p.color, color: "#0a0c10" }}
                  >
                    Active
                  </span>
                )}
              </div>
              <div style={{ fontSize: 11, color: "#7a8a9a", marginBottom: 10 }}>
                {p.desc}
              </div>
              <div style={{ display: "flex", gap: 5, flexWrap: "wrap" }}>
                {p.tools.map((t) => (
                  <span
                    key={t}
                    className="tag"
                    style={{
                      background: "#0a0c10",
                      color: "#4a5a70",
                      border: "1px solid #1e2d40",
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
            </div>
            <div style={{ textAlign: "right", flexShrink: 0, marginLeft: 12 }}>
              <div
                style={{
                  fontSize: 9,
                  color: "#4a5a70",
                  textTransform: "uppercase",
                  marginBottom: 3,
                }}
              >
                ACWR
              </div>
              <div
                style={{
                  fontSize: 17,
                  color: p.color,
                  fontFamily: "'Syne', sans-serif",
                  fontWeight: 800,
                }}
              >
                {p.acwr}
              </div>
              <div style={{ fontSize: 10, color: "#3a4a60", marginTop: 3 }}>
                {p.weeks}
              </div>
              <div style={{ fontSize: 10, color: "#3a4a60" }}>
                {p.intensity}
              </div>
              {phaseHistory(p.id) && (
                <div style={{ fontSize: 9, color: "#4a5a70", marginTop: 4 }}>
                  {phaseHistory(p.id)}
                </div>
              )}
            </div>
          </div>
        </div>
      ))}

      {/* Phase timeline */}
      {chronological.length >= 2 && totalDays > 0 && (
        <div className="card" style={{ marginBottom: 10 }}>
          <div
            style={{
              fontSize: 10,
              color: "#4a5a70",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 10,
            }}
          >
            Phase Timeline
          </div>
          <div
            style={{
              display: "flex",
              height: 10,
              borderRadius: 3,
              overflow: "hidden",
            }}
          >
            {chronological.map((p) => {
              const info = PHASES.find((x) => x.id === p.phase);
              const days = periodDays(p);
              return (
                <div
                  key={p.id}
                  title={`${info?.name ?? p.phase} · ${p.startedOn} → ${
                    p.endedOn ?? "now"
                  } · ${(days / 7).toFixed(1)} wks`}
                  style={{
                    width: `${(days / totalDays) * 100}%`,
                    minWidth: 4,
                    background: info?.color ?? "#334155",
                    opacity: p.endedOn === null ? 1 : 0.65,
                  }}
                />
              );
            })}
          </div>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: 9,
              color: "#2a3a50",
              marginTop: 5,
            }}
          >
            <span>{chronological[0]!.startedOn}</span>
            <span>now</span>
          </div>
        </div>
      )}

      <div className="card" style={{ marginTop: 6 }}>
        <div
          style={{
            fontSize: 10,
            color: "#4a5a70",
            textTransform: "uppercase",
            letterSpacing: "0.1em",
            marginBottom: 12,
          }}
        >
          ACWR Risk Zones
        </div>
        {ZONES.map((z) => (
          <div key={z.range} className="zone-row">
            <div className="zone-dot" style={{ background: z.color }} />
            <span style={{ fontSize: 11, color: "#7a8a9a", width: 64 }}>
              {z.range}
            </span>
            <span style={{ fontSize: 11, color: "#4a5a70" }}>{z.label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
