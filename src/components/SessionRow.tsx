import { PHASES } from "../constants";
import type { Session } from "../types";

interface Props {
  s: Session;
  onDelete: (id: string) => void;
}

export default function SessionRow({ s, onDelete }: Props) {
  const ph = PHASES.find((p) => p.id === s.phase);
  return (
    <div className="session-row">
      <div
        className="session-phase-bar"
        style={{ background: ph?.color || "#334155" }}
      />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div
          style={{
            display: "flex",
            gap: 7,
            alignItems: "center",
            marginBottom: 4,
            flexWrap: "wrap",
          }}
        >
          <span style={{ fontSize: 13, color: "#e2e8f0" }}>{s.typeLabel}</span>
          <span
            className="tag"
            style={{
              background: ph?.bg || "#1e2d40",
              color: ph?.color || "#7a8a9a",
              border: `1px solid ${ph?.border || "#1e2d40"}`,
            }}
          >
            {ph?.name || s.phase}
          </span>
        </div>
        <div style={{ fontSize: 11, color: "#4a5a70" }}>
          {s.date} · {s.duration}min · RPE {s.rpe} ·{" "}
          <span style={{ color: "#7a8a9a" }}>{s.load} AU</span>
        </div>
        {s.note && (
          <div style={{ fontSize: 11, color: "#3a4a60", marginTop: 3 }}>
            {s.note}
          </div>
        )}
      </div>
      <button className="del-btn" onClick={() => onDelete(s.id)}>
        ×
      </button>
    </div>
  );
}
