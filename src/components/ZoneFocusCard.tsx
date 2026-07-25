import { useState } from "react";
import { QUALITIES } from "../lib/force-curve";
import type { ForceCurveModel, TrainingQuality } from "../lib/force-curve";
import { recommendZone, zoneTrainingSets } from "../lib/zoneHistory";
import type { TindeqRecordingMeta } from "../types";
import { QUALITY_COLORS } from "../lib/zoneSelection";

interface Props {
  /// Recordings for the active exercise (already tag-filtered by ForceView).
  recordings: TindeqRecordingMeta[];
  model: ForceCurveModel | null;
  /// Arm the recommended zone on the gauge + guided timer (SL-100).
  onPick: (q: TrainingQuality) => void;
}

const WINDOW_DAYS = 28;

/// Training-balance card (SL-100, #182): how many duration-normalised sets
/// in the last 4 weeks you trained each quality on this exercise, and which
/// one to focus on next — the least-trained zone, with the force curve
/// breaking near-ties. Tapping the recommendation arms its guided zone
/// protocol.
export default function ZoneFocusCard({ recordings, model, onPick }: Props) {
  // `new Date()` is impure in render — freeze it once for this mount.
  const [now] = useState(() => new Date());
  const sets = zoneTrainingSets(recordings, now, WINDOW_DAYS);
  const rec = recommendZone(sets, model);
  if (!rec) return null;

  const maxSets = Math.max(1, ...QUALITIES.map((q) => sets[q.id]));

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="label-eyebrow" style={{ marginBottom: 8 }}>
        Training balance · last 4 weeks
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 5 }}>
        {QUALITIES.map((q) => {
          const n = sets[q.id];
          const rounded = Math.round(n * 10) / 10;
          const color = QUALITY_COLORS[q.id];
          return (
            <div key={q.id} style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span
                style={{
                  fontSize: "var(--t-xs)",
                  color: "var(--ink)",
                  width: 74,
                  flexShrink: 0,
                }}
              >
                {q.label}
              </span>
              <div
                style={{
                  flex: 1,
                  height: 8,
                  borderRadius: 4,
                  background: "var(--surface-1)",
                  overflow: "hidden",
                }}
              >
                <div
                  style={{
                    width: `${(n / maxSets) * 100}%`,
                    height: "100%",
                    background: color,
                    borderRadius: 4,
                  }}
                />
              </div>
              <span
                style={{
                  fontSize: "var(--t-2xs)",
                  color: "var(--ink-muted)",
                  width: 46,
                  textAlign: "right",
                  flexShrink: 0,
                }}
              >
                {rounded} set{rounded === 1 ? "" : "s"}
              </span>
            </div>
          );
        })}
      </div>

      {/* Focus recommendation — tap to arm its guided zone. */}
      <button
        onClick={() => onPick(rec.zone)}
        style={{
          marginTop: 12,
          width: "100%",
          textAlign: "left",
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "10px 12px",
          borderRadius: 10,
          border: `1px solid ${QUALITY_COLORS[rec.zone]}`,
          background: `color-mix(in srgb, ${QUALITY_COLORS[rec.zone]} 12%, transparent)`,
          cursor: "pointer",
          fontFamily: "inherit",
        }}
      >
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>
            FOCUS NEXT
          </div>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontWeight: 800,
              fontSize: "var(--t-md)",
              color: QUALITY_COLORS[rec.zone],
            }}
          >
            {QUALITIES.find((q) => q.id === rec.zone)?.label}
          </div>
          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", marginTop: 2 }}>
            {rec.reason}
          </div>
        </div>
        <span
          style={{
            fontSize: "var(--t-xs)",
            fontWeight: 700,
            color: QUALITY_COLORS[rec.zone],
            flexShrink: 0,
          }}
        >
          Arm ›
        </span>
      </button>
    </div>
  );
}
