import { useEffect, useState } from "react";
import { fetchRpePairs } from "../lib/repo";
import type { RpePair } from "../types";

const S = 140;
const PAD = 14;

function pos(v: number): number {
  return PAD + ((v - 1) / 9) * (S - 2 * PAD);
}

export default function RpeScatterCard() {
  const [pairs, setPairs] = useState<RpePair[]>([]);

  useEffect(() => {
    let cancelled = false;
    fetchRpePairs()
      .then((p) => {
        if (!cancelled) setPairs(p);
      })
      .catch(() => {
        // card simply stays hidden on error
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (pairs.length < 3) return null;

  const mae =
    pairs.reduce((s, p) => s + Math.abs(p.predicted - p.confirmed), 0) /
    pairs.length;

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div
        style={{
          fontSize: 9,
          color: "var(--ink-muted)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 8,
        }}
      >
        RPE Model
      </div>
      <div style={{ maxWidth: 220 }}>
        <svg viewBox={`0 0 ${S} ${S}`} style={{ width: "100%", display: "block" }}>
          {/* perfect-prediction diagonal */}
          <line
            x1={pos(1)}
            y1={S - pos(1)}
            x2={pos(10)}
            y2={S - pos(10)}
            style={{ stroke: "var(--ink-faint)" }}
            strokeDasharray="3 3"
            strokeWidth={1}
          />
          {pairs.map((p, i) => (
            <circle
              key={i}
              cx={pos(p.predicted)}
              cy={S - pos(p.confirmed)}
              r={3}
              fill="#5B5FC7"
              opacity={0.35 + 0.65 * (i / Math.max(1, pairs.length - 1))}
            >
              <title>{`pred ${p.predicted.toFixed(1)} · you said ${p.confirmed}`}</title>
            </circle>
          ))}
          <text x={S / 2} y={S - 1} fontSize={7} style={{ fill: "var(--ink-faint)" }} textAnchor="middle">
            predicted →
          </text>
          <text
            x={5}
            y={S / 2}
            fontSize={7}
            style={{ fill: "var(--ink-faint)" }}
            textAnchor="middle"
            transform={`rotate(-90 5 ${S / 2})`}
          >
            confirmed →
          </text>
        </svg>
      </div>
      <div style={{ fontSize: 10, color: "var(--ink-muted)", marginTop: 6 }}>
        {pairs.length} workouts · mean abs err{" "}
        <span style={{ color: "var(--ink-muted)" }}>{mae.toFixed(1)}</span>
      </div>
    </div>
  );
}
