import { computeTindeqStats } from "../lib/metrics";
import type { TindeqRecordingMeta } from "../types";

interface Props {
  recordings: TindeqRecordingMeta[];
}

const W = 300;
const H = 120;
const PAD_TOP = 12;
const PAD_BOTTOM = 16;
const PAD_LEFT = 30;
const PAD_RIGHT = 8;

export default function TindeqTrendChart({ recordings }: Props) {
  const stats = computeTindeqStats(recordings);
  if (!stats) return null;

  const sorted = [...recordings].sort((a, b) =>
    a.recordedAt.localeCompare(b.recordedAt),
  );
  const xs = sorted.map((r) => Date.parse(r.recordedAt));
  const tMin = xs[0]!;
  const tMax = Math.max(xs[xs.length - 1]!, tMin + 1);
  const peaks = sorted.map((r) => r.peakKg);
  const yMin = Math.min(...peaks) * 0.9;
  const yMax = Math.max(...peaks) * 1.08 || 1;

  const px = (t: number) =>
    PAD_LEFT + ((t - tMin) / (tMax - tMin)) * (W - PAD_LEFT - PAD_RIGHT);
  const py = (kg: number) =>
    PAD_TOP + (1 - (kg - yMin) / (yMax - yMin)) * (H - PAD_TOP - PAD_BOTTOM);

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

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div
        style={{
          fontSize: 9,
          color: "#4a5a70",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 10,
        }}
      >
        Peak Force Trend
      </div>

      <div className="grid-2" style={{ gridTemplateColumns: "1fr 1fr 1fr", marginBottom: 10 }}>
        <div>
          <div style={{ fontSize: 9, color: "#4a5a70" }}>Best</div>
          <div
            style={{
              fontFamily: "'Syne', sans-serif",
              fontWeight: 800,
              fontSize: 16,
              color: "#facc15",
            }}
          >
            {stats.bestPeak.toFixed(1)}
          </div>
        </div>
        <div>
          <div style={{ fontSize: 9, color: "#4a5a70" }}>Last</div>
          <div
            style={{
              fontFamily: "'Syne', sans-serif",
              fontWeight: 800,
              fontSize: 16,
              color: "#e2e8f0",
            }}
          >
            {stats.lastPeak.toFixed(1)}
          </div>
        </div>
        <div>
          <div style={{ fontSize: 9, color: "#4a5a70" }}>vs 30d avg</div>
          <div
            style={{
              fontFamily: "'Syne', sans-serif",
              fontWeight: 800,
              fontSize: 16,
              color:
                stats.delta === null
                  ? "#4a5a70"
                  : stats.delta >= 0
                    ? "#4ade80"
                    : "#f87171",
            }}
          >
            {stats.delta === null
              ? "—"
              : `${stats.delta >= 0 ? "+" : ""}${stats.delta.toFixed(1)}`}
          </div>
        </div>
      </div>

      <svg
        viewBox={`0 0 ${W} ${H}`}
        style={{ width: "100%", display: "block" }}
      >
        <text x={2} y={PAD_TOP + 3} fontSize={8} fill="#2a3a50">
          {yMax.toFixed(0)}kg
        </text>
        <text x={2} y={H - PAD_BOTTOM} fontSize={8} fill="#2a3a50">
          {yMin.toFixed(0)}
        </text>
        <polyline
          points={points}
          fill="none"
          stroke="#4ade80"
          strokeWidth={1.5}
          vectorEffect="non-scaling-stroke"
        />
        {sorted.map((r, i) => (
          <circle
            key={r.id}
            cx={px(xs[i]!)}
            cy={py(r.peakKg)}
            r={i === prIdx ? 4 : 2.5}
            fill={i === prIdx ? "#facc15" : "#4ade80"}
          >
            <title>
              {`${fmtDate(xs[i]!)} · ${r.peakKg.toFixed(1)} kg`}
            </title>
          </circle>
        ))}
        {sorted[prIdx] && (
          <text
            x={Math.min(px(xs[prIdx]!), W - 18)}
            y={Math.max(py(sorted[prIdx]!.peakKg) - 8, 8)}
            fontSize={8}
            fill="#facc15"
          >
            PR
          </text>
        )}
        <text x={PAD_LEFT} y={H - 4} fontSize={8} fill="#2a3a50">
          {fmtDate(tMin)}
        </text>
        <text x={W - PAD_RIGHT} y={H - 4} fontSize={8} fill="#2a3a50" textAnchor="end">
          {fmtDate(tMax)}
        </text>
      </svg>
    </div>
  );
}
