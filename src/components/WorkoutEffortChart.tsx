import { useChartHover } from "../hooks/useChartHover";
import { useChartId } from "../hooks/useChartId";
import { useSvgScale } from "../hooks/useSvgScale";
import {
  WORKOUT_CHART_PAD as PAD,
  attemptWindows,
  fmtMinSec,
  workoutXTicks,
} from "../lib/workoutChartAxis";
import SvgChartTooltip from "./SvgChartTooltip";
import ChartDefs from "./ChartDefs";
import { CHART_TOUCH_TARGET_UNITS, chartColor } from "../lib/chartTheme";
import type { WorkoutAttempt } from "../types";

interface Props {
  /// Workout start (ISO) — attempts are placed relative to it.
  startedAt: string;
  attempts: WorkoutAttempt[];
  /// Shared x domain (seconds) — same value the HR chart above plots into.
  tMax: number;
  /// Shared viewBox width, so PAD maps to the same fraction in both charts.
  width: number;
  /// Draw the m:ss labels (the bottom-most chart of the stack carries them).
  showTimeAxis: boolean;
}

const H = 70;
/// Effort scores are a 0–10 scale.
const EFFORT_MAX = 10;

/// Per-attempt effort, plotted on the *workout timeline* rather than one
/// even-width bar per attempt (SL-183) — so an x pixel here is the same
/// instant as in the HR chart stacked above it, and each bar sits under the
/// climb segment it belongs to.
export default function WorkoutEffortChart({
  startedAt,
  attempts,
  tMax,
  width: W,
  showTimeAxis,
}: Props) {
  const [hovered, hoverProps] = useChartHover<number>();
  const chartId = useChartId("workout-effort");
  const { x: px, y: py } = useSvgScale(W, H, PAD, 0, tMax, 0, EFFORT_MAX);

  const baseline = H - PAD.bottom;
  const windows = attemptWindows(startedAt, attempts);
  const bars = windows.map((w, i) => {
    const a = attempts[i]!;
    const x0 = px(w.start);
    // A short climb in a long workout is only a pixel or two wide — keep a
    // floor so every attempt stays visible and tappable.
    const barW = Math.max(3, px(w.end) - x0);
    const top = py(Math.min(EFFORT_MAX, a.effortScore ?? 0));
    return {
      i,
      a,
      x: x0,
      w: barW,
      top: Math.min(top, baseline - 3),
      manual: w.manual,
      cx: x0 + barW / 2,
    };
  });

  const yTicks = [0, EFFORT_MAX];
  const hoveredBar = hovered !== null ? bars[hovered] : undefined;

  return (
    <svg
      className="chart-scrub"
      role="group"
      aria-label="Workout attempt effort timeline"
      viewBox={`0 0 ${W} ${H}`}
      style={{ width: "100%", display: "block" }}
    >
      <ChartDefs instanceId={chartId} />
      {/* Gridlines + y labels (same gutter as the HR chart) */}
      {yTicks.map((v, i) => (
        <g key={`y-${i}`}>
          <line
            x1={PAD.left}
            y1={py(v)}
            x2={W - PAD.right}
            y2={py(v)}
            style={{ stroke: chartColor("grid") }}
            strokeWidth={1}
          />
          <text x={2} y={py(v) + 2.5} fontSize={7.5} style={{ fill: chartColor("axis") }}>
            {v}
            {i === yTicks.length - 1 ? "eff" : ""}
          </text>
        </g>
      ))}
      {showTimeAxis &&
        workoutXTicks(tMax).map((t, i, all) => (
          <text
            key={`x-${i}`}
            x={px(t)}
            y={H - 3}
            fontSize={7.5}
            style={{ fill: chartColor("axis") }}
            textAnchor={i === 0 ? "start" : i === all.length - 1 ? "end" : "middle"}
          >
            {fmtMinSec(t)}
          </text>
        ))}
      {bars.map((b) => (
        <rect
          key={`bar-${b.i}`}
          x={b.x}
          y={b.top}
          width={b.w}
          height={baseline - b.top}
          rx={1.5}
          fill={b.manual ? chartColor("caution") : chartColor("optimal")}
          opacity={hovered === null || hovered === b.i ? 1 : 0.5}
          stroke={hovered === b.i ? "var(--ink)" : "none"}
          strokeWidth={hovered === b.i ? 1 : 0}
        />
      ))}
      {/* Hit areas — 44 viewBox units keeps short climbs tappable without
          enlarging the visible bars. Pointer scrubbing remains on this layer. */}
      {bars.map((b) => (
        <rect
          key={`hit-${b.i}`}
          x={b.cx - Math.max(b.w, CHART_TOUCH_TARGET_UNITS) / 2}
          y={PAD.top}
          width={Math.max(b.w, CHART_TOUCH_TARGET_UNITS)}
          height={baseline - PAD.top}
          fill="transparent"
          role="button"
          tabIndex={0}
          aria-label={`Attempt ${b.i + 1}${b.a.effortScore != null ? `, effort ${b.a.effortScore.toFixed(1)}` : ""}`}
          style={{ cursor: "pointer" }}
          {...hoverProps(b.i)}
        />
      ))}
      {hoveredBar && (
        <SvgChartTooltip
          x={hoveredBar.cx}
          y={hoveredBar.top}
          viewW={W}
          viewH={H}
          lines={[
            `Attempt ${hoveredBar.i + 1}`,
            ...(hoveredBar.a.effortScore != null
              ? [`Effort ${hoveredBar.a.effortScore.toFixed(1)}`]
              : []),
            `${Math.round(hoveredBar.a.durationS)}s · +${hoveredBar.a.elevationGainM.toFixed(1)}m`,
            ...(hoveredBar.a.avgHr != null
              ? [
                  `avg ${Math.round(hoveredBar.a.avgHr)}${
                    hoveredBar.a.peakHr != null
                      ? ` / peak ${Math.round(hoveredBar.a.peakHr)}`
                      : ""
                  } bpm`,
                ]
              : []),
          ]}
        />
      )}
    </svg>
  );
}
