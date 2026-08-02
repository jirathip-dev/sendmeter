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
  onOpenGuide,
}: Props) {
  const selected = MODES.find((item) => item.value === setup.mode)!;
  const details = [
    setup.executionMethod === "cadence_only" ? "cadence only" : "sensor",
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
          {confirmed ? "Equipment checked · View" : "Check equipment"}
        </button>
      </div>
    );
  }

  return (
    <section className="force-setup-summary" aria-labelledby="force-setup-summary-title">
      <div className="force-setup-summary-head">
        <div>
          <div className="label-eyebrow" id="force-setup-summary-title">Equipment setup</div>
          <div className={`force-setup-state ${confirmed ? "checked" : "needs-check"}`}>
            {confirmed ? "Equipment checked" : "Not checked"}
          </div>
        </div>
        <button type="button" className="glass-pill" onClick={onOpenGuide} disabled={locked}>
          {confirmed ? "Edit / view" : "Check equipment"}
        </button>
      </div>
      <p className="force-setup-summary-line">
        {selected.title} · {details.join(" · ")}
      </p>
    </section>
  );
}
