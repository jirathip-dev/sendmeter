import { useSvgScale } from "../hooks/useSvgScale";
import { parseLocalDate, relativeDayLabel, today } from "../lib/dates";
import {
  PROJECTION_DAYS,
  projectAcwr,
  type AcwrProjection,
  type ProjectedDay,
} from "../lib/acwrProjection";
import { ewmaLoadState, getACWRStatus } from "../lib/metrics";
import { ZONE_COLORS } from "../lib/readinessZones";
import type { HealthMetric, Phase, Session } from "../types";
import InfoDot from "./InfoDot";

const W = 300;
// The extra height belongs entirely to the two-row axis: H - PAD.bottom
// remains 80, so the plot itself keeps its original dimensions.
const H = 108;
const PAD = { top: 10, right: 10, bottom: 28, left: 30 };
const CROSSING_LABEL_HALF_WIDTH = 12;

interface Props {
  phase: Phase;
  sessions: Session[];
  /// Most recent health row (may be older than today, may be absent). Passed
  /// down rather than fetched again — Dashboard already has it.
  latestReadiness: HealthMetric | null;
}

/// The plain-language version of the projection: what leaves the band, when.
function headline(p: AcwrProjection, phaseName: string): string {
  const todayFit = p.days[0]!.fit;
  if (p.band === null || todayFit === null) {
    return "No phase band to project against.";
  }
  const band = `${phaseName} band (${p.band.low.toFixed(1)}–${p.band.high.toFixed(1)})`;
  if (todayFit === "above") {
    const back = p.entersBand ? `back inside ${relativeDayLabel(p.entersBand.date)}` : "still above it in a week";
    const out = p.fallsBelow ? `, then under it ${relativeDayLabel(p.fallsBelow.date)}` : "";
    return `Above your ${band} — resting brings you ${back}${out}.`;
  }
  if (todayFit === "below") {
    return `Already below your ${band}, and resting keeps it falling.`;
  }
  return p.fallsBelow
    ? `Drops below your ${band} ${relativeDayLabel(p.fallsBelow.date)}.`
    : `Stays inside your ${band} all week, even with no training.`;
}

export function Chart({ p, todayColor }: { p: AcwrProjection; todayColor: string }) {
  const values = p.days.map((d) => d.acwr);
  const lo = Math.min(...values, p.band?.low ?? Infinity);
  const hi = Math.max(...values, p.band?.high ?? -Infinity);
  // A little headroom either side so the band edges and the today dot never
  // sit flush against the frame.
  const pad = Math.max((hi - lo) * 0.12, 0.05);
  const { x: px, y: py } = useSvgScale(W, H, PAD, 0, PROJECTION_DAYS, lo - pad, hi + pad);

  const point = (d: ProjectedDay) => `${px(d.dayOffset)},${py(d.acwr)}`;
  const crossing = p.fallsBelow;
  const crossingLabelX = crossing
    ? Math.min(px(crossing.dayOffset), W - PAD.right - CROSSING_LABEL_HALF_WIDTH)
    : 0;

  return (
    <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }} aria-hidden="true">
      {p.band !== null && (
        <>
          {/* The phase's target band — deliberately the phase band, not the
              universal 0.8–1.3 risk zone the ACWR card's track draws. */}
          <rect
            x={PAD.left}
            y={py(p.band.high)}
            width={W - PAD.left - PAD.right}
            height={Math.max(py(p.band.low) - py(p.band.high), 1)}
            fill="var(--success)"
            opacity={0.14}
          />
          {[p.band.high, p.band.low].map((v) => (
            <g key={v}>
              <line
                x1={PAD.left}
                y1={py(v)}
                x2={W - PAD.right}
                y2={py(v)}
                stroke="var(--success)"
                strokeWidth={1}
                opacity={0.5}
              />
              <text
                x={PAD.left - 5}
                y={py(v) + 3}
                textAnchor="end"
                fontSize={9}
                fill="var(--ink-faint)"
              >
                {v.toFixed(1)}
              </text>
            </g>
          ))}
        </>
      )}

      {/* Dashed on purpose: none of this is measured data. */}
      <polyline
        points={p.days.map(point).join(" ")}
        fill="none"
        stroke="var(--ink-muted)"
        strokeWidth={2}
        strokeDasharray="3 4"
        strokeLinecap="round"
      />

      {crossing && (
        <line
          x1={px(crossing.dayOffset)}
          y1={PAD.top}
          x2={px(crossing.dayOffset)}
          y2={H - PAD.bottom}
          stroke="var(--ink-faint)"
          strokeWidth={1}
          strokeDasharray="2 3"
        />
      )}

      {/* Today is the only real number on the chart — solid, colored by its
          risk status, and the only labelled value. */}
      <circle cx={px(0)} cy={py(p.days[0]!.acwr)} r={4} fill={todayColor} />
      <text
        x={px(0)}
        y={H - 4}
        textAnchor="start"
        fontSize={9}
        fill="var(--ink-faint)"
        data-axis-label="now"
      >
        Now {p.days[0]!.acwr.toFixed(2)}
      </text>
      {crossing && (
        <text
          x={crossingLabelX}
          y={H - 16}
          textAnchor="middle"
          fontSize={9}
          fill="var(--ink-faint)"
          data-axis-label="crossing"
        >
          {parseLocalDate(crossing.date).toLocaleDateString(undefined, { weekday: "short" })}
        </text>
      )}
      <text
        x={W - PAD.right}
        y={H - 4}
        textAnchor="end"
        fontSize={9}
        fill="var(--ink-faint)"
        data-axis-label="horizon"
      >
        +{PROJECTION_DAYS}d
      </text>
    </svg>
  );
}

/// Issue #224 (phase 1): where ACWR goes over the next week if you train
/// NOTHING, against the current phase's band, plus what a single session
/// would have to be to keep it in band. It deliberately stops there — it does
/// not schedule rest or training days, and it never presents readiness as
/// something that was projected forward.
export default function AcwrProjectionCard({ phase, sessions, latestReadiness }: Props) {
  const projection = projectAcwr(ewmaLoadState(sessions), {
    low: phase.acwrLow,
    high: phase.acwrHigh,
  });
  const readinessDate = latestReadiness?.date ?? null;
  const readinessValue = latestReadiness?.readiness ?? null;
  const readinessColor =
    (latestReadiness?.zone ? ZONE_COLORS[latestReadiness.zone] : null) ?? "var(--ink-muted)";

  return (
    <div className="card">
      <div
        className="card-title"
        style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}
      >
        <span>ACWR next 7 days</span>
        <InfoDot topic="acwrProjection" />
      </div>
      <div className="label-eyebrow" style={{ marginTop: 2 }}>
        If you train nothing
      </div>

      {projection === null ? (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 10, lineHeight: 1.5 }}>
          Log a few sessions and this card will show where your ACWR drifts over
          the coming week if you don't train.
        </div>
      ) : (
        <>
          <div style={{ marginTop: 8 }}>
            <Chart p={projection} todayColor={getACWRStatus(projection.days[0]!.acwr).color} />
          </div>
          <div style={{ fontSize: "var(--t-sm)", color: "var(--ink)", marginTop: 6, lineHeight: 1.5 }}>
            {headline(projection, phase.name)}
          </div>
          {projection.keepInBand && (
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 4, lineHeight: 1.5 }}>
              About{" "}
              <span style={{ color: "var(--ink)", fontWeight: 600 }}>
                {projection.keepInBand.durationMin} min @ RPE {projection.keepInBand.rpe}
              </span>{" "}
              {relativeDayLabel(projection.keepInBand.date)} would{" "}
              {projection.days[0]!.fit === "below" ? "bring you back to" : "hold"} the{" "}
              {projection.band!.low.toFixed(1)} floor — {Math.round(projection.keepInBand.load)} AU,
              or any duration × RPE that multiplies out the same.
            </div>
          )}
        </>
      )}

      {/* Today's readiness, walled off from the projection above: HRV, resting
          HR and sleep cannot be forecast, so this number is never stepped
          forward. The divider + the explicit "measured" label are the point. */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 10,
          marginTop: 12,
          paddingTop: 10,
          borderTop: "1px solid var(--hairline)",
        }}
      >
        <div style={{ minWidth: 0 }}>
          <div className="label-eyebrow">
            Readiness ·{" "}
            {readinessDate === null
              ? "no reading"
              : readinessDate === today()
                ? "today"
                : relativeDayLabel(readinessDate)}
          </div>
          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 2 }}>
            Measured, not projected
          </div>
        </div>
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontSize: 24,
            fontWeight: 800,
            letterSpacing: "-0.03em",
            lineHeight: 1,
            color: readinessValue === null ? "var(--ink-faint)" : readinessColor,
          }}
        >
          {readinessValue === null ? "—" : Math.round(readinessValue)}
        </div>
      </div>
    </div>
  );
}
