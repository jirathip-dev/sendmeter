import { useState } from "react";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import { fetchWeightHistory } from "../lib/repo";
import BoxChip from "./BoxChip";
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

const MODE_KEY = "sendmeter:trend-mode";

/// SL-88: the trend can plot absolute kg or strength-to-weight (% of body
/// weight). Weigh-ins are sparse, so each rep uses the last weight on/before
/// its date (forward fill); reps older than the first weigh-in fall back to
/// that first weight.
function weightOn(weights: { date: string; kg: number }[], date: string): number {
  let w = weights[0]!.kg;
  for (const entry of weights) {
    if (entry.date > date) break;
    w = entry.kg;
  }
  return w;
}

/// Daily aggregation: each training day's best peak + rep count. The chart
/// scatters EVERY rep faintly and highlights the daily bests (local maxima)
/// with the global max in gold — spread stays visible, trend reads off the
/// highlighted points, and stats derive from daily bests.
interface DailyBest {
  date: string; // YYYY-MM-DD
  t: number; // ms of the day's best rep
  best: number;
  count: number;
}

interface TrendPoint {
  id: string;
  recordedAt: string;
  val: number;
}

function dailyBests(sorted: TrendPoint[]): DailyBest[] {
  const byDate = new Map<string, DailyBest>();
  for (const r of sorted) {
    const date = r.recordedAt.slice(0, 10);
    const cur = byDate.get(date);
    if (!cur) {
      byDate.set(date, { date, t: Date.parse(r.recordedAt), best: r.val, count: 1 });
    } else {
      cur.count += 1;
      if (r.val > cur.best) {
        cur.best = r.val;
        cur.t = Date.parse(r.recordedAt);
      }
    }
  }
  return [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date));
}

function Chart({
  days,
  all,
  unit,
}: {
  days: DailyBest[];
  all: TrendPoint[];
  unit: string;
}) {
  const [hovered, hoverProps] = useChartHover<number>();
  const allTs = all.map((r) => Date.parse(r.recordedAt));
  const tMin = Math.min(days[0]!.t, allTs[0] ?? days[0]!.t);
  const tMax = Math.max(days[days.length - 1]!.t, tMin + 1);
  // The y-domain covers EVERY rep, not just the bests — the scatter shows
  // the whole session's spread.
  const allPeaks = all.map((r) => r.val);
  const yMin = Math.min(...allPeaks) * 0.9;
  const yMax = Math.max(...allPeaks) * 1.08 || 1;

  const { x: px, y: py } = useSvgScale(W, H, PAD, tMin, tMax, yMin, yMax);

  // PR = max daily best; ties → most recent
  let prIdx = 0;
  days.forEach((d, i) => {
    if (d.best >= days[prIdx]!.best) prIdx = i;
  });

  const fmtDate = (t: number) => {
    const d = new Date(t);
    return `${d.getMonth() + 1}/${d.getDate()}`;
  };

  const hoveredD = hovered !== null ? days[hovered] : undefined;
  const yMid = (yMin + yMax) / 2;
  const yTicks = [yMin, yMid, yMax];

  return (
    <svg className="chart-scrub" viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
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
            {i === yTicks.length - 1 ? unit : ""}
          </text>
        </g>
      ))}
      {/* Every rep as a faint scatter — the day's spread stays visible… */}
      {all.map((r, i) => (
        <circle
          key={r.id}
          cx={px(allTs[i]!)}
          cy={py(r.val)}
          r={1.8}
          fill="#7B83EB"
          opacity={0.3}
        />
      ))}
      {/* …with each day's best (local maximum) highlighted, PR in gold. */}
      {days.map((d, i) => (
        <circle
          key={d.date}
          cx={px(d.t)}
          cy={py(d.best)}
          r={hovered === i ? (i === prIdx ? 6 : 5) : i === prIdx ? 4.5 : 3.5}
          fill={i === prIdx ? "#DDB13A" : "#5B5FC7"}
          style={{ cursor: "pointer", transition: "r 0.1s" }}
          {...hoverProps(i)}
        />
      ))}
      {days[prIdx] && (
        <text
          x={Math.min(px(days[prIdx]!.t), W - 18)}
          y={Math.max(py(days[prIdx]!.best) - 8, 8)}
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
      {hovered !== null && hoveredD && (
        <line
          x1={px(hoveredD.t)}
          y1={PAD.top}
          x2={px(hoveredD.t)}
          y2={H - PAD.bottom}
          style={{ stroke: "var(--ink-faint)" }}
          strokeDasharray="2 2"
          strokeWidth={1}
        />
      )}
      {hoveredD && hovered !== null && (
        <SvgChartTooltip
          x={px(hoveredD.t)}
          y={py(hoveredD.best)}
          viewW={W}
          viewH={H}
          lines={[
            fmtDate(hoveredD.t),
            `best ${hoveredD.best.toFixed(1)} ${unit} · ${hoveredD.count} rep${hoveredD.count === 1 ? "" : "s"}`,
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
  const [mode, setMode] = useState<"kg" | "bw">(() =>
    localStorage.getItem(MODE_KEY) === "bw" ? "bw" : "kg",
  );
  const weights = useCancellableFetch(fetchWeightHistory, [], 0);

  const filtered = recordings.filter(
    (r) =>
      (selectedTag === null || r.tag === selectedTag) &&
      (selectedSide === null || r.side === selectedSide),
  );
  if (recordings.length < 2) return null;

  // No weigh-ins yet → the %BW mode has nothing to divide by.
  const ratioMode = mode === "bw" && weights.length > 0;
  const unit = ratioMode ? "%BW" : "kg";

  const sorted: TrendPoint[] = [...filtered]
    .sort((a, b) => a.recordedAt.localeCompare(b.recordedAt))
    .map((r) => ({
      id: r.id,
      recordedAt: r.recordedAt,
      val: ratioMode
        ? (r.peakKg / weightOn(weights, r.recordedAt.slice(0, 10))) * 100
        : r.peakKg,
    }));
  const days = dailyBests(sorted);

  function pick(next: "kg" | "bw") {
    setMode(next);
    localStorage.setItem(MODE_KEY, next);
  }

  // Stats over DAILY BESTS — a submax endurance day no longer drags "Last"
  // or the 30d comparison around; each day is represented by its best pull.
  const best = days.length ? Math.max(...days.map((d) => d.best)) : 0;
  const lastDay = days[days.length - 1];
  const priorWindow = lastDay
    ? days.filter(
        (d) =>
          d.date !== lastDay.date &&
          lastDay.t - d.t <= 30 * 86_400_000 &&
          lastDay.t - d.t > 0,
      )
    : [];
  const delta =
    lastDay && priorWindow.length
      ? lastDay.best -
        priorWindow.reduce((s, d) => s + d.best, 0) / priorWindow.length
      : null;

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          marginBottom: 10,
        }}
      >
        <div className="label-eyebrow">
          Peak Force Trend
          {selectedTag && (
            <span style={{ color: "var(--ink-faint)" }}>
              {" "}
              · {selectedTag}
              {selectedSide ? ` · ${selectedSide}` : ""}
            </span>
          )}
        </div>
        {weights.length > 0 && (
          <div style={{ display: "flex", gap: 4 }}>
            <BoxChip label="kg" small active={mode === "kg"} onClick={() => pick("kg")} />
            <BoxChip label="%BW" small active={mode === "bw"} onClick={() => pick("bw")} />
          </div>
        )}
      </div>

      {days.length >= 2 ? (
        <>
          <div
            className="grid-2"
            style={{ gridTemplateColumns: "1fr 1fr 1fr", marginBottom: 10 }}
          >
            <div>
              <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>Best</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: "var(--t-md)",
                  color: "var(--warning)",
                }}
              >
                {best.toFixed(1)}
              </div>
            </div>
            <div>
              <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>Last day</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: "var(--t-md)",
                  color: "var(--ink)",
                }}
              >
                {lastDay ? lastDay.best.toFixed(1) : "—"}
              </div>
            </div>
            <div>
              <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>vs 30d avg</div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  fontSize: "var(--t-md)",
                  color:
                    delta === null
                      ? "var(--ink-muted)"
                      : delta >= 0
                        ? "var(--success)"
                        : "var(--danger)",
                }}
              >
                {delta === null
                  ? "—"
                  : `${delta >= 0 ? "+" : ""}${delta.toFixed(1)}`}
              </div>
            </div>
          </div>
          <Chart days={days} all={sorted} unit={unit} />
        </>
      ) : (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", padding: "12px 0" }}>
          Not enough training days with this tag yet.
        </div>
      )}
    </div>
  );
}
