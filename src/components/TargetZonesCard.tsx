import { useState } from "react";
import { QUALITIES, ZONE_INTENSITY, zoneTarget } from "../lib/force-curve";
import type { ForceCurveModel } from "../lib/force-curve";
import { selectionHaptic } from "../lib/haptics";
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
  /// The global session-intensity dial (SL-97b) — one value owned by
  /// ForceView (persisted + used to re-arm the zone), driven by the slider
  /// this card renders (#172). Scales recommended zones only.
  intensityPct: number;
  onIntensityChange: (pct: number) => void;
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
export default function TargetZonesCard({
  tag,
  model,
  selected,
  onSelect,
  intensityPct,
  onIntensityChange,
}: Props) {
  const [alternate, setAlternate] = useState(false);
  // Above the recommended load — the number, the slider fill and the note all
  // switch to the warning hue together (100% IS the recommendation, so it
  // stays neutral).
  const heavy = intensityPct > 100;

  // Which zone is armed is derived from `selected` (its `zone:${q}` id) so the
  // SL-100 recommendation card arming the same `zoneSel` lights the right chip.
  const quality = selectedQuality(selected);
  const active = quality !== null;
  const zoneT = model && quality ? zoneTarget(model, quality, intensityPct) : null;

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
                    onSelect(
                      buildZoneSelection(model, q.id, tag, alternate, intensityPct),
                    );
                  }}
                />
              );
            })}
          </div>
          {/* #172: the session-intensity dial sits on the card whose numbers
              it moves (SL-97b had it as a −/+ stepper in the "Protocol
              presets" header). Still ONE global value owned by ForceView —
              recommended zones only, custom presets are never rescaled. */}
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 12 }}>
            <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>Intensity</span>
            <input
              type="range"
              aria-label="Session intensity"
              // #171: this control ticks PER STEP below; mute it for the
              // delegated tap listener so a drag isn't also a tap.
              data-haptic="off"
              min={ZONE_INTENSITY.min}
              max={ZONE_INTENSITY.max}
              step={ZONE_INTENSITY.step}
              value={intensityPct}
              onChange={(e) => {
                const next = Number(e.target.value);
                // A range input only emits when its *stepped* value changes,
                // and this guard swallows a repeat of the same value — so the
                // tick is one per 5% step, not one per drag pixel.
                if (next === intensityPct) return;
                selectionHaptic();
                onIntensityChange(next);
              }}
              style={{
                flex: 1,
                minWidth: 0,
                accentColor: heavy ? "var(--warning)" : "var(--primary)",
              }}
            />
            <span
              style={{
                fontSize: "var(--t-xs)",
                fontWeight: 700,
                color: heavy ? "var(--warning)" : "var(--ink)",
                width: 34,
                textAlign: "right",
              }}
            >
              {intensityPct}%
            </span>
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
              {/* The contextual note for whatever the slider above is set to. */}
              {quality && intensityPct !== 100 && (
                <div
                  style={{
                    fontSize: "var(--t-2xs)",
                    color: heavy ? "var(--warning)" : "var(--ink-faint)",
                    marginTop: 8,
                  }}
                >
                  {intensityPct < 100
                    ? "Lighter load — hold times auto-extended along your force curve to keep the stimulus."
                    : "Above the recommended load — extra strain on fingers; only when fully warmed up."}
                </div>
              )}
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
                      onSelect(
                        buildZoneSelection(model, quality, tag, e.target.checked, intensityPct),
                      );
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
