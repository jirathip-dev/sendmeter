import { prehabTarget } from "../lib/force-curve";
import type { ForceCurveModel } from "../lib/force-curve";
import { buildTimeline, timelineDurationS } from "../lib/protocol";
import { buildPrehabSelection, type ZoneSelection } from "../lib/zoneSelection";

import BoxChip from "./BoxChip";

interface Props {
  tag: string;
  model: ForceCurveModel | null;
  selected: ZoneSelection | null;
  onSelect: (sel: ZoneSelection | null) => void;
  /// #298-style lock: ForceView locks the gauge inputs for the whole duration
  /// of a run — arming/clearing Prehab mid-run must not be reachable any more
  /// than the recommended-zone chips are.
  locked: boolean;
  /// Unarm via ForceView's `clearProtocol` — drops the persisted preset key
  /// too, same as TargetZonesCard's own Clear.
  onClear: () => void;
}

function fmt(sec: number): string {
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s === 0 ? `${m}m` : `${m}m${s}s`;
}

/// Prehab (#325, split from #297 as Part B1) — a low-load, long-hold,
/// daily-repeatable finger-tendon maintenance protocol: 30s × 4 holds at
/// 0.70×CF (0.30×maxF as a fallback). Recorded under its own "prehab" zone
/// (see RecordedZone in force-curve.ts) so it's excluded from training
/// balance entirely, rather than being inferred back into training credit —
/// unlike TargetZonesCard's four zones, there's no intensity dial and no
/// alternate-sides option here: the dose is fixed by design (see
/// `buildPrehabSelection`'s own doc for why alternating never applies).
export default function PrehabCard({ tag, model, selected, onSelect, locked, onClear }: Props) {
  const active = selected?.protocol.id === "zone:prehab";
  const target = model ? prehabTarget(model) : null;

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="label-eyebrow" style={{ marginBottom: 8 }}>
        Maintenance · {tag}
      </div>
      {!target ? (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)" }}>
          Prehab unlocks once this exercise's force curve is computed (a few
          recordings, ideally one 30s+ hold).
        </div>
      ) : (
        <>
          <BoxChip
            label="Prehab"
            active={active}
            color="var(--ink-muted)"
            disabled={locked}
            onClick={() => {
              if (active) {
                onClear();
                return;
              }
              onSelect(buildPrehabSelection(model, tag));
            }}
          />
          {locked && (
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 4 }}>
              Locked while measuring — applies to your next run.
            </div>
          )}
          {active && selected ? (
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
                  {target.targetKg.toFixed(1)} kg
                </span>
                <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
                  ({target.lowKg.toFixed(1)}–{target.highKg.toFixed(1)})
                </span>
              </div>
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 4 }}>
                Timer: hold {fmt(selected.protocol.holdS)} · rest{" "}
                {fmt(selected.protocol.restRepsS)} × {selected.protocol.reps} reps · total{" "}
                {fmt(timelineDurationS(buildTimeline(selected.protocol, { switchS: 3 })))}
              </div>
              <div
                style={{
                  fontSize: "var(--t-2xs)",
                  color: "var(--ink-faint)",
                  marginTop: 8,
                  lineHeight: 1.5,
                }}
              >
                {target.basis}
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
          ) : (
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8 }}>
              A daily-repeatable maintenance hold, below your critical force —
              recorded separately from training balance.
            </div>
          )}
        </>
      )}
    </div>
  );
}
