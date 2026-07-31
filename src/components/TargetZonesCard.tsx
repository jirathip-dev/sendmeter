import { useState } from "react";
import {
  QUALITIES,
  ZONE_INTENSITY,
  prehabTarget,
  warmupTarget,
  zoneTarget,
} from "../lib/force-curve";
import type { ForceCurveModel } from "../lib/force-curve";
import { selectionHaptic } from "../lib/haptics";
import { buildTimeline, holdsSummary, timelineDurationS } from "../lib/protocol";
import {
  QUALITY_COLORS,
  buildPrehabSelection,
  buildWarmupSelection,
  buildZoneSelection,
  selectedQuality,
  type ZoneSelection,
} from "../lib/zoneSelection";

import BoxChip from "./BoxChip";
import InfoDot from "./InfoDot";

interface Props {
  tag: string;
  model: ForceCurveModel | null;
  /// Best effort peak for %-of-PR maintenance ramps. Kept separate from the
  /// force curve's best window average so the preview matches the timer.
  prKg: number | null;
  selected: ZoneSelection | null;
  onSelect: (sel: ZoneSelection | null) => void;
  /// The global session-intensity dial (SL-97b) — one value owned by
  /// ForceView (persisted + used to re-arm the zone), driven by the slider
  /// this card renders (#172). Scales recommended zones only.
  intensityPct: number;
  onIntensityChange: (pct: number) => void;
  /// #298 round 5: ForceView locks the gauge inputs (tag/side/selection/
  /// intensity/PR) for the whole duration of a run — any of the zone chips,
  /// the alternate-sides checkbox, the slider, or Clear moving mid-run would
  /// mean the set you finish isn't the set you started. Disables all of
  /// them rather than leaving a control that looks live but is inert.
  locked: boolean;
  /// Unarm via ForceView's `clearProtocol` (#298) — drops the persisted
  /// preset key too, not just this card's own `selected` prop, so a stale
  /// key can't re-arm a preset on the next mount.
  onClear: () => void;
}

function fmt(sec: number): string {
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s === 0 ? `${m}m` : `${m}m${s}s`;
}

/// Curve-derived protocol picker. The four trainable qualities and the
/// Warm-up/Prehab maintenance prescriptions share one card, but remain
/// separate semantic groups.
export default function TargetZonesCard({
  tag,
  model,
  prKg,
  selected,
  onSelect,
  intensityPct,
  onIntensityChange,
  locked,
  onClear,
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
  const warmupActive = selected?.protocol.id === "zone:warmup";
  const prehabActive = selected?.protocol.id === "zone:prehab";
  const maintenanceActive = warmupActive || prehabActive;
  const zoneT = model && quality ? zoneTarget(model, quality, intensityPct) : null;
  const warmupT = model && prKg ? warmupTarget(model, prKg) : null;
  const prehabT = model ? prehabTarget(model) : null;

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
          <div className="label-eyebrow" style={{ marginBottom: 6 }}>
            Training
          </div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {QUALITIES.map((q) => {
              const isActive = active && quality === q.id;
              return (
                <BoxChip
                  key={q.id}
                  label={q.label}
                  active={isActive}
                  color={QUALITY_COLORS[q.id]}
                  disabled={locked}
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
          {!maintenanceActive && (
            <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 12 }}>
              <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
                Intensity
              </span>
              <input
                type="range"
                aria-label="Session intensity"
                data-haptic="off"
                min={ZONE_INTENSITY.min}
                max={ZONE_INTENSITY.max}
                step={ZONE_INTENSITY.step}
                value={intensityPct}
                disabled={locked}
                onChange={(e) => {
                  const next = Number(e.target.value);
                  if (next === intensityPct) return;
                  selectionHaptic();
                  onIntensityChange(next);
                }}
                style={{
                  flex: 1,
                  minWidth: 0,
                  accentColor: heavy ? "var(--warning)" : "var(--primary)",
                  opacity: locked ? 0.5 : 1,
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
          )}
          <div
            style={{
              borderTop: "1px solid var(--border)",
              marginTop: 14,
              paddingTop: 12,
            }}
          >
            <div className="label-eyebrow" style={{ marginBottom: 6 }}>
              Maintenance
            </div>
            <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
              <BoxChip
                label="Warm-up"
                active={warmupActive}
                color="var(--primary)"
                disabled={locked || !warmupT}
                onClick={() => {
                  if (warmupActive) {
                    onClear();
                    return;
                  }
                  onSelect(buildWarmupSelection(model, tag, prKg ?? 0));
                }}
              />
              <BoxChip
                label="Prehab"
                active={prehabActive}
                color="var(--ink-muted)"
                disabled={locked || !prehabT}
                onClick={() => {
                  if (prehabActive) {
                    onClear();
                    return;
                  }
                  onSelect(buildPrehabSelection(model, tag));
                }}
              />
            </div>
            {(!warmupT || !prehabT) && (
              <div
                style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 6 }}
              >
                Maintenance protocols need a usable force-curve target.
              </div>
            )}
          </div>
          {locked && (
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 4 }}>
              Locked while measuring — applies to your next run.
            </div>
          )}
          {warmupActive && warmupT && selected ? (
            <div style={{ marginTop: 10 }}>
              <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
                <span
                  style={{
                    fontFamily: "Inter, sans-serif",
                    fontSize: 22,
                    fontWeight: 800,
                    color: "var(--primary)",
                  }}
                >
                  {warmupT.targetKg.toFixed(1)} → {warmupT.finalTargetKg.toFixed(1)} kg
                </span>
              </div>
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 4 }}>
                {holdsSummary(selected.protocol)} holds × {selected.protocol.reps} reps · {" "}
                {selected.protocol.sets} sets · 40% → 55% → 70% PR · about {" "}
                {fmt(timelineDurationS(buildTimeline(selected.protocol, { switchS: 3 })))}
              </div>
              <div
                style={{
                  fontSize: "var(--t-2xs)",
                  color: "var(--ink-faint)",
                  marginTop: 8,
                }}
              >
                Progressive primer · do general movement and easy climbing first · excluded from training balance
              </div>
              <button
                onClick={onClear}
                disabled={locked}
                className="glass-pill"
                style={{ marginTop: 10, padding: "6px 14px", fontSize: "var(--t-2xs)" }}
              >
                Clear — free hold
              </button>
            </div>
          ) : prehabActive && prehabT && selected ? (
            <div style={{ marginTop: 10 }}>
              <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
                <span
                  style={{
                    fontFamily: "Inter, sans-serif",
                    fontSize: 22,
                    fontWeight: 800,
                    color: "var(--ink-muted)",
                  }}
                >
                  {prehabT.targetKg.toFixed(1)} kg
                </span>
                <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
                  ({prehabT.lowKg.toFixed(1)}–{prehabT.highKg.toFixed(1)})
                </span>
              </div>
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 4 }}>
                {fmt(selected.protocol.holdS)} × {selected.protocol.reps} ·{" "}
                {fmt(selected.protocol.restRepsS)} rest · about{" "}
                {fmt(timelineDurationS(buildTimeline(selected.protocol, { switchS: 3 })))}
              </div>
              <div
                style={{
                  fontSize: "var(--t-2xs)",
                  color: "var(--ink-faint)",
                  marginTop: 8,
                }}
              >
                Fixed dose · below critical force · excluded from training balance
              </div>
              <button
                onClick={onClear}
                disabled={locked}
                className="glass-pill"
                style={{ marginTop: 10, padding: "6px 14px", fontSize: "var(--t-2xs)" }}
              >
                Clear — free hold
              </button>
            </div>
          ) : active && zoneT && selected ? (
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
              {/* The prescription the guided timer will run. A single-rep
                  protocol (endurance, #320: 1 rep × 8 sets) skips the
                  "rest × N reps" clause — nothing to say about a rep count
                  of one. */}
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 4 }}>
                Timer: hold {fmt(selected.protocol.holdS)}
                {selected.protocol.reps > 1 &&
                  ` · rest ${fmt(selected.protocol.restRepsS)} × ${selected.protocol.reps} reps`}
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
                  disabled={locked}
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
              {/* #298: an explicit unarm, alongside re-tapping the active
                  chip above — easier to spot than "tap the thing you already
                  tapped again". Routes through ForceView's `clearProtocol`
                  (round 4), same as the fullscreen's identical button — not
                  `onSelect(null)`, which leaves the persisted preset key
                  behind for `PresetManager` to resurrect on the next mount.
                  #298 round 5 (finding 4): disabled while locked — tapping
                  Clear mid-run must not silently apply once the run ends. */}
              <button
                onClick={onClear}
                disabled={locked}
                className="glass-pill"
                style={{ marginTop: 10, padding: "6px 14px", fontSize: "var(--t-2xs)" }}
              >
                Clear — free hold
              </button>
            </div>
          ) : !maintenanceActive ? (
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8 }}>
              Pick a protocol — it arms the live-gauge band and guided timer.
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}
