import type {
  ForceMeasurementMode,
  ForceSetupInputs,
} from "../lib/forceSetup";

interface Props {
  setup: ForceSetupInputs;
  confirmed: boolean;
  targetKg: number | null;
  locked: boolean;
  compact?: boolean;
  onMode: (mode: ForceMeasurementMode) => void;
  onOpenGuide: () => void;
}

const MODES: { value: ForceMeasurementMode; title: string; support: string }[] = [
  { value: "static", title: "Static hold", support: "isometric" },
  { value: "movement", title: "Movement set", support: "Reverse Action" },
];

export default function ForceSetupSummary({
  setup,
  confirmed,
  targetKg,
  locked,
  compact = false,
  onMode,
  onOpenGuide,
}: Props) {
  const selected = MODES.find((item) => item.value === setup.mode)!;
  const details = [
    setup.equipment.trim() || "equipment not named",
    setup.side ? setup.side[0]!.toUpperCase() + setup.side.slice(1) : "side not set",
    targetKg && targetKg > 0 ? `${targetKg.toFixed(1)} kg target` : null,
  ].filter(Boolean);

  if (compact) {
    return (
      <div className="force-setup-summary compact">
        <div>
          <strong>{selected.title}</strong>
          <span> · {details.join(" · ")}</span>
        </div>
        <button type="button" className="glass-pill" onClick={onOpenGuide}>
          {confirmed ? "Setup checked · View guide" : "Check setup"}
        </button>
      </div>
    );
  }

  return (
    <section className="force-setup-summary" aria-labelledby="force-setup-summary-title">
      <div className="force-setup-summary-head">
        <div>
          <div className="label-eyebrow" id="force-setup-summary-title">Measurement setup</div>
          <div className={`force-setup-state ${confirmed ? "checked" : "needs-check"}`}>
            {confirmed ? "Setup checked" : "Needs confirmation"}
          </div>
        </div>
        <button type="button" className="glass-pill" onClick={onOpenGuide} disabled={locked}>
          {confirmed ? "Edit / view guide" : "How to set up"}
        </button>
      </div>
      <div className="force-mode-picker" role="radiogroup" aria-label="Measurement mode">
        {MODES.map((item) => (
          <button
            type="button"
            role="radio"
            aria-checked={setup.mode === item.value}
            className={setup.mode === item.value ? "selected" : ""}
            key={item.value}
            onClick={() => onMode(item.value)}
            disabled={locked}
          >
            <strong>{item.title}</strong>
            <span>{item.support}</span>
          </button>
        ))}
      </div>
      <p className="force-setup-summary-line">
        {selected.title} · {details.join(" · ")}
      </p>
    </section>
  );
}
