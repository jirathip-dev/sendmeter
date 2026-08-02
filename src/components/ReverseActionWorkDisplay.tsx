import type { ReverseActionSegment } from "../lib/reverseAction";
import type { TargetZone } from "../lib/targetZoneCoach";
import type { TindeqSide } from "../types";

const ZONE = {
  unknown: { label: "FIND TARGET", symbol: "◆", color: "var(--ink-muted)" },
  below: { label: "BELOW", symbol: "↓", color: "var(--info)" },
  "in-zone": { label: "IN ZONE", symbol: "✓", color: "var(--success)" },
  above: { label: "ABOVE", symbol: "↑", color: "var(--danger)" },
} as const;

const WAIT = { label: "WAIT", symbol: "·", color: "var(--ink-muted)" } as const;

function directionLabel(segment: ReverseActionSegment | null, done: boolean): string {
  if (done) return "SET COMPLETE";
  if (!segment) return "GET READY";
  if (segment.phase === "move") return segment.direction === "out" ? "OUT" : "RETURN";
  return segment.phase === "setRest" ? "SET REST" : "GET READY";
}

interface Props {
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
}

/// The intentionally sparse, distance-readable working face for #400. The
/// detailed trace stays out of the primary hierarchy while a cadence set is
/// moving and returns after Stop/in History.
export default function ReverseActionWorkDisplay(props: Props) {
  const moving = props.segment?.phase === "move";
  const presentation = moving ? ZONE[props.zone] : WAIT;
  const phase = directionLabel(props.segment, props.done);
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        gap: 10,
        textAlign: "center",
        flex: 1,
        justifyContent: "center",
        minHeight: 0,
      }}
    >
      <div
        aria-live="assertive"
        style={{
          color: moving ? "var(--success)" : "var(--warning)",
          fontFamily: "Inter, sans-serif",
          fontWeight: 900,
          fontSize: "clamp(2.4rem, 14vw, 4.8rem)",
          letterSpacing: "0.1em",
          lineHeight: 0.95,
        }}
      >
        {phase}
      </div>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontWeight: 850,
          fontVariantNumeric: "tabular-nums",
          fontSize: "clamp(3.4rem, 22vw, 7rem)",
          lineHeight: 0.9,
          color: "var(--ink)",
        }}
      >
        {moving ? props.currentKg.toFixed(1) : Math.max(0, props.remainingS ?? 0).toFixed(1)}
        <span style={{ fontSize: "clamp(1rem, 5vw, 1.7rem)", color: "var(--ink-muted)" }}>
          {moving ? " kg" : "s"}
        </span>
      </div>
      <div
        role="meter"
        aria-label="Reverse Action force target"
        aria-valuemin={0}
        aria-valuemax={Math.max(props.highKg * 1.5, props.currentKg, 1)}
        aria-valuenow={Math.max(0, props.currentKg)}
        aria-valuetext={`${presentation.label}; target ${props.lowKg.toFixed(1)} to ${props.highKg.toFixed(1)} kilograms`}
        style={{
          alignSelf: "stretch",
          borderRadius: 18,
          padding: "13px 16px",
          background: `color-mix(in srgb, ${presentation.color} 18%, var(--surface-1))`,
          border: `3px solid color-mix(in srgb, ${presentation.color} 70%, transparent)`,
        }}
      >
        <div
          style={{
            color: presentation.color,
            fontFamily: "Inter, sans-serif",
            fontWeight: 900,
            fontSize: "clamp(1.8rem, 9vw, 3rem)",
            letterSpacing: "0.08em",
            lineHeight: 1,
          }}
        >
          <span aria-hidden="true">{presentation.symbol} </span>
          {presentation.label}
        </div>
        <div style={{ marginTop: 6, color: "var(--ink)", fontWeight: 750 }}>
          TARGET {props.targetKg.toFixed(1)} kg · {props.lowKg.toFixed(1)}–{props.highKg.toFixed(1)}
        </div>
      </div>
      <div
        style={{
          color: "var(--ink-muted)",
          fontSize: "clamp(1rem, 4.5vw, 1.35rem)",
          fontWeight: 750,
        }}
      >
        {props.segment?.phase === "move"
          ? `REP ${props.segment.rep}/${props.reps} · SET ${props.segment.set}/${props.sets}`
          : props.done
            ? `${props.sets}/${props.sets} SETS`
            : `SET ${props.segment?.set ?? 1}/${props.sets}`}
        {props.side ? ` · ${props.side.toUpperCase()}` : ""}
        {moving && props.remainingS !== null ? ` · ${props.remainingS.toFixed(1)}s` : ""}
      </div>
    </div>
  );
}
