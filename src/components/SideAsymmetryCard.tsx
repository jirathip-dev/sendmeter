import { isEffortRecording } from "../lib/zoneHistory";
import type { TindeqRecordingMeta } from "../types";

/// Left/right best-peak comparison for a tag — finger-strength asymmetry is a
/// real injury-risk signal (SL-19). Uses recording metadata (peakKg + side),
/// so no sample fetch is needed. Renders only when both sides have data.
///
/// Capacity recordings only: Warm-up and Prehab are submax by construction,
/// so neither may become a side's "best" and fabricate an asymmetry reading.
export default function SideAsymmetryCard({
  recordings,
}: {
  recordings: TindeqRecordingMeta[];
}) {
  const effortRecordings = recordings.filter(isEffortRecording);
  const bestPeak = (side: string): number | null => {
    const peaks = effortRecordings.filter((r) => r.side === side && r.peakKg != null).map((r) => r.peakKg!);
    return peaks.length ? Math.max(...peaks) : null;
  };
  const left = bestPeak("left");
  const right = bestPeak("right");
  if (left == null || right == null) return null;

  const strong = Math.max(left, right);
  const imbalancePct = strong > 0 ? ((strong - Math.min(left, right)) / strong) * 100 : 0;
  const strongerSide = left >= right ? "left" : "right";
  const flag = imbalancePct >= 15; // asymmetry worth addressing

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="label-eyebrow" style={{ marginBottom: 12 }}>
        Left / Right asymmetry
      </div>
      <div style={{ display: "flex", gap: 14 }}>
        {([["Left", left], ["Right", right]] as const).map(([label, v]) => (
          <div key={label} style={{ flex: 1 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "baseline",
                fontSize: "var(--t-xs)",
                marginBottom: 5,
              }}
            >
              <span style={{ color: "var(--ink-muted)" }}>{label}</span>
              <span style={{ fontFamily: "Inter, sans-serif", fontWeight: 800 }}>
                {v.toFixed(1)}
                <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)", fontWeight: 400 }}> kg</span>
              </span>
            </div>
            <div style={{ height: 8, borderRadius: 4, background: "var(--surface-2)", overflow: "hidden" }}>
              <div
                style={{
                  width: `${(v / strong) * 100}%`,
                  height: "100%",
                  borderRadius: 4,
                  background: v === strong ? "var(--success)" : "var(--info)",
                }}
              />
            </div>
          </div>
        ))}
      </div>
      <div
        style={{
          fontSize: "var(--t-xs)",
          color: flag ? "var(--warning)" : "var(--ink-muted)",
          marginTop: 12,
        }}
      >
        {imbalancePct < 1
          ? "Balanced (<1%)"
          : `${imbalancePct.toFixed(0)}% stronger on the ${strongerSide}${flag ? " — worth rebalancing" : ""}`}
      </div>
    </div>
  );
}
