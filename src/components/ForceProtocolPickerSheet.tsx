import type { ReactNode } from "react";
import type { TindeqPreset } from "../types";
import ProtocolBadge from "./ProtocolBadge";
import Sheet from "./Sheet";
import { MOVEMENT_STARTER_PRESET, protocolSummary } from "../lib/movementProtocol";

interface SelectedProtocolCardProps {
  protocol: TindeqPreset | null;
  locked: boolean;
  onChoose: () => void;
  onClear: () => void;
}

export function SelectedProtocolCard({ protocol, locked, onChoose, onClear }: SelectedProtocolCardProps) {
  return (
    <section className="card surface-force force-selected-protocol" aria-labelledby="selected-protocol-title">
      <div className="force-selected-protocol-head">
        <div>
          <div className="label-eyebrow" id="selected-protocol-title">Protocol</div>
          <div className="force-selected-protocol-name">{protocol?.name ?? "Choose a protocol"}</div>
        </div>
        {protocol && <ProtocolBadge mode={protocol.protocolMode ?? "hold"} />}
      </div>
      <div className="force-selected-protocol-copy">
        {protocol
          ? protocolSummary(protocol)
          : "Pick a suggested session or one of your own protocols before starting."}
      </div>
      <div className={`force-protocol-actions${protocol ? "" : " force-protocol-actions-single"}`}>
        <button type="button" className="btn-secondary force-choose-protocol" disabled={locked} onClick={onChoose}>
          {protocol ? "Choose another" : "Choose protocol"}
        </button>
        {protocol && (
          <button type="button" className="btn-ghost force-clear-protocol" disabled={locked} onClick={onClear}>
            Use free hold
          </button>
        )}
      </div>
      {locked && <div className="force-lock-note">Locked while armed or measuring.</div>}
    </section>
  );
}

interface ForceProtocolPickerSheetProps {
  selectedId: string | null;
  onClose: () => void;
  onMovementStarter: () => void;
  suggestedStatic: ReactNode;
  myProtocols: ReactNode;
}

export default function ForceProtocolPickerSheet({
  selectedId,
  onClose,
  onMovementStarter,
  suggestedStatic,
  myProtocols,
}: ForceProtocolPickerSheetProps) {
  const movementSelected = selectedId === MOVEMENT_STARTER_PRESET.id;
  return (
    <Sheet title="Choose protocol" subtitle="Suggested sessions and protocols you created" onClose={onClose} fullHeight className="force-protocol-sheet">
      <section aria-labelledby="suggested-protocols-title">
        <h3 className="force-sheet-section-title" id="suggested-protocols-title">Suggested</h3>
        {suggestedStatic}
        <button
          type="button"
          className="card surface-force force-suggested-movement"
          aria-pressed={movementSelected}
          onClick={onMovementStarter}
        >
          <span className="force-suggested-title-row">
            <span className="force-suggested-title">Movement Starter</span>
            <ProtocolBadge mode="reverse_action" />
          </span>
          <span className="force-suggested-kicker">Resisted movement · MOVEMENT</span>
          <span className="force-suggested-copy">3s concentric · 1s eccentric · 10 reps × 3 sets · 60s rest</span>
          <span className="force-suggested-help">Move through your range against resistance; the clock guides each rep.</span>
        </button>
      </section>
      <section aria-labelledby="my-protocols-title" className="force-my-protocols">
        <h3 className="force-sheet-section-title" id="my-protocols-title">My protocols</h3>
        {myProtocols}
      </section>
    </Sheet>
  );
}
