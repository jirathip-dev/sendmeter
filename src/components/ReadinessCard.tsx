import { useEffect, useState } from "react";
import { fetchHealthMetrics } from "../lib/repo";
import type { HealthMetric } from "../types";

const ZONE_COLORS: Record<string, string> = {
  push: "#4ade80",
  maintain: "#facc15",
  recover: "#f87171",
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

  if (metrics.length === 0) return null;

  const latest = metrics[metrics.length - 1]!;
  const color = latest.zone ? (ZONE_COLORS[latest.zone] ?? "#64748b") : "#64748b";

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
          color: "#4a5a70",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 8,
        }}
      >
        Readiness
      </div>
      <div
        style={{
          fontFamily: "'Syne', sans-serif",
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
          <span style={{ color: "#4a5a70", textTransform: "none" }}>
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
                  ? (ZONE_COLORS[m.zone] ?? "#1e2d40")
                  : "#1e2d40",
              borderRadius: 2,
            }}
          />
        ))}
      </div>
      {footerParts.length > 0 && (
        <div style={{ fontSize: 10, color: "#4a5a70", marginTop: 8 }}>
          {footerParts.join(" · ")}
        </div>
      )}
    </div>
  );
}
