import { useMemo } from "react";
import Sheet from "./Sheet";
import ContributionHeatmap from "./ContributionHeatmap";
import type { AcwrData, AcwrStatus, Session, WeeklyLoad } from "../types";

/// Detail page for training load — opened from the ACWR card. Shows the
/// acute:chronic summary, weekly totals, and a GitHub-style heatmap of
/// daily AU (SL-38).
export default function LoadSheet({
  acwrData,
  status,
  sessions,
  weeklyLoads,
  onClose,
}: {
  acwrData: AcwrData;
  status: AcwrStatus;
  sessions: Session[];
  weeklyLoads: WeeklyLoad[];
  onClose: () => void;
}) {
  const maxW = Math.max(...weeklyLoads.map((w) => w.total), 1);
  const daily = useMemo(() => {
    const m = new Map<string, number>();
    for (const s of sessions) m.set(s.date, (m.get(s.date) ?? 0) + s.load);
    return m;
  }, [sessions]);

  return (
    <Sheet onClose={onClose}>
      <div style={{ fontFamily: "Inter, sans-serif", fontSize: 20, fontWeight: 800 }}>
        Training Load
      </div>
      <div style={{ fontSize: 11, color: "var(--ink-muted)", marginBottom: 16 }}>
        Daily AU (Load = Duration × RPE) and your acute:chronic ratio.
      </div>

      <div className="grid-2">
        <div className="card">
          <div className="label-eyebrow" style={{ marginBottom: 8 }}>ACWR</div>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 32,
              fontWeight: 800,
              color: status.color,
              letterSpacing: "-0.04em",
              lineHeight: 1,
            }}
          >
            {acwrData.acwr !== null ? acwrData.acwr.toFixed(2) : "—"}
          </div>
          <div style={{ fontSize: 11, color: status.color, marginTop: 4 }}>
            {status.label}
          </div>
        </div>
        <div className="card">
          <div className="label-eyebrow" style={{ marginBottom: 10 }}>Load (AU)</div>
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12, marginBottom: 6 }}>
            <span style={{ color: "var(--ink-muted)" }}>Acute 7d</span>
            <span style={{ color: "var(--ink)" }}>{acwrData.acute.toFixed(0)}</span>
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12 }}>
            <span style={{ color: "var(--ink-muted)" }}>Chronic avg</span>
            <span style={{ color: "var(--ink)" }}>{acwrData.chronic.toFixed(0)}</span>
          </div>
        </div>
      </div>

      {/* Weekly totals (moved in from the dashboard Load card) */}
      <div className="card" style={{ marginTop: 10 }}>
        <div className="label-eyebrow" style={{ marginBottom: 12 }}>Weekly load</div>
        <div style={{ display: "flex", gap: 8, alignItems: "flex-end", height: 72 }}>
          {weeklyLoads.map((w, i) => (
            <div
              key={i}
              style={{
                flex: 1,
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                gap: 4,
                height: "100%",
                justifyContent: "flex-end",
              }}
            >
              <span style={{ fontSize: 9, color: "var(--ink-muted)" }}>
                {w.total.toLocaleString()}
              </span>
              <div
                style={{
                  width: "100%",
                  height: Math.max((w.total / maxW) * 48, 2),
                  background: i === weeklyLoads.length - 1 ? "var(--success)" : "var(--border)",
                  borderRadius: 3,
                }}
              />
              <span style={{ fontSize: 8, color: "var(--ink-faint)" }}>{w.label}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="card" style={{ marginTop: 10 }}>
        <div className="label-eyebrow" style={{ marginBottom: 12 }}>Daily load</div>
        <ContributionHeatmap values={daily} />
      </div>

      <div style={{ marginTop: 12 }}>
        <button className="btn-ghost" onClick={onClose}>Close</button>
      </div>
    </Sheet>
  );
}
