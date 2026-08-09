import type { ReverseActionToleranceMode } from "../types";
import NumInput from "./NumInput";
import {
  maxMovementRepsForCadence,
  movementSetDurationS,
  TINDEQ_MAX_MOVEMENT_SET_S,
} from "../lib/movementProtocol";

function NumberField({
  label,
  value,
  onChange,
  min,
  max,
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
  min: number;
  max: number;
}) {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 4, flex: 1, minWidth: 82 }}>
      <span
        style={{
          fontSize: "var(--t-eyebrow)",
          color: "var(--ink-muted)",
          textTransform: "uppercase",
          letterSpacing: "0.06em",
        }}
      >
        {label}
      </span>
      <NumInput
        value={value}
        onCommit={onChange}
        min={min}
        max={max}
        style={{ padding: "9px 10px", fontSize: "var(--t-base)" }}
      />
    </label>
  );
}

interface Props {
  reps: number;
  sets: number;
  cadenceOutS: number;
  cadenceReturnS: number;
  restSetsS: number;
  prepareS: number;
  toleranceMode: ReverseActionToleranceMode;
  toleranceValue: number;
  setupNote: string;
  onReps: (value: number) => void;
  onSets: (value: number) => void;
  onCadenceOutS: (value: number) => void;
  onCadenceReturnS: (value: number) => void;
  onRestSetsS: (value: number) => void;
  onPrepareS: (value: number) => void;
  onToleranceMode: (value: ReverseActionToleranceMode) => void;
  onToleranceValue: (value: number) => void;
  onSetupNote: (value: string) => void;
}

/// Reverse Action-specific editor kept out of PresetManager so #401 can add
/// instructional setup UI without coupling it to cadence/storage behavior.
export default function ReverseActionPresetFields(props: Props) {
  const setDurationS =
    props.reps * (props.cadenceOutS + props.cadenceReturnS);
  const maxReps = maxMovementRepsForCadence(
    props.cadenceOutS,
    props.cadenceReturnS,
  );
  const overCap = movementSetDurationS({
    protocolMode: "reverse_action",
    reps: props.reps,
    cadenceOutS: props.cadenceOutS,
    cadenceReturnS: props.cadenceReturnS,
  }) > TINDEQ_MAX_MOVEMENT_SET_S;
  return (
    <>
      <div style={{ display: "flex", gap: 8, marginTop: 12, flexWrap: "wrap" }}>
        <NumberField label="Reps / set" value={props.reps} onChange={props.onReps} min={1} max={maxReps} />
        <NumberField label="Sets" value={props.sets} onChange={props.onSets} min={1} max={20} />
      </div>
      <div style={{ display: "flex", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
        <NumberField
          label="Concentric s"
          value={props.cadenceOutS}
          onChange={props.onCadenceOutS}
          min={0.5}
          max={30}
        />
        <NumberField
          label="Eccentric s"
          value={props.cadenceReturnS}
          onChange={props.onCadenceReturnS}
          min={0.5}
          max={30}
        />
      </div>
      <div
        style={{
          fontSize: "var(--t-xs)",
          color: overCap ? "var(--danger)" : "var(--ink-muted)",
          marginTop: 6,
          lineHeight: 1.5,
        }}
      >
        One continuous {setDurationS}s set · max 30m per set for Progressor; clock-guided
        reps; force does not infer joint position.
        {overCap && " Lower reps or cadence before saving."}
      </div>
      <div style={{ display: "flex", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
        <NumberField
          label="Rest / set s"
          value={props.restSetsS}
          onChange={props.onRestSetsS}
          min={0}
          max={1200}
        />
        <NumberField
          label="Prepare s"
          value={props.prepareS}
          onChange={props.onPrepareS}
          min={0}
          max={60}
        />
      </div>

      <span className="field-label">Target tolerance</span>
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
        {(
          [
            ["percent", "% of target"],
            ["kg", "± kg"],
          ] as const
        ).map(([mode, label]) => (
          <button
            key={mode}
            className="tag tolerance-mode-option"
            data-selected={props.toleranceMode === mode ? "true" : "false"}
            onClick={() => props.onToleranceMode(mode)}
          >
            {label}
          </button>
        ))}
      </div>
      <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
        <NumberField
          label={props.toleranceMode === "percent" ? "Tolerance %" : "Tolerance kg"}
          value={props.toleranceValue}
          onChange={props.onToleranceValue}
          min={0.1}
          max={100}
        />
      </div>

      <span className="field-label">Setup note (optional)</span>
      <input
        className="field"
        value={props.setupNote}
        onChange={(event) => props.onSetupNote(event.target.value)}
        placeholder="Spring, preload, attachment or position markers"
      />
      <div
        style={{
          fontSize: "var(--t-2xs)",
          color: "var(--ink-faint)",
          marginTop: 6,
          lineHeight: 1.5,
        }}
      >
        Saved with each set. Equipment setup guidance is handled separately.
      </div>
    </>
  );
}
