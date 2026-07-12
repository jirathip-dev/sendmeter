import { useMemo } from "react";
import { computeTindeqStats } from "../lib/metrics";
import type { TindeqRecordingMeta, TindeqSide } from "../types";

interface Props {
  recordings: TindeqRecordingMeta[];
  selectedTag: string | null;
  onSelectTag: (tag: string | null) => void;
  selectedSide: TindeqSide | null;
  onSelectSide: (side: TindeqSide | null) => void;
}

const W = 300;
const H = 120;
const PAD_TOP = 12;
const PAD_BOTTOM = 16;
const PAD_LEFT = 30;
const PAD_RIGHT = 8;

function TagChip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="tag"
      style={{
        background: active ? "#5B5FC7" : "#F5F5F7",
        color: active ? "#ffffff" : "#6E6E73",
        border: `1px solid ${active ? "#5B5FC7" : "#D8D8DC"}`,
        cursor: "pointer",
        fontFamily: "Inter, sans-serif",
      }}
    >
      {label}
    </button>
  );
}

function Chart({ sorted }: { sorted: TindeqRecordingMeta[] }) {
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
    <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
      <text x={2} y={PAD_TOP + 3} fontSize={8} fill="#8E8E93">
        {yMax.toFixed(0)}kg
      </text>
      <text x={2} y={H - PAD_BOTTOM} fontSize={8} fill="#8E8E93">
        {yMin.toFixed(0)}
      </text>
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
          r={i === prIdx ? 4 : 2.5}
          fill={i === prIdx ? "#FFB800" : "#5B5FC7"}
        >
          <title>{`${fmtDate(xs[i]!)} · ${r.peakKg.toFixed(1)} kg${r.tag ? ` · ${r.tag}` : ""}`}</title>
        </circle>
      ))}
      {sorted[prIdx] && (
        <text
          x={Math.min(px(xs[prIdx]!), W - 18)}
          y={Math.max(py(sorted[prIdx]!.peakKg) - 8, 8)}
          fontSize={8}
          fill="#FFB800"
        >
          PR
        </text>
      )}
      <text x={PAD_LEFT} y={H - 4} fontSize={8} fill="#8E8E93">
        {fmtDate(tMin)}
      </text>
      <text
        x={W - PAD_RIGHT}
        y={H - 4}
        fontSize={8}
        fill="#8E8E93"
        textAnchor="end"
      >
        {fmtDate(tMax)}
      </text>
    </svg>
  );
}

export default function TindeqTrendChart({
  recordings,
  selectedTag,
  onSelectTag,
  selectedSide,
  onSelectSide,
}: Props) {
  // Tags ordered by frequency, so the exercises you measure most come first
  const tags = useMemo(() => {
    const counts = new Map<string, number>();
    for (const r of recordings) {
      if (r.tag) counts.set(r.tag, (counts.get(r.tag) ?? 0) + 1);
    }
    return [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([tag]) => tag);
  }, [recordings]);

  const hasSides = recordings.some((r) => r.side !== "");

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
      <div
        style={{
          fontSize: 9,
          color: "#6E6E73",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 10,
        }}
      >
        Peak Force Trend
      </div>

      {tags.length > 0 && (
        <div
          style={{ display: "flex", gap: 5, flexWrap: "wrap", marginBottom: 8 }}
        >
          <TagChip
            label="All"
            active={selectedTag === null}
            onClick={() => onSelectTag(null)}
          />
          {tags.map((t) => (
            <TagChip
              key={t}
              label={t}
              active={selectedTag === t}
              onClick={() => onSelectTag(selectedTag === t ? null : t)}
            />
          ))}
        </div>
      )}
      {hasSides && (
        <div
          style={{ display: "flex", gap: 5, flexWrap: "wrap", marginBottom: 12 }}
        >
          <TagChip
            label="Both sides"
            active={selectedSide === null}
            onClick={() => onSelectSide(null)}
          />
          {(["left", "right"] as const).map((s) => (
            <TagChip
              key={s}
              label={s === "left" ? "Left" : "Right"}
              active={selectedSide === s}
              onClick={() => onSelectSide(selectedSide === s ? null : s)}
            />
          ))}
        </div>
      )}

      {stats && sorted.length >= 2 ? (
        <>
          <div
            className="grid-2"
            style={{ gridTemplateColumns: "1fr 1fr 1fr", marginBottom: 10 }}
          >
            <div>
              <div style={{ fontSize: 9, color: "#6E6E73" }}>Best</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: 16,
                  color: "#FFB800",
                }}
              >
                {stats.bestPeak.toFixed(1)}
              </div>
            </div>
            <div>
              <div style={{ fontSize: 9, color: "#6E6E73" }}>Last</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: 16,
                  color: "#F5F5F7",
                }}
              >
                {stats.lastPeak.toFixed(1)}
              </div>
            </div>
            <div>
              <div style={{ fontSize: 9, color: "#6E6E73" }}>vs 30d avg</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: 16,
                  color:
                    stats.delta === null
                      ? "#6E6E73"
                      : stats.delta >= 0
                        ? "#34C759"
                        : "#FF453A",
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
        <div style={{ fontSize: 11, color: "#8E8E93", padding: "12px 0" }}>
          Not enough recordings with this tag yet.
        </div>
      )}
    </div>
  );
}
