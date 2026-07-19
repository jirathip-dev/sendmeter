import { useChartHover } from "../hooks/useChartHover";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { useSvgScale } from "../hooks/useSvgScale";
import { fetchRpePairs } from "../lib/repo";
import SvgChartTooltip from "./SvgChartTooltip";
import type { RpePair } from "../types";

const W = 150;
const H = 150;
const PAD = { top: 8, right: 8, bottom: 18, left: 20 };
const TICKS = [1, 4, 7, 10];

export default function RpeScatterCard() {
  const [hovered, hoverProps] = useChartHover<number>();
  const realtimeVersion = useRealtimeVersion();
  // Fixed 1-10 RPE domain on both axes — called unconditionally since the
  // empty-state early return below happens before any chart is rendered.
  const { x: px, y: py } = useSvgScale(W, H, PAD, 1, 10, 1, 10);
  const pairs = useCancellableFetch<RpePair[]>(fetchRpePairs, [], realtimeVersion);

  // Empty state: the feature should be discoverable before enough data exists
  if (pairs.length < 3) {
    return (
      <div className="card">
        <div className="label-eyebrow" style={{ marginBottom: 8 }}>
          RPE Model
        </div>
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.5 }}>
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
      <div className="label-eyebrow" style={{ marginBottom: 8 }}>
        RPE Model
      </div>
      <div style={{ maxWidth: 220 }}>
        <svg className="chart-scrub" viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
          {/* axis gridlines + ticks */}
          {TICKS.map((v) => (
            <g key={`grid-${v}`}>
              <line
                x1={PAD.left}
                y1={py(v)}
                x2={W - PAD.right}
                y2={py(v)}
                style={{ stroke: "var(--hairline)" }}
                strokeWidth={1}
              />
              <line
                x1={px(v)}
                y1={PAD.top}
                x2={px(v)}
                y2={H - PAD.bottom}
                style={{ stroke: "var(--hairline)" }}
                strokeWidth={1}
              />
              <text
                x={px(v)}
                y={H - PAD.bottom + 9}
                fontSize={6.5}
                style={{ fill: "var(--ink-faint)" }}
                textAnchor="middle"
              >
                {v}
              </text>
              <text
                x={PAD.left - 4}
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
          {pairs.map((p, i) => {
            // Color by how close the prediction was (SVG can't read CSS vars):
            // spot-on = blue, off by ~1 pt = yellow, way off = orange.
            const err = Math.abs(p.predicted - p.confirmed);
            const dotColor =
              err <= 1 ? "#2E96F0" : err <= 2 ? "#DDB13A" : "#E5743A";
            return (
            <circle
              key={i}
              cx={px(p.predicted)}
              cy={py(p.confirmed)}
              r={hovered === i ? 5 : 3}
              fill={dotColor}
              opacity={
                hovered === null || hovered === i
                  ? 0.35 + 0.65 * (i / Math.max(1, pairs.length - 1))
                  : 0.2
              }
              style={{ cursor: "pointer", transition: "r 0.1s, opacity 0.1s" }}
              {...hoverProps(i)}
            />
            );
          })}
          <text
            x={W - PAD.right}
            y={H - 2}
            fontSize={6.5}
            style={{ fill: "var(--ink-faint)" }}
            textAnchor="end"
          >
            predicted
          </text>
          <text
            x={4}
            y={PAD.top + 2}
            fontSize={6.5}
            style={{ fill: "var(--ink-faint)" }}
            textAnchor="start"
            transform={`rotate(-90 4 ${PAD.top + 2})`}
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
      <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", marginTop: 6 }}>
        {pairs.length} workouts · mean abs err{" "}
        <span
          style={{
            color:
              mae <= 1
                ? "var(--success)"
                : mae <= 2
                  ? "var(--warning)"
                  : "var(--danger)",
            fontWeight: 700,
          }}
        >
          {mae.toFixed(1)}
        </span>
      </div>
    </div>
  );
}
