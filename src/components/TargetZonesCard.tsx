import { useState } from "react";
import { QUALITIES, ZONE_PROTOCOLS, zoneTarget } from "../lib/force-curve";
import type { ForceCurveModel, TrainingQuality } from "../lib/force-curve";
import { buildTimeline, timelineDurationS } from "../lib/protocol";
import type { TindeqPreset } from "../types";
import type { GaugeTarget } from "./ForceCurveCard";
import InfoDot from "./InfoDot";

/// A selected zone = a load band for the live chart + a full guided protocol
/// (pull time / rest / reps / sets) for the fullscreen countdown.
export interface ZoneSelection {
  target: GaugeTarget;
  protocol: TindeqPreset;
}

interface Props {
  tag: string;
  model: ForceCurveModel | null;
  selected: ZoneSelection | null;
  onSelect: (sel: ZoneSelection | null) => void;
}

function fmt(sec: number): string {
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s === 0 ? `${m}m` : `${m}m${s}s`;
}

/// Training-zone target picker (POWER / STRENGTH / POW END / ENDURANCE),
/// anchored to the selected exercise's force-curve fit. Picking a zone arms
/// the band on the live gauge AND its guided timer (hold/rest/reps from the
/// zone's prescription). Alternate ticks L⇄R per rep; otherwise the global
/// side applies.
export default function TargetZonesCard({ tag, model, selected, onSelect }: Props) {
  const [quality, setQuality] = useState<TrainingQuality | null>(null);
  const [alternate, setAlternate] = useState(false);

  function build(q: TrainingQuality, alt: boolean): ZoneSelection | null {
    if (!model) return null;
    const t = zoneTarget(model, q);
    if (!t) return null;
    const zp = ZONE_PROTOCOLS[q];
    return {
      target: {
        kg: t.targetKg,
        lowKg: t.lowKg,
        highKg: t.highKg,
        workS: t.workS,
        label: `${t.label} · ${tag}`,
      },
      protocol: {
        id: `zone:${q}`,
        name: `${t.label} · ${tag}`,
        holdS: zp.holdS,
        reps: zp.reps,
        sets: zp.sets,
        restRepsS: zp.restRepsS,
        restSetsS: zp.restSetsS,
        targetKg: t.targetKg,
        alternateSides: alt,
      },
    };
  }

  const active = quality !== null && selected !== null;
  const zoneT = model && quality ? zoneTarget(model, quality) : null;

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
        <span>Recommended · {tag}</span>
        <InfoDot topic="gaugeTarget" />
      </div>
      {!model ? (
        <div style={{ fontSize: 11, color: "var(--ink-faint)" }}>
          Zones unlock once this exercise's force curve is computed (a few
          recordings, ideally one 30s+ hold).
        </div>
      ) : (
        <>
          <div style={{ display: "flex", gap: 5, flexWrap: "wrap" }}>
            {QUALITIES.map((q) => {
              const isActive = active && quality === q.id;
              return (
                <button
                  key={q.id}
                  className="tag"
                  onClick={() => {
                    if (isActive) {
                      setQuality(null);
                      onSelect(null);
                      return;
                    }
                    setQuality(q.id);
                    onSelect(build(q.id, alternate));
                  }}
                  style={{
                    background: isActive ? "var(--primary)" : "var(--surface-1)",
                    color: isActive ? "#ffffff" : "var(--ink-muted)",
                    border: `1px solid ${isActive ? "var(--primary)" : "var(--border)"}`,
                    cursor: "pointer",
                    fontFamily: "Inter, sans-serif",
                  }}
                >
                  {q.label}
                </button>
              );
            })}
          </div>
          {active && zoneT && selected ? (
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
                  {zoneT.targetKg.toFixed(1)} kg
                </span>
                <span style={{ fontSize: 11, color: "var(--ink-muted)" }}>
                  ({zoneT.lowKg.toFixed(1)}–{zoneT.highKg.toFixed(1)})
                </span>
              </div>
              {/* The prescription the guided timer will run */}
              <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 4 }}>
                Timer: hold {fmt(selected.protocol.holdS)} · rest{" "}
                {fmt(selected.protocol.restRepsS)} × {selected.protocol.reps} reps
                {selected.protocol.sets > 1 &&
                  ` · ${selected.protocol.sets} sets (${fmt(selected.protocol.restSetsS)} between)`}{" "}
                · total {fmt(timelineDurationS(buildTimeline(selected.protocol, { switchS: 3 })))}
              </div>
              <label
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  marginTop: 8,
                  fontSize: 11,
                  color: "var(--ink-muted)",
                  cursor: "pointer",
                }}
              >
                <input
                  type="checkbox"
                  checked={alternate}
                  onChange={(e) => {
                    setAlternate(e.target.checked);
                    if (quality) onSelect(build(quality, e.target.checked));
                  }}
                />
                Alternate left ⇄ right each rep (otherwise uses the selected side)
              </label>
            </div>
          ) : (
            <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 8 }}>
              Pick a zone — it arms the band on the live gauge and a guided
              hold/rest timer from its prescription.
            </div>
          )}
        </>
      )}
    </div>
  );
}
