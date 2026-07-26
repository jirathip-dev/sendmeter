import { hrRecoveryBpm } from "../lib/workoutStats";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import {
  WORKOUT_CHART_PAD as PAD,
  attemptWindows,
  fmtMinSec,
  workoutXTicks,
} from "../lib/workoutChartAxis";
import SvgChartTooltip from "./SvgChartTooltip";
import type { WorkoutAttempt, WorkoutHrSample, WorkoutSource } from "../types";

interface Props {
  /// Workout start (ISO) — attempt windows are placed relative to it.
  startedAt: string;
  attempts: WorkoutAttempt[];
  /// The workout-level 1Hz trace, fetched by the parent so every chart in the
  /// stack shares one x domain (null while loading / when none was kept).
  samples: WorkoutHrSample[] | null;
  /// Shared x domain (seconds) and viewBox width — see workoutChartAxis.
  tMax: number;
  width: number;
  /// Draw the m:ss labels (the bottom-most chart of the stack carries them).
  showTimeAxis: boolean;
  /// Provenance — a watch workout is expected to have an HR trace, so if it's
  /// missing we show a "still syncing" note (the watch uploads it in the
  /// background); a phone workout never has one, so we render nothing.
  source: WorkoutSource;
}

const H = 90;

/// Continuous HR timeline for a whole workout (SL-42): one line/area over
/// the workout-level 1Hz trace, each boulder attempt shaded as a segment
/// (manual attempts in the warning color), rest = the unshaded gaps.
/// Renders nothing when the workout kept no raw trace (older builds, phone
/// workouts without HR).
export default function WorkoutHrChart({
  startedAt,
  attempts,
  samples,
  tMax,
  width: W,
  showTimeAxis,
  source,
}: Props) {
  const [hovered, hoverProps] = useChartHover<number>();

  const hrSamples = samples?.filter((s) => s.hr !== null) ?? [];
  const hrs = hrSamples.map((s) => s.hr!);
  const hrMin = hrs.length ? Math.min(...hrs) : 0;
  const hrMax = hrs.length ? Math.max(...hrs) : 1;
  // Pad the y-domain so the line doesn't kiss the frame edges.
  const yPad = Math.max(3, (hrMax - hrMin) * 0.1);
  const { x: px, y: py } = useSvgScale(W, H, PAD, 0, tMax, hrMin - yPad, hrMax + yPad);

  if (!samples || hrSamples.length < 2) {
    // A watch workout is expected to have a trace — if it's not here yet it's
    // still uploading from the watch (background sync), so reassure rather than
    // show nothing. Phone workouts never have a trace, so render nothing.
    return source === "watch" ? (
      <div
        style={{
          fontSize: "var(--t-2xs)",
          color: "var(--ink-faint)",
          marginTop: 8,
          display: "flex",
          alignItems: "center",
          gap: 6,
        }}
      >
        <span aria-hidden="true">⟳</span>
        Heart-rate trace still syncing from your watch…
      </div>
    ) : null;
  }

  // Contiguous non-null HR runs → one line + area sub-path each (a null gap
  // means the sensor lagged; drawing across it would invent data).
  const runs: WorkoutHrSample[][] = [];
  let run: WorkoutHrSample[] = [];
  for (const s of samples) {
    if (s.hr === null) {
      if (run.length) runs.push(run);
      run = [];
    } else {
      run.push(s);
    }
  }
  if (run.length) runs.push(run);

  const baseline = H - PAD.bottom;
  const areaPath = (r: WorkoutHrSample[]) =>
    `M ${px(r[0]!.t).toFixed(1)},${baseline} ` +
    r.map((s) => `L ${px(s.t).toFixed(1)},${py(s.hr!).toFixed(1)}`).join(" ") +
    ` L ${px(r[r.length - 1]!.t).toFixed(1)},${baseline} Z`;
  const linePoints = (r: WorkoutHrSample[]) =>
    r.map((s) => `${px(s.t).toFixed(1)},${py(s.hr!).toFixed(1)}`).join(" ");

  // Attempt windows in trace seconds (shared with the effort chart below).
  const windows = attemptWindows(startedAt, attempts);

  // Downsampled hover targets (~50 across the trace).
  const hoverStep = Math.max(1, Math.floor(hrSamples.length / 50));
  const hoverIndices: number[] = [];
  for (let i = 0; i < hrSamples.length; i += hoverStep) hoverIndices.push(i);
  const hoveredSample = hovered !== null ? hrSamples[hovered] : undefined;
  const hoveredWindow =
    hoveredSample &&
    windows.find((w) => hoveredSample.t >= w.start && hoveredSample.t <= w.end);

  const yTicks = [hrMin, (hrMin + hrMax) / 2, hrMax];
  const xTicks = workoutXTicks(tMax);

  // HR-recovery fatigue metric (SL-25): mean bpm the heart drops in the 60s
  // after each climb — bigger = fresher between attempts. Computed from the
  // trace already loaded here (no extra fetch).
  const recoveryBpm = hrRecoveryBpm(samples, startedAt, attempts);

  return (
    <div style={{ marginTop: 12 }}>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
          marginBottom: 4,
        }}
      >
        <span className="label-eyebrow">Heart rate · climbs vs rest</span>
        <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)" }}>
          <span style={{ color: "var(--success)" }}>■</span> climb
          {windows.some((w) => w.manual) && (
            <>
              {" "}
              <span style={{ color: "var(--warning)" }}>■</span> manual
            </>
          )}{" "}
          · gaps = rest
        </span>
      </div>
      {recoveryBpm !== null && (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", marginBottom: 4 }}>
          HR recovery{" "}
          <span style={{ color: "var(--danger)", fontWeight: 700 }}>
            −{Math.round(recoveryBpm)} bpm
          </span>{" "}
          in the 60s after a climb, on average
        </div>
      )}
      <div style={{ width: "100%" }}>
        <svg className="chart-scrub" viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
          {/* Attempt segments (rest stays unshaded) */}
          {windows.map((w, i) => (
            <rect
              key={i}
              x={px(w.start)}
              width={Math.max(1.5, px(w.end) - px(w.start))}
              y={PAD.top}
              height={baseline - PAD.top}
              fill={w.manual ? "var(--warning)" : "var(--success)"}
              opacity="0.12"
            />
          ))}
          {/* Gridlines + y labels */}
          {yTicks.map((v, i) => (
            <g key={`y-${i}`}>
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
                y={py(v) + 2.5}
                fontSize={7.5}
                style={{ fill: "var(--ink-faint)" }}
              >
                {Math.round(v)}
                {i === yTicks.length - 1 ? "bpm" : ""}
              </text>
            </g>
          ))}
          {showTimeAxis &&
            xTicks.map((t, i) => (
              <text
                key={`x-${i}`}
                x={px(t)}
                y={H - 3}
                fontSize={7.5}
                style={{ fill: "var(--ink-faint)" }}
                textAnchor={i === 0 ? "start" : i === xTicks.length - 1 ? "end" : "middle"}
              >
                {fmtMinSec(t)}
              </text>
            ))}
          {/* HR area + line, split at sensor gaps */}
          {runs.map((r, i) =>
            r.length < 2 ? null : (
              <g key={i}>
                <path d={areaPath(r)} fill="#5B5FC7" opacity="0.12" />
                <polyline
                  points={linePoints(r)}
                  fill="none"
                  stroke="#5B5FC7"
                  strokeWidth="1.5"
                  vectorEffect="non-scaling-stroke"
                />
              </g>
            ),
          )}
          {/* Hover targets */}
          {hoverIndices.map((i) => (
            <circle
              key={i}
              cx={px(hrSamples[i]!.t)}
              cy={py(hrSamples[i]!.hr!)}
              r={8}
              fill="transparent"
              style={{ cursor: "pointer" }}
              {...hoverProps(i)}
            />
          ))}
          {hovered !== null && hoveredSample && (
            <>
              <line
                x1={px(hoveredSample.t)}
                y1={PAD.top}
                x2={px(hoveredSample.t)}
                y2={baseline}
                style={{ stroke: "var(--ink-faint)" }}
                strokeDasharray="2 2"
                strokeWidth={1}
              />
              <circle
                cx={px(hoveredSample.t)}
                cy={py(hoveredSample.hr!)}
                r={3}
                fill="#5B5FC7"
              />
              <SvgChartTooltip
                x={px(hoveredSample.t)}
                y={py(hoveredSample.hr!)}
                viewW={W}
                viewH={H}
                lines={[
                  fmtMinSec(hoveredSample.t),
                  `${Math.round(hoveredSample.hr!)} bpm`,
                  hoveredWindow ? (hoveredWindow.manual ? "manual climb" : "climbing") : "rest",
                ]}
              />
            </>
          )}
        </svg>
      </div>
    </div>
  );
}
