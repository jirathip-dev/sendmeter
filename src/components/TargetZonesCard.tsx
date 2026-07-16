import { useState } from "react";
import { QUALITIES, zoneTarget } from "../lib/force-curve";
import type { ForceCurveModel, TrainingQuality } from "../lib/force-curve";
import type { GaugeTarget } from "./ForceCurveCard";
import InfoDot from "./InfoDot";

interface Props {
  tag: string;
  model: ForceCurveModel | null;
  selected: GaugeTarget | null;
  onSelect: (t: GaugeTarget | null) => void;
}

/// Training-zone target picker (POWER / STRENGTH / POW END / ENDURANCE),
/// anchored to the selected tag's force-curve fit. Picking a zone arms it as
/// the gauge target (band + line on the live trace).
export default function TargetZonesCard({ tag, model, selected, onSelect }: Props) {
  const [quality, setQuality] = useState<TrainingQuality | null>(null);
  const target = model && quality ? zoneTarget(model, quality) : null;

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div
        className="label-eyebrow"
        style={{
          marginBottom: 8,
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
        }}
      >
        <span>Gauge target · {tag}</span>
        <InfoDot topic="gaugeTarget" />
      </div>
      {!model ? (
        <div style={{ fontSize: 11, color: "var(--ink-faint)" }}>
          Zones unlock once this tag's force curve is computed (a few
          recordings, ideally one 30s+ hold).
        </div>
      ) : (
        <>
          <div style={{ display: "flex", gap: 5, flexWrap: "wrap" }}>
            {QUALITIES.map((q) => {
              const active = quality === q.id && selected !== null;
              return (
                <button
                  key={q.id}
                  className="tag"
                  onClick={() => {
                    if (active) {
                      setQuality(null);
                      onSelect(null);
                      return;
                    }
                    setQuality(q.id);
                    const t = zoneTarget(model, q.id);
                    onSelect(
                      t
                        ? {
                            kg: t.targetKg,
                            lowKg: t.lowKg,
                            highKg: t.highKg,
                            workS: t.workS,
                            label: `${t.label} · ${tag}`,
                          }
                        : null,
                    );
                  }}
                  style={{
                    background: active ? "var(--primary)" : "var(--surface-1)",
                    color: active ? "#ffffff" : "var(--ink-muted)",
                    border: `1px solid ${active ? "var(--primary)" : "var(--border)"}`,
                    cursor: "pointer",
                    fontFamily: "Inter, sans-serif",
                  }}
                >
                  {q.label}
                </button>
              );
            })}
          </div>
          {target && selected ? (
            <div style={{ marginTop: 10 }}>
              <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
                <span
                  style={{
                    fontFamily: "Inter, sans-serif",
                    fontSize: 22,
                    fontWeight: 800,
                    color: "var(--success)",
                  }}
                >
                  {target.targetKg.toFixed(1)} kg
                </span>
                <span style={{ fontSize: 11, color: "var(--ink-muted)" }}>
                  ({target.lowKg.toFixed(1)}–{target.highKg.toFixed(1)}) ·{" "}
                  {target.workS}s work
                </span>
              </div>
              <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 3 }}>
                {target.protocol}
              </div>
            </div>
          ) : (
            <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 8 }}>
              Pick a zone to show its band on the live gauge.
            </div>
          )}
        </>
      )}
    </div>
  );
}
