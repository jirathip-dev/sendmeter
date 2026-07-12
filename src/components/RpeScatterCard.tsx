import { useEffect, useState } from "react";
import { fetchRpePairs } from "../lib/repo";
import { useChartHover } from "../hooks/useChartHover";
import SvgChartTooltip from "./SvgChartTooltip";
import type { RpePair } from "../types";

const W = 150;
const H = 150;
const PAD_LEFT = 20;
const PAD_RIGHT = 8;
const PAD_TOP = 8;
const PAD_BOTTOM = 18;
const TICKS = [1, 4, 7, 10];

function px(v: number): number {
  return PAD_LEFT + ((v - 1) / 9) * (W - PAD_LEFT - PAD_RIGHT);
}

function py(v: number): number {
  return PAD_TOP + (1 - (v - 1) / 9) * (H - PAD_TOP - PAD_BOTTOM);
}

export default function RpeScatterCard() {
  const [pairs, setPairs] = useState<RpePair[]>([]);
  const [hovered, hoverProps] = useChartHover<number>();

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

  // Empty state: the feature should be discoverable before enough data exists
  if (pairs.length < 3) {
    return (
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
          RPE Model
        </div>
        <div style={{ fontSize: 11, color: "var(--ink-muted)", lineHeight: 1.5 }}>
          Shows predicted vs. confirmed RPE for your auto-tracked workouts,
          once you've confirmed at least 3 ({pairs.length}/3 so far).
        </div>
      </div>
    );
  }

  const mae =
    pairs.reduce((s, p) => s + Math.abs(p.predicted - p.confirmed), 0) /
    pairs.length;

  const hoveredPair = hovered !== null ? pairs[hovered] : undefined;

  return (
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
        RPE Model
      </div>
      <div style={{ maxWidth: 220 }}>
        <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
          {/* axis gridlines + ticks */}
          {TICKS.map((v) => (
            <g key={`grid-${v}`}>
              <line
                x1={PAD_LEFT}
                y1={py(v)}
                x2={W - PAD_RIGHT}
                y2={py(v)}
                style={{ stroke: "var(--hairline)" }}
                strokeWidth={1}
              />
              <line
                x1={px(v)}
                y1={PAD_TOP}
                x2={px(v)}
                y2={H - PAD_BOTTOM}
                style={{ stroke: "var(--hairline)" }}
                strokeWidth={1}
              />
              <text
                x={px(v)}
                y={H - PAD_BOTTOM + 9}
                fontSize={6.5}
                style={{ fill: "var(--ink-faint)" }}
                textAnchor="middle"
              >
                {v}
              </text>
              <text
                x={PAD_LEFT - 4}
                y={py(v) + 2}
                fontSize={6.5}
                style={{ fill: "var(--ink-faint)" }}
                textAnchor="end"
              >
                {v}
              </text>
            </g>
          ))}

          {/* perfect-prediction diagonal */}
          <line
            x1={px(1)}
            y1={py(1)}
            x2={px(10)}
            y2={py(10)}
            style={{ stroke: "var(--ink-faint)" }}
            strokeDasharray="3 3"
            strokeWidth={1}
          />
          {pairs.map((p, i) => (
            <circle
              key={i}
              cx={px(p.predicted)}
              cy={py(p.confirmed)}
              r={hovered === i ? 5 : 3}
              fill="#5B5FC7"
              opacity={
                hovered === null || hovered === i
                  ? 0.35 + 0.65 * (i / Math.max(1, pairs.length - 1))
                  : 0.2
              }
              style={{ cursor: "pointer", transition: "r 0.1s, opacity 0.1s" }}
              {...hoverProps(i)}
            />
          ))}
          <text
            x={W - PAD_RIGHT}
            y={H - 2}
            fontSize={6.5}
            style={{ fill: "var(--ink-faint)" }}
            textAnchor="end"
          >
            predicted
          </text>
          <text
            x={4}
            y={PAD_TOP + 2}
            fontSize={6.5}
            style={{ fill: "var(--ink-faint)" }}
            textAnchor="start"
            transform={`rotate(-90 4 ${PAD_TOP + 2})`}
          >
            confirmed
          </text>
          {hoveredPair && (
            <SvgChartTooltip
              x={px(hoveredPair.predicted)}
              y={py(hoveredPair.confirmed)}
              viewW={W}
              viewH={H}
              lines={[
                `pred ${hoveredPair.predicted.toFixed(1)}`,
                `you said ${hoveredPair.confirmed}`,
              ]}
            />
          )}
        </svg>
      </div>
      <div style={{ fontSize: 10, color: "var(--ink-muted)", marginTop: 6 }}>
        {pairs.length} workouts · mean abs err{" "}
        <span style={{ color: "var(--ink-muted)" }}>{mae.toFixed(1)}</span>
      </div>
    </div>
  );
}
