import { PHASES } from "../constants";
import type { PhaseId } from "../types";

interface Props {
  currentPhase: PhaseId;
  onSetPhase: (id: PhaseId) => void;
}

const ZONES = [
  { range: "< 0.7", label: "Under-training", color: "#818cf8" },
  { range: "0.7–0.8", label: "Low — build carefully", color: "#60a5fa" },
  { range: "0.8–1.3", label: "Optimal — safe progression", color: "#4ade80" },
  { range: "1.3–1.5", label: "Caution — monitor closely", color: "#facc15" },
  { range: "> 1.5", label: "Danger — injury risk", color: "#f87171" },
];

export default function PhasesView({ currentPhase, onSetPhase }: Props) {
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
            </div>
          </div>
        </div>
      ))}

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
