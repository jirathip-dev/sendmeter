import { useChartHover } from "../hooks/useChartHover";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { fetchHealthMetrics } from "../lib/repo";
import { ewma } from "../lib/metrics";
import { daysAgo } from "../lib/dates";
import ChartTooltip from "./ChartTooltip";
import type { HealthMetric } from "../types";

type MetricKey =
  | "hrvSdnnMs"
  | "restingHr"
  | "sleepHours"
  | "sleepDeepHours"
  | "sleepRemHours"
  | "respRateBpm"
  | "bodyMassKg";

interface MetricSpec {
  key: MetricKey;
  label: string;
  unit: string;
  format: (v: number) => string;
  // Which way is "good" vs the day's own 28d average — drives the per-day
  // bar color (SL-63). null = no good/bad meaning (e.g. body weight).
  higherIsBetter: boolean | null;
}

const METRICS: MetricSpec[] = [
  { key: "hrvSdnnMs", label: "HRV", unit: "ms", format: (v) => Math.round(v).toString(), higherIsBetter: true },
  { key: "restingHr", label: "Resting HR", unit: "bpm", format: (v) => Math.round(v).toString(), higherIsBetter: false },
  { key: "respRateBpm", label: "Resp Rate", unit: "brpm", format: (v) => v.toFixed(1), higherIsBetter: false },
  { key: "sleepHours", label: "Sleep", unit: "h", format: (v) => v.toFixed(1), higherIsBetter: true },
  { key: "sleepDeepHours", label: "Deep Sleep", unit: "h", format: (v) => v.toFixed(1), higherIsBetter: true },
  { key: "sleepRemHours", label: "REM Sleep", unit: "h", format: (v) => v.toFixed(1), higherIsBetter: true },
  { key: "bodyMassKg", label: "Weight", unit: "kg", format: (v) => v.toFixed(1), higherIsBetter: null },
];

// Fetch a longer window than we show so the EWMA trends are warmed up by the
// time they enter the visible range (a 28-day EMA seeded inside the visible
// window would just chase the bars).
const FETCH_DAYS = 60;
const VISIBLE_DAYS = 14;

// Row chart geometry (SVG viewBox units; width scales to the card).
const W = 300;
const H = 30;
const SLOT = W / VISIBLE_DAYS;
const Y_TOP = 2;
const Y_BASE = 28;

/// Breaks the readiness score back down into the raw inputs it's computed
/// from — a companion to ReadinessCard so "why is my score X" is visible.
/// All rows share one X axis (the same last-14-days range, gaps included);
/// each row overlays short (7d, solid) and long (28d, dashed) EWMA trends.
export default function RecoveryStatsCard() {
  const [hovered, hoverProps] = useChartHover<string>();
  const realtimeVersion = useRealtimeVersion();
  const metrics = useCancellableFetch<HealthMetric[]>(
    () => fetchHealthMetrics(FETCH_DAYS),
    [],
    realtimeVersion,
  );

  // Shared day slots: oldest → newest, identical for every row.
  const allDays = Array.from({ length: FETCH_DAYS }, (_, i) =>
    daysAgo(FETCH_DAYS - 1 - i),
  );
  const visibleDays = allDays.slice(FETCH_DAYS - VISIBLE_DAYS);
  const byDate = new Map(metrics.map((m) => [m.date, m]));

  const rows = METRICS.map((spec) => {
    const dense = allDays.map((d) => byDate.get(d)?.[spec.key] ?? null);
    const short = ewma(dense, 7).slice(FETCH_DAYS - VISIBLE_DAYS);
    const long = ewma(dense, 28).slice(FETCH_DAYS - VISIBLE_DAYS);
    const values = dense.slice(FETCH_DAYS - VISIBLE_DAYS);
    return { spec, values, short, long };
  }).filter((r) => r.values.some((v) => v !== null));

  // Hovering any day highlights that column across every row (shared X).
  const hoveredDay = hovered !== null ? Number(hovered.split(":")[1]) : null;

  if (rows.length === 0) {
    return (
      <div className="card">
        <div className="label-eyebrow" style={{ marginBottom: 8 }}>
          Recovery Inputs
        </div>
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.5 }}>
          HRV, resting heart rate, sleep, and weight will show here once your
          watch starts syncing overnight data.
        </div>
      </div>
    );
  }

  return (
    <div className="card">
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
          marginBottom: 10,
        }}
      >
        <div className="label-eyebrow">Recovery Inputs</div>
        {/* Trend legend */}
        <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)", display: "flex", gap: 8 }}>
          <span>
            <svg width="14" height="6" style={{ verticalAlign: "middle" }}>
              <line x1="0" y1="3" x2="14" y2="3" stroke="var(--primary)" strokeWidth="1.5" />
            </svg>{" "}
            7d
          </span>
          <span>
            <svg width="14" height="6" style={{ verticalAlign: "middle" }}>
              <line x1="0" y1="3" x2="14" y2="3" stroke="var(--ink-muted)" strokeWidth="1.2" strokeDasharray="3 2" />
            </svg>{" "}
            28d
          </span>
        </div>
      </div>

      {rows.map(({ spec, values, short, long }, rowIdx) => {
        // Latest = newest non-null day in the visible window.
        let latest: number | null = null;
        for (let i = values.length - 1; i >= 0; i--) {
          const v = values[i];
          if (v != null) {
            latest = v;
            break;
          }
        }
        // Y range spans bars AND trend overlays so lines never clip.
        const present = [
          ...values.filter((v): v is number => v !== null),
          ...short.filter((v): v is number => v !== null),
          ...long.filter((v): v is number => v !== null),
        ];
        const max = Math.max(...present);
        const min = Math.min(...present);
        const range = max - min || 1;
        const yOf = (v: number) =>
          Y_BASE - ((v - min) / range) * (Y_BASE - Y_TOP - 4);
        const linePoints = (series: (number | null)[]) =>
          series
            .map((v, i) =>
              v === null ? null : `${(i + 0.5) * SLOT},${yOf(v).toFixed(2)}`,
            )
            .filter((p): p is string => p !== null)
            .join(" ");

        // Per-day good/bad color (SL-63): each bar compared to that day's own
        // 28d average (falling back to the window mean), in the metric's "good"
        // direction. A small deadband around the average stays neutral.
        const nums = values.filter((v): v is number => v !== null);
        const mean = nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : 0;
        const barColor = (v: number, i: number): string => {
          if (spec.higherIsBetter === null) return "var(--primary)";
          const base = long[i] ?? mean;
          if (base === 0 || Math.abs(v - base) < base * 0.02) return "var(--primary)";
          const good = spec.higherIsBetter ? v > base : v < base;
          return good ? "var(--success)" : "var(--danger)";
        };

        return (
          <div key={spec.key} style={{ marginTop: rowIdx === 0 ? 0 : 12 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "baseline",
                marginBottom: 4,
              }}
            >
              <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
                {spec.label}
              </span>
              <span
                style={{
                  fontSize: "var(--t-base)",
                  color: "var(--ink)",
                  fontWeight: 700,
                  fontFamily: "Inter, sans-serif",
                }}
              >
                {latest !== null ? spec.format(latest) : "—"}
                <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)", fontWeight: 400 }}>
                  {" "}
                  {spec.unit}
                </span>
              </span>
            </div>
            <div style={{ position: "relative" }}>
              {/* Tooltip for this row's hovered day */}
              {hovered?.startsWith(`${spec.key}:`) && hoveredDay !== null && (
                <ChartTooltip
                  align={
                    hoveredDay < 2
                      ? "start"
                      : hoveredDay > VISIBLE_DAYS - 3
                        ? "end"
                        : "center"
                  }
                >
                  {visibleDays[hoveredDay]} ·{" "}
                  {values[hoveredDay] !== null
                    ? `${spec.format(values[hoveredDay]!)} ${spec.unit}`
                    : short[hoveredDay] !== null
                      ? `7d ${spec.format(short[hoveredDay]!)} ${spec.unit}`
                      : "no data"}
                </ChartTooltip>
              )}
              <svg
                className="chart-scrub"
                viewBox={`0 0 ${W} ${H}`}
                style={{ width: "100%", display: "block" }}
              >
                {/* Shared-X hover crosshair (mirrors across all rows) */}
                {hoveredDay !== null && (
                  <line
                    x1={(hoveredDay + 0.5) * SLOT}
                    x2={(hoveredDay + 0.5) * SLOT}
                    y1={0}
                    y2={H}
                    stroke="var(--ink-faint)"
                    strokeWidth="1"
                    strokeDasharray="2 2"
                    vectorEffect="non-scaling-stroke"
                  />
                )}
                {/* Day bars (gaps stay empty) */}
                {values.map((v, i) => {
                  if (v === null) return null;
                  const hk = `${spec.key}:${i}`;
                  const y = yOf(v);
                  return (
                    <rect
                      key={i}
                      x={(i + 0.2) * SLOT}
                      width={SLOT * 0.6}
                      y={y}
                      height={Y_BASE + 2 - y}
                      rx="1"
                      fill={barColor(v, i)}
                      opacity={
                        hovered === hk
                          ? 0.9
                          : hoveredDay !== null && hoveredDay === i
                            ? 0.7
                            : 0.3
                      }
                    />
                  );
                })}
                {/* Long trend (28d) — dashed, faint */}
                <polyline
                  points={linePoints(long)}
                  fill="none"
                  stroke="var(--ink-muted)"
                  strokeWidth="1.2"
                  strokeDasharray="3 2"
                  vectorEffect="non-scaling-stroke"
                  opacity="0.7"
                />
                {/* Short trend (7d) — solid */}
                <polyline
                  points={linePoints(short)}
                  fill="none"
                  stroke="var(--primary)"
                  strokeWidth="1.5"
                  vectorEffect="non-scaling-stroke"
                />
                {/* Full-height transparent hover targets, one per day slot */}
                {visibleDays.map((_, i) => (
                  <rect
                    key={`h-${i}`}
                    x={i * SLOT}
                    width={SLOT}
                    y={0}
                    height={H}
                    fill="transparent"
                    style={{ cursor: "pointer" }}
                    {...hoverProps(`${spec.key}:${i}`)}
                  />
                ))}
              </svg>
            </div>
          </div>
        );
      })}

      {/* Shared x-axis labels — rendered once for every row above */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          fontSize: "var(--t-eyebrow)",
          color: "var(--ink-faint)",
          marginTop: 4,
        }}
      >
        <span>{visibleDays[0]!.slice(5)}</span>
        <span>{visibleDays[Math.floor(VISIBLE_DAYS / 2)]!.slice(5)}</span>
        <span>{visibleDays[VISIBLE_DAYS - 1]!.slice(5)}</span>
      </div>
    </div>
  );
}
