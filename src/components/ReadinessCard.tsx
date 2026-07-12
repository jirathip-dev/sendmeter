import { useEffect, useState } from "react";
import { fetchHealthMetrics } from "../lib/repo";
import type { HealthMetric } from "../types";

const ZONE_COLORS: Record<string, string> = {
  push: "#34C759",
  maintain: "#FFB800",
  recover: "#FF453A",
};

export default function ReadinessCard() {
  const [metrics, setMetrics] = useState<HealthMetric[]>([]);

  useEffect(() => {
    let cancelled = false;
    fetchHealthMetrics(14)
      .then((m) => {
        if (!cancelled) setMetrics(m);
      })
      .catch(() => {
        // card stays hidden on error
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Empty state: the feature should be discoverable before any watch data
  if (metrics.length === 0) {
    return (
      <div className="card">
        <div
          style={{
            fontSize: 9,
            color: "var(--ink-muted)",
            textTransform: "uppercase",
            letterSpacing: "0.1em",
            marginBottom: 8,
          }}
        >
          Readiness
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
          with your climbing load. Wear your Apple Watch overnight and open the
          Send Log watch app to compute it.
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
    <div className="card">
      <div
        style={{
          fontSize: 9,
          color: "var(--ink-muted)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 8,
        }}
      >
        Readiness
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
      <div
        style={{
          display: "flex",
          gap: 3,
          alignItems: "flex-end",
          height: 36,
          marginTop: 12,
        }}
      >
        {days.map(({ key, m }) => (
          <div
            key={key}
            title={
              m?.readiness != null ? `${key} · ${m.readiness}` : `${key} · no data`
            }
            style={{
              flex: 1,
              height:
                m?.readiness != null
                  ? Math.max(3, (m.readiness / 100) * 32)
                  : 2,
              background:
                m?.zone && m.readiness != null
                  ? (ZONE_COLORS[m.zone] ?? "var(--border)")
                  : "var(--border)",
              borderRadius: 2,
            }}
          />
        ))}
      </div>
      {footerParts.length > 0 && (
        <div style={{ fontSize: 10, color: "var(--ink-muted)", marginTop: 8 }}>
          {footerParts.join(" · ")}
        </div>
      )}
    </div>
  );
}
