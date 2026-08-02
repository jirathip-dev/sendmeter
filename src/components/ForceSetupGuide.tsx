import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { useTindeq } from "../hooks/useTindeq";
import {
  appendReadinessSample,
  canConfirmForceSetup,
  claimForceSetupAction,
  emptyForceReadiness,
  markReadinessZeroed,
  tareDecision,
  type ForceMeasurementMode,
  type ForceReadinessState,
  type ForceSetupInputs,
  type ForceSetupMetadata,
} from "../lib/forceSetup";
import type { TindeqSide } from "../types";
import ForcePathDiagram from "./ForcePathDiagram";
import Sheet from "./Sheet";
import TagSideEditor from "./TagSideEditor";

interface Props {
  tindeq: ReturnType<typeof useTindeq>;
  mode: ForceMeasurementMode;
  exercise: string;
  side: TindeqSide;
  allTags: string[];
  targetKg: number | null;
  autoShow: boolean;
  metadataForMode: (mode: ForceMeasurementMode) => ForceSetupMetadata;
  onMode: (mode: ForceMeasurementMode) => void;
  onTag: (tag: string) => void;
  onSide: (side: TindeqSide) => void;
  onSaveDraft: (setup: ForceSetupInputs) => void;
  onConfirm: (setup: ForceSetupInputs) => void;
  onAutoShow: (enabled: boolean) => void;
  onClose: () => void;
}

const MODE_COPY = {
  static: {
    title: "Static hold",
    support: "Isometric",
    instruction: "Keep the joint position still. Build force smoothly and hold the target.",
  },
  movement: {
    title: "Movement set",
    support: "Reverse Action",
    instruction: "Maintain the target force while moving through your marked range at the guided cadence.",
  },
} as const;

function StatusRow({ ok, children }: { ok: boolean; children: ReactNode }) {
  return (
    <div className={`force-readiness-row ${ok ? "pass" : "pending"}`}>
      <span aria-hidden="true">{ok ? "✓" : "○"}</span>
      <span>{children}</span>
    </div>
  );
}

export default function ForceSetupGuide({
  tindeq,
  mode,
  exercise,
  side,
  allTags,
  targetKg,
  autoShow,
  metadataForMode,
  onMode,
  onTag,
  onSide,
  onSaveDraft,
  onConfirm,
  onAutoShow,
  onClose,
}: Props) {
  const [step, setStep] = useState(0);
  const [draft, setDraft] = useState(() => metadataForMode(mode));
  const [equipmentConfirmed, setEquipmentConfirmed] = useState(false);
  const [positionConfirmed, setPositionConfirmed] = useState(false);
  const connected = ["connected", "checking", "armed", "measuring"].includes(tindeq.status);
  const [readiness, setReadiness] = useState<ForceReadinessState>(() =>
    emptyForceReadiness(connected),
  );
  const [tareInFlight, setTareInFlight] = useState(false);
  const headingRef = useRef<HTMLHeadingElement | null>(null);
  const readinessRef = useRef(readiness);
  const currentRef = useRef(tindeq.current);
  const tindeqRef = useRef(tindeq);
  const draftRef = useRef(draft);
  const modeRef = useRef(mode);
  const actionsRef = useRef(new Set<string>());
  const mountedRef = useRef(true);

  useLayoutEffect(() => {
    readinessRef.current = readiness;
    currentRef.current = tindeq.current;
    tindeqRef.current = tindeq;
    draftRef.current = draft;
    modeRef.current = mode;
  }, [readiness, tindeq, draft, mode]);

  useEffect(() => {
    queueMicrotask(() => headingRef.current?.focus());
  }, [step]);

  useEffect(() => {
    if (tindeq.status !== "checking") return;
    const sample = { atMs: performance.now(), kg: tindeq.current };
    queueMicrotask(() => {
      setReadiness((previous) => {
        const next = appendReadinessSample(previous, sample, targetKg);
        readinessRef.current = next;
        return next;
      });
    });
  }, [tindeq, targetKg]);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      const current = tindeqRef.current;
      if (current.status === "checking") void current.endReadinessCheck();
    };
  }, []);

  const setup = (): ForceSetupInputs => ({
    mode: modeRef.current,
    exercise,
    side,
    ...draftRef.current,
  });

  function chooseMode(next: ForceMeasurementMode) {
    onSaveDraft(setup());
    modeRef.current = next;
    const nextDraft = metadataForMode(next);
    draftRef.current = nextDraft;
    setDraft(nextDraft);
    setEquipmentConfirmed(false);
    setPositionConfirmed(false);
    setReadiness(emptyForceReadiness(connected));
    onMode(next);
  }

  function close() {
    onSaveDraft(setup());
    onClose();
  }

  async function startCheck() {
    if (!claimForceSetupAction(actionsRef.current, "start-check")) return;
    const current = tindeqRef.current;
    if (current.status !== "connected") {
      actionsRef.current.delete("start-check");
      return;
    }
    const reset = emptyForceReadiness(true);
    readinessRef.current = reset;
    setReadiness(reset);
    const started = await current.beginReadinessCheck();
    if (started && !mountedRef.current) {
      await current.endReadinessCheck();
      return;
    }
    if (!started) actionsRef.current.delete("start-check");
  }

  async function tare() {
    if (!claimForceSetupAction(actionsRef.current, "tare")) return;
    const current = tindeqRef.current;
    const decision = tareDecision({
      capabilities: current.capabilities,
      connected: current.status === "checking",
      unloadedStable: readinessRef.current.signalStableNow,
      currentKg: currentRef.current,
      inFlight: false,
    });
    if (!decision.allowed) {
      actionsRef.current.delete("tare");
      return;
    }
    setTareInFlight(true);
    const ok = await current.tare();
    if (ok && mountedRef.current) {
      setReadiness((previous) => {
        const next = markReadinessZeroed(previous, "tare");
        readinessRef.current = next;
        return next;
      });
    }
    if (mountedRef.current) setTareInFlight(false);
    actionsRef.current.delete("tare");
  }

  async function confirm() {
    if (!claimForceSetupAction(actionsRef.current, "confirm")) return;
    const snapshot = setup();
    const current = tindeqRef.current;
    if (current.status === "checking") await current.endReadinessCheck();
    if (!mountedRef.current) return;
    onConfirm(snapshot);
  }

  const readinessView = { ...readiness, connected };
  const tareState = tareDecision({
    capabilities: tindeq.capabilities,
    connected: tindeq.status === "checking",
    unloadedStable: readiness.signalStableNow,
    currentKg: tindeq.current,
    inFlight: tareInFlight,
  });
  const confirmEnabled = canConfirmForceSetup({
    capabilities: tindeq.capabilities,
    readiness: readinessView,
    equipmentConfirmed,
    positionConfirmed,
  });
  return (
    <Sheet onClose={close} fullHeight className="force-setup-sheet">
      <div className="force-setup-guide" role="dialog" aria-modal="true" aria-labelledby="force-setup-guide-title">
        <header className="force-setup-guide-header">
          <div>
            <div className="label-eyebrow">Force setup · {step + 1} of 3</div>
            <h2 id="force-setup-guide-title" tabIndex={-1} ref={headingRef}>
              {step === 0 ? "Choose how force is measured" : step === 1 ? "Make the setup repeatable" : "Check the live signal"}
            </h2>
          </div>
          <button type="button" className="modal-x" onClick={close} aria-label="Close setup guide">×</button>
        </header>

        <div className="force-setup-guide-body">
          {step === 0 && (
            <>
              <p>Choose the movement you intend to perform. The same equipment can produce a different measurement when the movement changes.</p>
              <div className="force-mode-cards" role="radiogroup" aria-label="Measurement mode">
                {(["static", "movement"] as const).map((value) => {
                  const copy = MODE_COPY[value];
                  return (
                    <button key={value} type="button" role="radio" aria-checked={mode === value} className={mode === value ? "selected" : ""} onClick={() => chooseMode(value)}>
                      <strong>{copy.title}</strong>
                      <span>{copy.support}</span>
                      <p>{copy.instruction}</p>
                    </button>
                  );
                })}
              </div>
              <ForcePathDiagram mode={mode} />
              <div className="force-guide-note">
                <strong>Force-path principle, not one prescribed rig.</strong> Keep the sensor inline and relatively stationary where the exercise permits. Avoid twisting, sideways load, and cable interference.
              </div>
              {mode === "movement" && (
                <p className="force-guide-caution">Maintain force through the marked range. Move smoothly; jerking to chase the target can create misleading peaks. The gauge records force, but this setup guide does not prescribe spring stiffness, range, or a clinical protocol.</p>
              )}
            </>
          )}

          {step === 1 && (
            <>
              <TagSideEditor tag={exercise} side={side} allTags={allTags} onTag={onTag} onSide={onSide} locked={false} />
              <div className="force-setup-fields">
                <label>
                  <span>{mode === "movement" ? "Spring / equipment nickname" : "Equipment nickname"}</span>
                  <input className="field" value={draft.equipment} onChange={(event) => setDraft({ ...draft, equipment: event.target.value })} placeholder={mode === "movement" ? "Blue spring + handle" : "Portable edge + handle"} />
                </label>
                <label>
                  <span>Anchor / attachment note</span>
                  <input className="field" value={draft.attachment} onChange={(event) => setDraft({ ...draft, attachment: event.target.value })} placeholder="Anchor point, connector, tether" />
                </label>
                <label>
                  <span>{mode === "movement" ? "Body position + endpoint markers" : "Body + joint position marker"}</span>
                  <textarea className="field" rows={2} value={draft.position} onChange={(event) => setDraft({ ...draft, position: event.target.value })} placeholder={mode === "movement" ? "Seat/foot mark; start and end positions" : "Seat/foot mark; joint angle or reach reference"} />
                </label>
                <label>
                  <span>Preload / starting-force note (optional)</span>
                  <input className="field" value={draft.preload} onChange={(event) => setDraft({ ...draft, preload: event.target.value })} placeholder="Your repeatable starting reference" />
                </label>
              </div>
              <div className="force-guide-checks">
                <label><input type="checkbox" checked={equipmentConfirmed} onChange={(event) => setEquipmentConfirmed(event.target.checked)} /> I inspected the anchor, handle, rated connectors{mode === "movement" ? ", spring/compliant element, and safety tether or clear area" : ""}; the cable is clear.</label>
                <label><input type="checkbox" checked={positionConfirmed} onChange={(event) => setPositionConfirmed(event.target.checked)} /> I marked a repeatable body position, grip, side, direction of force, and {mode === "movement" ? "both movement endpoints with a clear path" : "static joint/body position"}.</label>
              </div>
              <p className="force-guide-caution">A stable sensor signal cannot prove an anchor or movement is safe. Stay clear of pinch and impact paths and use components rated for the expected load.</p>
            </>
          )}

          {step === 2 && (
            <>
              <div className="force-device-status">
                <div><strong>{tindeq.deviceName}</strong><span>{connected ? "Connected" : "Not connected"}</span></div>
                <div><strong>Battery</strong><span>{tindeq.capabilities.lowBatteryWarning ? (tindeq.lowBattery ? "Low-battery warning" : "No low-battery warning reported") : "Not reported by this device"}</span></div>
              </div>
              {!connected && (
                <button type="button" className="btn-primary" onClick={() => void tindeq.connect()} disabled={tindeq.status === "connecting"}>{tindeq.status === "connecting" ? "Connecting…" : `Connect ${tindeq.deviceName}`}</button>
              )}
              {tindeq.status === "connected" && (
                <button type="button" className="btn-primary" onClick={() => void startCheck()}>Start live readiness check</button>
              )}
              {tindeq.status === "checking" && (
                <>
                  <div className="force-live-reading" role="meter" aria-label="Current force" aria-valuemin={0} aria-valuemax={Math.max(10, targetKg ?? 10, tindeq.current)} aria-valuenow={Math.max(0, tindeq.current)}>
                    <span>LIVE FORCE</span>
                    <strong>{tindeq.current.toFixed(1)} <small>kg</small></strong>
                    <em>{readiness.signalStableNow ? "Unloaded signal stable" : readiness.unloadedStable ? "Baseline passed · apply load gradually" : "Unload completely and keep still"}</em>
                  </div>
                  <StatusRow ok={readiness.unloadedStable}>Stable unloaded baseline observed</StatusRow>
                  {tareState.visible ? (
                    <div className="force-tare-control">
                      <button type="button" className="glass-pill" onClick={() => void tare()} disabled={!tareState.allowed || readiness.tareComplete}>{readiness.tareComplete ? "Tared" : tareInFlight ? "Taring…" : "Tare unloaded sensor"}</button>
                      {!readiness.tareComplete && <span>{tareState.reason ?? "Tare is manual and only enabled while the live unloaded signal is stable."}</span>}
                    </div>
                  ) : (
                    <label className="force-no-tare"><input type="checkbox" checked={readiness.noTareAcknowledged} onChange={(event) => setReadiness((previous) => event.target.checked ? markReadinessZeroed(previous, "device-instructions") : { ...previous, noTareAcknowledged: false })} /> This device cannot tare from Sendmeter. I followed its zero/offset instructions while the system was fully unloaded.</label>
                  )}
                  <StatusRow ok={readiness.testLoadSeen}>Apply a small load gradually (at least 2 kg), then unload</StatusRow>
                  <StatusRow ok={readiness.targetReached}>{targetKg && targetKg > 0 ? (readiness.targetReached ? `Configured ${targetKg.toFixed(1)} kg target was reached` : `Configured ${targetKg.toFixed(1)} kg target not reached in this small check — this does not block setup`) : "No force target configured; small-load response is enough"}</StatusRow>
                  <p className="force-guide-caution">Signal checks confirm connection and repeatability only. Bluetooth can still drop when the phone sleeps, the device moves out of range, or radio interference changes.</p>
                </>
              )}
              <div className="force-readiness-list" aria-live="polite">
                <StatusRow ok={connected}>Device connected</StatusRow>
                <StatusRow ok={equipmentConfirmed}>Equipment/path inspection confirmed</StatusRow>
                <StatusRow ok={positionConfirmed}>Position/range references confirmed</StatusRow>
              </div>
            </>
          )}
        </div>

        <footer className="force-setup-guide-footer">
          <label className="force-auto-show"><input type="checkbox" checked={!autoShow} onChange={(event) => onAutoShow(!event.target.checked)} /> Do not show automatically next time</label>
          <div>
            {step > 0 && <button type="button" className="btn-ghost" onClick={() => setStep(step - 1)}>Back</button>}
            {step < 2 ? (
              <button type="button" className="btn-primary" onClick={() => { onSaveDraft(setup()); setStep(step + 1); }}>Continue</button>
            ) : (
              <button type="button" className="btn-primary" disabled={!confirmEnabled} onClick={() => void confirm()}>Setup checked · Arm workout</button>
            )}
          </div>
        </footer>
      </div>
    </Sheet>
  );
}
