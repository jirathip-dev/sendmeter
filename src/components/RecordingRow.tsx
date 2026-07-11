import { useState } from "react";
import { fetchRecordingSamples } from "../lib/repo";
import type { TindeqRecordingMeta, TindeqSample } from "../types";

interface Props {
  rec: TindeqRecordingMeta;
  onDelete: (id: string) => void;
}

function SamplesPreview({ samples }: { samples: TindeqSample[] }) {
  if (samples.length < 2) return null;
  const w = 300;
  const h = 60;
  const tMax = samples[samples.length - 1]!.t || 1;
  const kgMax = Math.max(...samples.map((s) => s.kg), 1) * 1.1;
  const points = samples
    .map(
      (s) =>
        `${((s.t / tMax) * w).toFixed(1)},${(h - (s.kg / kgMax) * h).toFixed(1)}`,
    )
    .join(" ");
  return (
    <svg
      viewBox={`0 0 ${w} ${h}`}
      style={{ width: "100%", height: 60, display: "block", marginTop: 10 }}
      preserveAspectRatio="none"
    >
      <polyline
        points={points}
        fill="none"
        stroke="#4ade80"
        strokeWidth="1.5"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
}

export default function RecordingRow({ rec, onDelete }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [samples, setSamples] = useState<TindeqSample[] | null>(null);
  const [loadError, setLoadError] = useState(false);

  async function toggle() {
    const next = !expanded;
    setExpanded(next);
    if (next && !samples) {
      try {
        setSamples(await fetchRecordingSamples(rec.id));
      } catch {
        setLoadError(true);
      }
    }
  }

  const date = new Date(rec.recordedAt);
  const dateLabel = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")} ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;

  return (
    <div
      className="session-row"
      style={{ flexDirection: "column", alignItems: "stretch", gap: 0 }}
    >
      <div
        style={{ display: "flex", alignItems: "center", gap: 12, cursor: "pointer" }}
        onClick={() => void toggle()}
      >
        <div className="session-phase-bar" style={{ background: "#4ade80" }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div
            style={{
              fontSize: 13,
              color: "#e2e8f0",
              marginBottom: 4,
              display: "flex",
              alignItems: "center",
              gap: 7,
              flexWrap: "wrap",
            }}
          >
            <span>
              <span
                style={{
                  fontFamily: "'Syne', sans-serif",
                  fontWeight: 800,
                  color: "#4ade80",
                }}
              >
                {rec.peakKg.toFixed(1)} kg
              </span>{" "}
              peak
            </span>
            {rec.tag && (
              <span
                className="tag"
                style={{
                  background: "rgba(96,165,250,0.12)",
                  color: "#60a5fa",
                  border: "1px solid rgba(96,165,250,0.35)",
                }}
              >
                {rec.tag}
              </span>
            )}
            {rec.side && (
              <span
                className="tag"
                style={{
                  background: "rgba(250,204,21,0.10)",
                  color: "#facc15",
                  border: "1px solid rgba(250,204,21,0.3)",
                }}
              >
                {rec.side === "both" ? "L+R" : rec.side === "left" ? "L" : "R"}
              </span>
            )}
          </div>
          <div style={{ fontSize: 11, color: "#4a5a70" }}>
            {dateLabel} · {(rec.durationMs / 1000).toFixed(1)}s · avg{" "}
            {rec.avgKg.toFixed(1)} kg
          </div>
          {rec.note && (
            <div style={{ fontSize: 11, color: "#3a4a60", marginTop: 3 }}>
              {rec.note}
            </div>
          )}
        </div>
        <button
          className="del-btn"
          onClick={(e) => {
            e.stopPropagation();
            onDelete(rec.id);
          }}
        >
          ×
        </button>
      </div>
      {expanded &&
        (samples ? (
          <SamplesPreview samples={samples} />
        ) : (
          <div style={{ fontSize: 10, color: "#3a4a60", marginTop: 8 }}>
            {loadError ? "Failed to load trace" : "Loading trace…"}
          </div>
        ))}
    </div>
  );
}
