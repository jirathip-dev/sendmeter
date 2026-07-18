import { computeTindeqStats } from "../lib/metrics";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import SvgChartTooltip from "./SvgChartTooltip";
import type { TindeqRecordingMeta, TindeqSide } from "../types";

interface Props {
  recordings: TindeqRecordingMeta[];
  /// Follows the tab's GLOBAL exercise/side (set in the Exercise card) —
  /// this chart has no filters of its own.
  selectedTag: string | null;
  selectedSide: TindeqSide | null;
}

const W = 300;
const H = 120;
const PAD = { top: 12, right: 8, bottom: 16, left: 30 };

function Chart({ sorted }: { sorted: TindeqRecordingMeta[] }) {
  const [hovered, hoverProps] = useChartHover<number>();
  const xs = sorted.map((r) => Date.parse(r.recordedAt));
  const tMin = xs[0]!;
  const tMax = Math.max(xs[xs.length - 1]!, tMin + 1);
  const peaks = sorted.map((r) => r.peakKg);
  const yMin = Math.min(...peaks) * 0.9;
  const yMax = Math.max(...peaks) * 1.08 || 1;

  const { x: px, y: py } = useSvgScale(W, H, PAD, tMin, tMax, yMin, yMax);

  const points = sorted
    .map((r, i) => `${px(xs[i]!).toFixed(1)},${py(r.peakKg).toFixed(1)}`)
    .join(" ");

  // PR = max peak; ties → most recent
  let prIdx = 0;
  sorted.forEach((r, i) => {
    if (r.peakKg >= sorted[prIdx]!.peakKg) prIdx = i;
  });

  const fmtDate = (t: number) => {
    const d = new Date(t);
    return `${d.getMonth() + 1}/${d.getDate()}`;
  };

  const hoveredR = hovered !== null ? sorted[hovered] : undefined;
  const yMid = (yMin + yMax) / 2;
  const yTicks = [yMin, yMid, yMax];

  return (
    <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
      {/* y-axis gridlines */}
      {yTicks.map((v, i) => (
        <g key={i}>
          <line
            x1={PAD.left}
            y1={py(v)}
            x2={W - PAD.right}
            y2={py(v)}
            style={{ stroke: "var(--hairline)" }}
            strokeWidth={1}
          />
          <text
            x={2}
            y={py(v) + (i === 0 ? -2 : i === yTicks.length - 1 ? 7 : 2.5)}
            fontSize={7.5}
            style={{ fill: "var(--ink-faint)" }}
          >
            {v.toFixed(0)}
            {i === yTicks.length - 1 ? "kg" : ""}
          </text>
        </g>
      ))}
      <polyline
        points={points}
        fill="none"
        stroke="#5B5FC7"
        strokeWidth={1.5}
        vectorEffect="non-scaling-stroke"
      />
      {sorted.map((r, i) => (
        <circle
          key={r.id}
          cx={px(xs[i]!)}
          cy={py(r.peakKg)}
          r={hovered === i ? (i === prIdx ? 6 : 4.5) : i === prIdx ? 4 : 2.5}
          fill={i === prIdx ? "#DDB13A" : "#5B5FC7"}
          style={{ cursor: "pointer", transition: "r 0.1s" }}
          {...hoverProps(i)}
        />
      ))}
      {sorted[prIdx] && (
        <text
          x={Math.min(px(xs[prIdx]!), W - 18)}
          y={Math.max(py(sorted[prIdx]!.peakKg) - 8, 8)}
          fontSize={8}
          fill="#DDB13A"
        >
          PR
        </text>
      )}
      <text x={PAD.left} y={H - 4} fontSize={8} style={{ fill: "var(--ink-faint)" }}>
        {fmtDate(tMin)}
      </text>
      <text
        x={W - PAD.right}
        y={H - 4}
        fontSize={8}
        style={{ fill: "var(--ink-faint)" }}
        textAnchor="end"
      >
        {fmtDate(tMax)}
      </text>
      {hovered !== null && (
        <line
          x1={px(xs[hovered]!)}
          y1={PAD.top}
          x2={px(xs[hovered]!)}
          y2={H - PAD.bottom}
          style={{ stroke: "var(--ink-faint)" }}
          strokeDasharray="2 2"
          strokeWidth={1}
        />
      )}
      {hoveredR && hovered !== null && (
        <SvgChartTooltip
          x={px(xs[hovered]!)}
          y={py(hoveredR.peakKg)}
          viewW={W}
          viewH={H}
          lines={[
            fmtDate(xs[hovered]!),
            `${hoveredR.peakKg.toFixed(1)} kg${hoveredR.tag ? ` · ${hoveredR.tag}` : ""}`,
          ]}
        />
      )}
    </svg>
  );
}

export default function ForceTrendChart({
  recordings,
  selectedTag,
  selectedSide,
}: Props) {
  const filtered = recordings.filter(
    (r) =>
      (selectedTag === null || r.tag === selectedTag) &&
      (selectedSide === null || r.side === selectedSide),
  );

  const stats = computeTindeqStats(filtered);
  if (recordings.length < 2) return null;

  const sorted = [...filtered].sort((a, b) =>
    a.recordedAt.localeCompare(b.recordedAt),
  );

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="label-eyebrow" style={{ marginBottom: 10 }}>
        Peak Force Trend
        {selectedTag && (
          <span style={{ color: "var(--ink-faint)" }}>
            {" "}
            · {selectedTag}
            {selectedSide ? ` · ${selectedSide}` : ""}
          </span>
        )}
      </div>

      {stats && sorted.length >= 2 ? (
        <>
          <div
            className="grid-2"
            style={{ gridTemplateColumns: "1fr 1fr 1fr", marginBottom: 10 }}
          >
            <div>
              <div style={{ fontSize: 9, color: "var(--ink-muted)" }}>Best</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: 16,
                  color: "var(--warning)",
                }}
              >
                {stats.bestPeak.toFixed(1)}
              </div>
            </div>
            <div>
              <div style={{ fontSize: 9, color: "var(--ink-muted)" }}>Last</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: 16,
                  color: "var(--surface-1)",
                }}
              >
                {stats.lastPeak.toFixed(1)}
              </div>
            </div>
            <div>
              <div style={{ fontSize: 9, color: "var(--ink-muted)" }}>vs 30d avg</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: 16,
                  color:
                    stats.delta === null
                      ? "var(--ink-muted)"
                      : stats.delta >= 0
                        ? "var(--success)"
                        : "var(--danger)",
                }}
              >
                {stats.delta === null
                  ? "—"
                  : `${stats.delta >= 0 ? "+" : ""}${stats.delta.toFixed(1)}`}
              </div>
            </div>
          </div>
          <Chart sorted={sorted} />
        </>
      ) : (
        <div style={{ fontSize: 11, color: "var(--ink-faint)", padding: "12px 0" }}>
          Not enough recordings with this tag yet.
        </div>
      )}
    </div>
  );
}
