import { useChartHover } from "../hooks/useChartHover";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { fetchHealthMetrics } from "../lib/repo";
import ChartTooltip from "./ChartTooltip";
import type { HealthMetric } from "../types";

const ZONE_COLORS: Record<string, string> = {
  push: "var(--success)",
  maintain: "var(--warning)",
  recover: "var(--danger)",
};

export default function ReadinessCard({ onClick }: { onClick?: () => void } = {}) {
  const [hoveredDay, hoverDayProps] = useChartHover<number>();
  const realtimeVersion = useRealtimeVersion();
  const metrics = useCancellableFetch<HealthMetric[]>(
    () => fetchHealthMetrics(14),
    [],
    realtimeVersion,
  );

  // Empty state: the feature should be discoverable before any watch data
  if (metrics.length === 0) {
    return (
      <div className="card" onClick={onClick} style={{ cursor: onClick ? "pointer" : undefined }}>
        <div className="label-eyebrow" style={{ marginBottom: 8, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <span>Readiness</span>
          {onClick && <span style={{ fontSize: 13, color: "var(--ink-faint)" }}>›</span>}
        </div>
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontSize: 38,
            fontWeight: 800,
            color: "var(--ink-faint)",
            letterSpacing: "-0.04em",
            lineHeight: 1,
          }}
        >
          —
        </div>
        <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 10, lineHeight: 1.5 }}>
          Daily recovery score from HRV, resting heart rate, and sleep — blended
          with your climbing load. Wear your Apple Watch overnight, then open
          Sendmeter on your iPhone to sync it from Apple Health.
        </div>
      </div>
    );
  }

  const latest = metrics[metrics.length - 1]!;
  const color = latest.zone ? (ZONE_COLORS[latest.zone] ?? "var(--ink-muted)") : "var(--ink-muted)";

  // Build a date-indexed lookup for the last 14 days (gaps = missing)
  const byDate = new Map(metrics.map((m) => [m.date, m]));
  const days: { key: string; m: HealthMetric | undefined }[] = [];
  for (let i = 13; i >= 0; i--) {
    const d = new Date();
    d.setDate(d.getDate() - i);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    days.push({ key, m: byDate.get(key) });
  }

  const footerParts: string[] = [];
  if (latest.hrvSdnnMs) footerParts.push(`HRV ${Math.round(latest.hrvSdnnMs)}ms`);
  if (latest.restingHr) footerParts.push(`RHR ${Math.round(latest.restingHr)}`);
  if (latest.sleepHours) footerParts.push(`Sleep ${latest.sleepHours.toFixed(1)}h`);
  if (latest.bodyMassKg) footerParts.push(`${latest.bodyMassKg.toFixed(1)}kg`);

  return (
    <div className="card" onClick={onClick} style={{ cursor: onClick ? "pointer" : undefined }}>
      <div className="label-eyebrow" style={{ marginBottom: 8, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <span>Readiness</span>
        {onClick && <span style={{ fontSize: 13, color: "var(--ink-faint)" }}>›</span>}
      </div>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: 38,
          fontWeight: 800,
          color,
          letterSpacing: "-0.04em",
          lineHeight: 1,
        }}
      >
        {latest.readiness ?? "—"}
      </div>
      <div style={{ fontSize: 11, color, marginTop: 4, textTransform: "uppercase" }}>
        {latest.zone ?? "no score"}
        {latest.date !== days[days.length - 1]!.key && (
          <span style={{ color: "var(--ink-muted)", textTransform: "none" }}>
            {" "}
            · {latest.date}
          </span>
        )}
      </div>
      <div style={{ display: "flex", gap: 6, marginTop: 12 }}>
        {/* y-axis, reserved outside the plot/data area */}
        <div style={{ position: "relative", width: 16, flexShrink: 0, height: 36 }}>
          {[
            { v: 70, label: "70" },
            { v: 40, label: "40" },
          ].map(({ v, label }) => (
            <span
              key={v}
              style={{
                position: "absolute",
                top: 36 - (v / 100) * 32 - 5,
                right: 0,
                fontSize: 8,
                color: "var(--ink-faint)",
              }}
            >
              {label}
            </span>
          ))}
        </div>
        <div style={{ position: "relative", flex: 1 }}>
          {/* zone-threshold gridlines (push/maintain/recover boundaries) */}
          {[70, 40].map((v) => (
            <div
              key={v}
              style={{
                position: "absolute",
                left: 0,
                right: 0,
                top: 36 - (v / 100) * 32,
                borderTop: "1px dashed var(--hairline)",
              }}
            />
          ))}
          {hoveredDay !== null && (
            <div
              style={{
                position: "absolute",
                left: `${((hoveredDay + 0.5) / days.length) * 100}%`,
                top: 0,
                bottom: 0,
                width: 0,
                borderLeft: "1px dashed var(--ink-faint)",
                pointerEvents: "none",
              }}
            />
          )}
          <div
            style={{
              display: "flex",
              gap: 3,
              alignItems: "flex-end",
              height: 36,
            }}
          >
            {days.map(({ key, m }, i) => (
              <div
                key={key}
                style={{
                  flex: 1,
                  position: "relative",
                  height: "100%",
                  display: "flex",
                  alignItems: "flex-end",
                }}
              >
                {hoveredDay === i && (
                  <ChartTooltip
                    align={i < 2 ? "start" : i > days.length - 3 ? "end" : "center"}
                  >
                    {key} ·{" "}
                    {m?.readiness != null
                      ? `${m.readiness} ${m.zone ?? ""}`.trim()
                      : "no data"}
                  </ChartTooltip>
                )}
                <div
                  style={{
                    width: "100%",
                    height:
                      m?.readiness != null
                        ? Math.max(3, (m.readiness / 100) * 32)
                        : 2,
                    background:
                      m?.zone && m.readiness != null
                        ? (ZONE_COLORS[m.zone] ?? "var(--border)")
                        : "var(--border)",
                    borderRadius: 2,
                    opacity: hoveredDay === null || hoveredDay === i ? 1 : 0.5,
                    boxShadow: hoveredDay === i ? "0 0 0 1.5px var(--ink)" : "none",
                    cursor: "pointer",
                    transition: "opacity 0.1s",
                  }}
                  {...hoverDayProps(i)}
                />
              </div>
            ))}
          </div>
          {/* x-axis: a few date ticks, not all 14 (too cramped) */}
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: 8,
              color: "var(--ink-faint)",
              marginTop: 3,
            }}
          >
            <span>{days[0]!.key.slice(5)}</span>
            <span>{days[Math.floor((days.length - 1) / 2)]!.key.slice(5)}</span>
            <span>{days[days.length - 1]!.key.slice(5)}</span>
          </div>
        </div>
      </div>
      {footerParts.length > 0 && (
        <div style={{ fontSize: 10, color: "var(--ink-muted)", marginTop: 8 }}>
          {footerParts.join(" · ")}
        </div>
      )}
    </div>
  );
}
