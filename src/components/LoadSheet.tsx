import { useMemo } from "react";
import Sheet from "./Sheet";
import ContributionHeatmap from "./ContributionHeatmap";
import type { AcwrData, AcwrStatus, Session } from "../types";

/// Detail page for training load — opened from the ACWR card. Shows the
/// acute:chronic summary plus a GitHub-style heatmap of daily AU (SL-38).
export default function LoadSheet({
  acwrData,
  status,
  sessions,
  onClose,
}: {
  acwrData: AcwrData;
  status: AcwrStatus;
  sessions: Session[];
  onClose: () => void;
}) {
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
