import { useEffect, useRef } from "react";
import type { ForceMeasurementMode } from "../lib/forceSetup";
import ForcePathDiagram from "./ForcePathDiagram";
import Sheet from "./Sheet";

interface Props {
  mode: ForceMeasurementMode;
  sensor: boolean;
  onClose: () => void;
}

const MODE_COPY = {
  static: {
    title: "Static hold",
    support: "Isometric",
    instruction: "Keep your chosen setup at its marked reference positions. Build force smoothly and hold.",
  },
  movement: {
    title: "Movement set",
    support: "Fixed-contact movement",
    instruction: "Keep the resisted contact point at its reference mark while moving smoothly between your other markers.",
  },
} as const;

/** Informational equipment guidance only. It deliberately does not inspect,
 * approve, persist, or gate the user's physical setup. */
export default function ForceSetupGuide({ mode, sensor, onClose }: Props) {
  const headingRef = useRef<HTMLHeadingElement | null>(null);

  useEffect(() => {
    queueMicrotask(() => headingRef.current?.focus());
  }, []);

  const copy = MODE_COPY[mode];
  return (
    <Sheet onClose={onClose} fullHeight className="force-setup-sheet">
      <article className="force-setup-guide" role="dialog" aria-modal="true" aria-labelledby="force-setup-guide-title">
        <header className="force-setup-guide-header">
          <div>
            <div className="label-eyebrow">How to set up</div>
            <h2 id="force-setup-guide-title" tabIndex={-1} ref={headingRef}>
              {copy.title} <span className="force-setup-support">· {copy.support}</span>
            </h2>
          </div>
          <button type="button" className="modal-x" onClick={onClose} aria-label="Close setup guidance">×</button>
        </header>

        <div className="force-setup-guide-body">
          <div className="force-guide-note">
            <strong>{sensor ? "Sensor" : "Cadence only"}</strong><br />
            {copy.instruction}
          </div>

          {sensor && <ForcePathDiagram mode={mode} />}

          <section aria-labelledby="force-equipment-principles">
            <h3 id="force-equipment-principles">Equipment principles</h3>
            <ul className="force-setup-list">
              <li>Follow the equipment manufacturers' instructions and use anchors, handles, springs, and connectors rated for the expected load.</li>
              {sensor ? (
                <>
                  <li>Keep the sensor inline with the applied force. Avoid twisting, sideways loading, and cable interference.</li>
                  <li>Unload the system completely before using the gauge's tare control.</li>
                </>
              ) : (
                <li>Keep connectors and anchors in their intended load path. The clock guides cadence but does not measure equipment resistance.</li>
              )}
              {mode === "movement" && <li>Keep the movement area clear and use an appropriate tether or clear impact area for compliant or spring setups.</li>}
            </ul>
          </section>

          <section aria-labelledby="force-repeatable-position">
            <h3 id="force-repeatable-position">Make the setup repeatable</h3>
            <ul className="force-setup-list">
              <li>Use the same exercise grip or handle, side, body or foot position, and direction of force.</li>
              <li>{mode === "movement" ? "Mark both movement endpoints and keep the path clear of pinch or impact hazards." : "Mark the joint or body position used for the static hold."}</li>
              {mode === "movement" && <li>Move smoothly through your chosen range. Jerking to chase a target can create misleading force peaks.</li>}
            </ul>
          </section>

          {!sensor && (
            <p className="force-guide-caution">Cadence only has no force sensor, target band, tare, or movement detection. Equipment resistance is whatever your setup provides.</p>
          )}
          <p className="force-guide-caution">This guidance cannot verify an anchor, movement, or technique as safe. Use a setup you already know is appropriate for you and stay clear of pinch and impact paths.</p>
        </div>
      </article>
    </Sheet>
  );
}
