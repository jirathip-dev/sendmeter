import { useState } from "react";
import { QUALITIES, zoneTarget } from "../lib/force-curve";
import type { ForceCurveModel } from "../lib/force-curve";
import { buildTimeline, timelineDurationS } from "../lib/protocol";
import {
  QUALITY_COLORS,
  buildZoneSelection,
  selectedQuality,
  type ZoneSelection,
} from "../lib/zoneSelection";

import BoxChip from "./BoxChip";
import InfoDot from "./InfoDot";

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
  const [alternate, setAlternate] = useState(false);

  // Which zone is armed is derived from `selected` (its `zone:${q}` id) so the
  // SL-100 recommendation card arming the same `zoneSel` lights the right chip.
  const quality = selectedQuality(selected);
  const active = quality !== null;
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
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)" }}>
          Zones unlock once this exercise's force curve is computed (a few
          recordings, ideally one 30s+ hold).
        </div>
      ) : (
        <>
          {/* Same box-chip size as the tag/side pickers — one chip language
              across the tab; each zone keeps its hue. */}
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {QUALITIES.map((q) => {
              const isActive = active && quality === q.id;
              return (
                <BoxChip
                  key={q.id}
                  label={q.label}
                  active={isActive}
                  color={QUALITY_COLORS[q.id]}
                  onClick={() => {
                    if (isActive) {
                      onSelect(null);
                      return;
                    }
                    onSelect(buildZoneSelection(model, q.id, tag, alternate));
                  }}
                />
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
                    color: quality ? QUALITY_COLORS[quality] : "var(--success)",
                  }}
                >
                  {zoneT.targetKg.toFixed(1)} kg
                </span>
                <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
                  ({zoneT.lowKg.toFixed(1)}–{zoneT.highKg.toFixed(1)})
                </span>
              </div>
              {/* The prescription the guided timer will run */}
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 4 }}>
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
                  fontSize: "var(--t-xs)",
                  color: "var(--ink-muted)",
                  cursor: "pointer",
                }}
              >
                <input
                  type="checkbox"
                  checked={alternate}
                  onChange={(e) => {
                    setAlternate(e.target.checked);
                    if (quality)
                      onSelect(buildZoneSelection(model, quality, tag, e.target.checked));
                  }}
                />
                Alternate left ⇄ right each set (otherwise uses the selected side)
              </label>
            </div>
          ) : (
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8 }}>
              Pick a zone — it arms the band on the live gauge and a guided
              hold/rest timer from its prescription.
            </div>
          )}
        </>
      )}
    </div>
  );
}
