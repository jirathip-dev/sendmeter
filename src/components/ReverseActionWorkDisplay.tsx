import type { ReverseActionSegment } from "../lib/reverseAction";
import type { TargetZone } from "../lib/targetZoneCoach";
import type { TindeqSide } from "../types";

const ZONE = {
  unknown: { label: "FIND TARGET", color: "var(--ink-muted)" },
  below: { label: "BELOW", color: "var(--info)" },
  "in-zone": { label: "IN ZONE", color: "var(--success)" },
  above: { label: "ABOVE", color: "var(--danger)" },
} as const;

function instruction(segment: ReverseActionSegment | null, done: boolean): string {
  if (done) return "SET COMPLETE";
  if (!segment) return "PREPARE";
  if (segment.phase === "move") return segment.direction === "out" ? "OUT" : "RETURN";
  return segment.phase === "setRest" ? "SET REST" : "PREPARE";
}

export default function ReverseActionWorkDisplay(props: {
  currentKg: number;
  targetKg: number;
  lowKg: number;
  highKg: number;
  zone: TargetZone;
  segment: ReverseActionSegment | null;
  remainingS: number | null;
  done: boolean;
  reps: number;
  sets: number;
  side: TindeqSide;
}) {
  const moving = props.segment?.phase === "move";
  const zone = moving ? ZONE[props.zone] : ZONE.unknown;
  return <div style={{ flexShrink: 0, display: "grid", gap: 6, textAlign: "center" }}>
    <div style={{ display: "flex", alignItems: "baseline", justifyContent: "center", gap: 12 }}>
      <div aria-live="assertive" style={{ fontSize: "clamp(1.8rem, 9vw, 3.1rem)", fontWeight: 900, letterSpacing: ".08em", color: moving ? "var(--success)" : "var(--warning)", lineHeight: 1 }}>{instruction(props.segment, props.done)}</div>
      <div style={{ fontSize: "clamp(1.8rem, 9vw, 3.1rem)", fontWeight: 900, fontVariantNumeric: "tabular-nums", lineHeight: 1 }}>{Math.max(0, props.remainingS ?? 0).toFixed(1)}<span style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)" }}>s</span></div>
    </div>
    <div role="meter" aria-label="Reverse Action force target" aria-valuemin={0} aria-valuemax={Math.max(props.highKg * 1.5, props.currentKg, 1)} aria-valuenow={Math.max(0, props.currentKg)} aria-valuetext={`${zone.label}; target ${props.lowKg.toFixed(1)} to ${props.highKg.toFixed(1)} kilograms`} style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
      <div style={{ borderRadius: 12, padding: "7px 10px", background: "var(--surface-1)" }}>
        <div className="label-eyebrow">CURRENT</div>
        <div style={{ fontSize: "clamp(1.8rem, 10vw, 3.2rem)", fontWeight: 900, lineHeight: 1 }}>{props.currentKg.toFixed(1)}<span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}> kg</span></div>
      </div>
      <div style={{ borderRadius: 12, padding: "7px 10px", color: zone.color, background: `color-mix(in srgb, ${zone.color} 16%, var(--surface-1))`, border: `2px solid color-mix(in srgb, ${zone.color} 60%, transparent)` }}>
        <div className="label-eyebrow">ZONE</div>
        <div style={{ fontSize: "clamp(1.25rem, 6vw, 2rem)", fontWeight: 900, lineHeight: 1.25 }}>{moving ? zone.label : "WAIT"}</div>
      </div>
    </div>
    <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", fontWeight: 750 }}>
      TARGET {props.targetKg.toFixed(1)} kg · {props.lowKg.toFixed(1)}–{props.highKg.toFixed(1)} · REP {props.segment?.rep ?? 1}/{props.reps} · SET {props.segment?.set ?? 1}/{props.sets}{props.side ? ` · ${props.side.toUpperCase()}` : ""}
    </div>
  </div>;
}
