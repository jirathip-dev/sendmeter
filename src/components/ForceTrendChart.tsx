import { useState } from "react";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import { useChartId } from "../hooks/useChartId";
import { dateStr } from "../lib/dates";
import {
  dailyBoxStats,
  hitWidthsPx,
  trendChartRecordings,
  type DailyBoxStats,
} from "../lib/forceTrend";
import { fetchWeightHistory } from "../lib/repo";
import BoxChip from "./BoxChip";
import SvgChartTooltip from "./SvgChartTooltip";
import ChartDefs from "./ChartDefs";
import { chartColor, chartGradientUrl } from "../lib/chartTheme";
import type { ForceCapacityModality, TindeqRecordingMeta, TindeqSide } from "../types";

interface Props {
  recordings: TindeqRecordingMeta[];
  /// Follows the tab's GLOBAL exercise/side (set in the Exercise card) —
  /// this chart has no filters of its own.
  selectedTag: string | null;
  selectedSide: TindeqSide | null;
  modality: ForceCapacityModality;
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

/// Daily aggregation: each training day's box-plot stats (issue #145) — the
/// chart scatters EVERY rep faintly underneath, then draws a Tukey box per
/// day (quartiles/whiskers/outliers via `dailyBoxStats`/`boxStats`), with
/// the PR day's median tick called out in gold — spread stays visible, the
/// day's distribution reads off the box, and stats derive from daily bests.
interface TrendPoint {
  id: string;
  recordedAt: string;
  val: number;
}

const MIN_BOX_W = 4;
const MAX_BOX_W = 16;
const MAX_OUTLIER_DOTS = 8;

/// Thins a day's outliers down to at most `max` rendered dots. Adapted from
/// `RepBoxPlotChart.tsx`'s `pickOutlierDots` (not imported — that copy lives
/// in an index-based per-rep chart, this one is time-scaled per-day, and the
/// box widths/caps here are smaller): quantize to the pixel-y grid first
/// (values landing on the same dot are redundant), then if still over the
/// cap, take an evenly spaced sample across the sorted survivors.
function pickOutlierDots(outliers: number[], py: (v: number) => number, max: number): number[] {
  const byPixel = new Map<number, number>();
  for (const v of outliers) {
    const pixel = Math.round(py(v));
    if (!byPixel.has(pixel)) byPixel.set(pixel, v);
  }
  const values = [...byPixel.values()].sort((a, b) => a - b);
  if (values.length <= max) return values;
  const picked: number[] = [];
  const step = (values.length - 1) / (max - 1);
  for (let i = 0; i < max; i++) {
    picked.push(values[Math.round(i * step)]!);
  }
  return [...new Set(picked)];
}

function Chart({
  days,
  all,
  unit,
}: {
  days: DailyBoxStats[];
  all: TrendPoint[];
  unit: string;
}) {
  const [hovered, hoverProps] = useChartHover<number>();
  const chartId = useChartId("force-trend");
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

  // Box width cap: the chart is time-scaled (not evenly spaced like
  // RepBoxPlotChart's index-based layout), so the width can't come from a
  // fixed band — derive it from the tightest pixel gap between adjacent
  // days' x positions instead, so close-together training days don't get
  // overlapping boxes.
  const dayXs = days.map((d) => px(d.t)).sort((a, b) => a - b);
  let minGapPx = Infinity;
  for (let i = 1; i < dayXs.length; i++) {
    minGapPx = Math.min(minGapPx, dayXs[i]! - dayXs[i - 1]!);
  }
  const boxW = Math.min(
    MAX_BOX_W,
    Math.max(MIN_BOX_W, (Number.isFinite(minGapPx) ? minGapPx : MAX_BOX_W) * 0.7),
  );
  const capW = boxW * 0.5;
  // Hit target can be a bit wider than the visible box for easier tapping,
  // but still capped so it doesn't swallow a neighboring day's hits. Each
  // day gets its OWN width from its nearest-neighbor gap (`hitWidthsPx`,
  // `days` order == x-ascending order — see its own comment) — a global
  // min-gap-derived width used to collapse every day's hit target whenever
  // any single pair of days landed close together (issue #145 revision).
  const hitWidths = hitWidthsPx(
    days.map((d) => px(d.t)),
    boxW,
    MIN_BOX_W,
  );

  return (
    <svg
      className="chart-scrub"
      role="img"
      aria-label={`Force trend distribution by training day in ${unit}`}
      viewBox={`0 0 ${W} ${H}`}
      style={{ width: "100%", display: "block" }}
    >
      <ChartDefs instanceId={chartId} />
      {/* y-axis gridlines */}
      {yTicks.map((v, i) => (
        <g key={i}>
          <line
            x1={PAD.left}
            y1={py(v)}
            x2={W - PAD.right}
            y2={py(v)}
            style={{ stroke: chartColor("grid") }}
            strokeWidth={1}
          />
          <text
            x={2}
            y={py(v) + (i === 0 ? -2 : i === yTicks.length - 1 ? 7 : 2.5)}
            fontSize={7.5}
              style={{ fill: chartColor("axis") }}
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
          fill={chartColor("forceSecondary")}
          opacity={0.3}
        />
      ))}
      {/* …with each day's box-and-whisker distribution on top, PR day's
          median tick called out in gold (mirrors RepBoxPlotChart's
          session-best-rep callout in History). */}
      {days.map((d, i) => {
        const s = d.stats;
        const cx = px(d.t);
        const isPr = i === prIdx;
        const isHovered = hovered === i;
        const color = isPr ? chartColor("caution") : chartColor("force");
        const outlierDots = pickOutlierDots(s.outliers, py, MAX_OUTLIER_DOTS);
        return (
          <g key={d.date} opacity={hovered !== null && !isHovered ? 0.55 : 1}>
            {/* Whisker + caps */}
            <line
              x1={cx}
              y1={py(s.whiskerLo)}
              x2={cx}
              y2={py(s.whiskerHi)}
              stroke={chartColor("axis")}
              strokeOpacity={0.7}
              strokeWidth={1}
              vectorEffect="non-scaling-stroke"
            />
            <line
              x1={cx - capW / 2}
              y1={py(s.whiskerLo)}
              x2={cx + capW / 2}
              y2={py(s.whiskerLo)}
              stroke={chartColor("axis")}
              strokeOpacity={0.7}
              strokeWidth={1}
              vectorEffect="non-scaling-stroke"
            />
            <line
              x1={cx - capW / 2}
              y1={py(s.whiskerHi)}
              x2={cx + capW / 2}
              y2={py(s.whiskerHi)}
              stroke={chartColor("axis")}
              strokeOpacity={0.7}
              strokeWidth={1}
              vectorEffect="non-scaling-stroke"
            />
            {/* Q1–Q3 box */}
            <rect
              x={cx - boxW / 2}
              y={py(s.q3)}
              width={boxW}
              height={Math.max(0.5, py(s.q1) - py(s.q3))}
              rx={2}
              fill={isPr ? color : chartGradientUrl(chartId, "force-area")}
              fillOpacity={isHovered ? 0.32 : 0.22}
              stroke={color}
              strokeWidth={isHovered ? 1.5 : 1}
              vectorEffect="non-scaling-stroke"
            />
            {/* Median tick — PR day in gold, same as the old best-dot */}
            <line
              x1={cx - boxW / 2}
              y1={py(s.median)}
              x2={cx + boxW / 2}
              y2={py(s.median)}
              stroke={color}
              strokeWidth={2}
              strokeLinecap="round"
              vectorEffect="non-scaling-stroke"
            />
            {/* Outlier dots (thinned) — texture, not noise */}
            {outlierDots.map((v, oi) => (
              <circle
                key={oi}
                cx={cx}
                cy={py(v)}
                r={1.3}
                fill="none"
                stroke={chartColor("axis")}
                strokeOpacity={0.6}
                strokeWidth={1}
                vectorEffect="non-scaling-stroke"
              />
            ))}
            {/* Hit target: full chart height so a scrub anywhere over this
                day's column selects it. Width is per-day (see `hitWidths`
                above), not a single dataset-wide value. */}
            <rect
              x={cx - hitWidths[i]! / 2}
              y={PAD.top}
              width={hitWidths[i]!}
              height={H - PAD.top - PAD.bottom}
              fill="transparent"
              style={{ cursor: "pointer" }}
              {...hoverProps(i)}
            />
          </g>
        );
      })}
      {days[prIdx] && (
        <text
          x={Math.min(px(days[prIdx]!.t), W - 18)}
          y={Math.max(py(days[prIdx]!.best) - 8, 8)}
          fontSize={8}
          fill={chartColor("caution")}
        >
          PR
        </text>
      )}
      <text x={PAD.left} y={H - 4} fontSize={8} style={{ fill: chartColor("axis") }}>
        {fmtDate(tMin)}
      </text>
      <text
        x={W - PAD.right}
        y={H - 4}
        fontSize={8}
        style={{ fill: chartColor("axis") }}
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
          style={{ stroke: chartColor("axis") }}
          strokeDasharray="2 2"
          strokeWidth={1}
        />
      )}
      {hoveredD && hovered !== null && (
        <SvgChartTooltip
          x={px(hoveredD.t)}
          y={py(hoveredD.stats.median)}
          viewW={W}
          viewH={H}
          lines={[
            fmtDate(hoveredD.t),
            `median ${hoveredD.stats.median.toFixed(1)} ${unit}`,
            `Q1–Q3 ${hoveredD.stats.q1.toFixed(1)}–${hoveredD.stats.q3.toFixed(1)} ${unit} · ${hoveredD.count} rep${hoveredD.count === 1 ? "" : "s"}`,
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
  modality,
}: Props) {
  const [mode, setMode] = useState<"kg" | "bw">(() =>
    localStorage.getItem(MODE_KEY) === "bw" ? "bw" : "kg",
  );
  const weights = useCancellableFetch(fetchWeightHistory, [], 0);

  const filtered = trendChartRecordings(recordings, selectedTag, selectedSide, modality);
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
        ? (r.peakKg! / weightOn(weights, dateStr(new Date(r.recordedAt)))) * 100
        : r.peakKg!,
    }));
  const days = dailyBoxStats(sorted);

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
          {modality === "reverse_action" ? "Reverse Action" : "Static"} Peak Force Trend
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
