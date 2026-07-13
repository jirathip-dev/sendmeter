import { useChartHover } from "../hooks/useChartHover";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { fetchHealthMetrics } from "../lib/repo";
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
}

const METRICS: MetricSpec[] = [
  { key: "hrvSdnnMs", label: "HRV", unit: "ms", format: (v) => Math.round(v).toString() },
  { key: "restingHr", label: "Resting HR", unit: "bpm", format: (v) => Math.round(v).toString() },
  { key: "respRateBpm", label: "Resp Rate", unit: "brpm", format: (v) => v.toFixed(1) },
  { key: "sleepHours", label: "Sleep", unit: "h", format: (v) => v.toFixed(1) },
  { key: "sleepDeepHours", label: "Deep Sleep", unit: "h", format: (v) => v.toFixed(1) },
  { key: "sleepRemHours", label: "REM Sleep", unit: "h", format: (v) => v.toFixed(1) },
  { key: "bodyMassKg", label: "Weight", unit: "kg", format: (v) => v.toFixed(1) },
];

/// Breaks the readiness score back down into the raw inputs it's computed
/// from — a companion to ReadinessCard so "why is my score X" is visible.
export default function RecoveryStatsCard() {
  const [hovered, hoverProps] = useChartHover<string>();
  const realtimeVersion = useRealtimeVersion();
  const metrics = useCancellableFetch<HealthMetric[]>(
    () => fetchHealthMetrics(14),
    [],
    realtimeVersion,
  );

  const rows = METRICS.map((spec) => {
    const points = metrics.filter((m) => m[spec.key] != null) as (HealthMetric &
      Record<MetricKey, number>)[];
    return { spec, points };
  }).filter((r) => r.points.length > 0);

  if (rows.length === 0) {
    return (
      <div className="card">
        <div className="label-eyebrow" style={{ marginBottom: 8 }}>
          Recovery Inputs
        </div>
        <div style={{ fontSize: 11, color: "var(--ink-muted)", lineHeight: 1.5 }}>
          HRV, resting heart rate, sleep, and weight will show here once your
          watch starts syncing overnight data.
        </div>
      </div>
    );
  }

  return (
    <div className="card">
      <div className="label-eyebrow" style={{ marginBottom: 10 }}>
        Recovery Inputs
      </div>
      {rows.map(({ spec, points }, i) => {
        const latest = points[points.length - 1]!;
        const values = points.map((p) => p[spec.key]);
        const max = Math.max(...values);
        const min = Math.min(...values);
        const range = max - min || 1;
        return (
          <div key={spec.key} style={{ marginTop: i === 0 ? 0 : 12 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "baseline",
                marginBottom: 4,
              }}
            >
              <span style={{ fontSize: 10, color: "var(--ink-muted)" }}>
                {spec.label}
              </span>
              <span
                style={{
                  fontSize: 13,
                  color: "var(--ink)",
                  fontWeight: 700,
                  fontFamily: "Inter, sans-serif",
                }}
              >
                {spec.format(latest[spec.key])}
                <span
                  style={{
                    fontSize: 9,
                    color: "var(--ink-faint)",
                    fontWeight: 400,
                  }}
                >
                  {" "}
                  {spec.unit}
                </span>
              </span>
            </div>
            <div style={{ position: "relative" }}>
              {(() => {
                const prefix = `${spec.key}-`;
                const hoveredIdx =
                  hovered?.startsWith(prefix)
                    ? Number(hovered.slice(prefix.length))
                    : null;
                return (
                  hoveredIdx !== null && (
                    <div
                      style={{
                        position: "absolute",
                        left: `${((hoveredIdx + 0.5) / points.length) * 100}%`,
                        top: 0,
                        bottom: 0,
                        width: 0,
                        borderLeft: "1px dashed var(--ink-faint)",
                        pointerEvents: "none",
                      }}
                    />
                  )
                );
              })()}
              <div
                style={{ display: "flex", gap: 2, alignItems: "flex-end", height: 20 }}
              >
                {points.map((p, j) => {
                  const v = p[spec.key];
                  const h = Math.max(2, ((v - min) / range) * 16 + 3);
                  const hk = `${spec.key}-${j}`;
                  const baseOpacity = 0.3 + 0.7 * (j / Math.max(1, points.length - 1));
                  return (
                    <div
                      key={p.date}
                      style={{
                        flex: 1,
                        position: "relative",
                        height: "100%",
                        display: "flex",
                        alignItems: "flex-end",
                      }}
                    >
                      {hovered === hk && (
                        <ChartTooltip
                          align={
                            j < 2
                              ? "start"
                              : j > points.length - 3
                                ? "end"
                                : "center"
                          }
                        >
                          {p.date} · {spec.format(v)} {spec.unit}
                        </ChartTooltip>
                      )}
                      <div
                        style={{
                          width: "100%",
                          height: h,
                          background: "var(--primary)",
                          opacity: hovered === null || hovered === hk ? baseOpacity : 0.15,
                          borderRadius: 1,
                          boxShadow: hovered === hk ? "0 0 0 1.5px var(--ink)" : "none",
                          cursor: "pointer",
                          transition: "opacity 0.1s",
                        }}
                        {...hoverProps(hk)}
                      />
                    </div>
                  );
                })}
              </div>
              {/* x-axis: this row's own date range (rows can cover different days) */}
              {points.length > 1 && (
                <div
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    fontSize: 7.5,
                    color: "var(--ink-faint)",
                    marginTop: 2,
                  }}
                >
                  <span>{points[0]!.date.slice(5)}</span>
                  <span>{points[points.length - 1]!.date.slice(5)}</span>
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
