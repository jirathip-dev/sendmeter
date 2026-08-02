import type { DynamometerCapabilities } from "./dynamometer";
import type { ForceExecutionMethod, TindeqProtocolMode, TindeqSide } from "../types";

export type ForceMeasurementMode = "static" | "movement";

/** Presentation mapping only. The armed protocol selects this value; equipment
 * setup never acts as an independent Static/Movement switch. */
export function forceProtocolMode(mode: ForceMeasurementMode): TindeqProtocolMode {
  return mode === "movement" ? "reverse_action" : "hold";
}

export function forceMeasurementMode(mode: TindeqProtocolMode): ForceMeasurementMode {
  return mode === "reverse_action" ? "movement" : "static";
}

export interface ForceSetupMetadata {
  equipment: string;
  preload: string;
  attachment: string;
  position: string;
}

export interface ForceSetupInputs extends ForceSetupMetadata {
  mode: ForceMeasurementMode;
  executionMethod?: ForceExecutionMethod;
  exercise: string;
  side: TindeqSide;
}

export interface ForceSetupConfirmation {
  validityKey: string;
  confirmedAt: string;
}

export interface ForceSetupMemory {
  version: 1;
  autoShow: boolean;
  /** Legacy #401 field retained so existing local memory remains readable.
   * #422 derives the visible mode from the armed protocol and never writes it. */
  selectedMode: ForceMeasurementMode;
  seenModes: ForceMeasurementMode[];
  metadataByContext: Record<string, ForceSetupMetadata>;
  sideByContext: Record<string, TindeqSide>;
  confirmations: Record<string, ForceSetupConfirmation>;
}

export const EMPTY_FORCE_SETUP_METADATA: ForceSetupMetadata = {
  equipment: "",
  preload: "",
  attachment: "",
  position: "",
};

export function emptyForceSetupMemory(): ForceSetupMemory {
  return {
    version: 1,
    autoShow: true,
    selectedMode: "static",
    seenModes: [],
    metadataByContext: {},
    sideByContext: {},
    confirmations: {},
  };
}

function normalized(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLocaleLowerCase();
}

/** Metadata follows exercise + mode. Side is deliberately excluded so a user
 * changing hands does not lose useful anchor/position notes. Confirmation is
 * stricter and includes side and equipment below. */
export function forceSetupContextKey(input: {
  mode: ForceMeasurementMode;
  exercise: string;
  executionMethod?: ForceExecutionMethod;
}): string {
  const legacy = [input.mode, normalized(input.exercise)];
  return JSON.stringify(input.executionMethod === "cadence_only" ? [...legacy, "cadence_only"] : legacy);
}

/** The exact inputs that make a setup confirmation valid. Optional notes are
 * not keys: editing prose must not erase unrelated configuration. Equipment is
 * a key because changing a spring/handle/edge materially changes the force path. */
export function forceSetupValidityKey(input: ForceSetupInputs): string {
  const legacy = [
    input.mode,
    normalized(input.exercise),
    input.side,
    normalized(input.equipment),
  ];
  return JSON.stringify(input.executionMethod === "cadence_only" ? [...legacy, "cadence_only"] : legacy);
}

export function isForceSetupConfirmed(
  memory: ForceSetupMemory,
  input: ForceSetupInputs,
): boolean {
  const key = forceSetupValidityKey(input);
  return memory.confirmations[key]?.validityKey === key;
}

export function shouldAutoShowForceSetup(
  memory: ForceSetupMemory,
  mode: ForceMeasurementMode,
): boolean {
  return memory.autoShow && !memory.seenModes.includes(mode);
}

export function rememberForceSetup(
  memory: ForceSetupMemory,
  input: ForceSetupInputs,
  confirmedAt: string,
): ForceSetupMemory {
  const validityKey = forceSetupValidityKey(input);
  const contextKey = forceSetupContextKey(input);
  return {
    ...memory,
    seenModes: memory.seenModes.includes(input.mode)
      ? memory.seenModes
      : [...memory.seenModes, input.mode],
    metadataByContext: {
      ...memory.metadataByContext,
      [contextKey]: {
        equipment: input.equipment.trim(),
        preload: input.preload.trim(),
        attachment: input.attachment.trim(),
        position: input.position.trim(),
      },
    },
    sideByContext: { ...memory.sideByContext, [contextKey]: input.side },
    confirmations: {
      ...memory.confirmations,
      [validityKey]: { validityKey, confirmedAt },
    },
  };
}

export function saveForceSetupDraft(
  memory: ForceSetupMemory,
  input: ForceSetupInputs,
): ForceSetupMemory {
  return {
    ...memory,
    metadataByContext: {
      ...memory.metadataByContext,
      [forceSetupContextKey(input)]: {
        equipment: input.equipment.trim(),
        preload: input.preload.trim(),
        attachment: input.attachment.trim(),
        position: input.position.trim(),
      },
    },
    sideByContext: {
      ...memory.sideByContext,
      [forceSetupContextKey(input)]: input.side,
    },
  };
}

export function markForceSetupSeen(
  memory: ForceSetupMemory,
  mode: ForceMeasurementMode,
): ForceSetupMemory {
  if (memory.seenModes.includes(mode)) return memory;
  return { ...memory, seenModes: [...memory.seenModes, mode] };
}

export function parseForceSetupMemory(raw: string | null): ForceSetupMemory {
  if (!raw) return emptyForceSetupMemory();
  try {
    const parsed = JSON.parse(raw) as Partial<ForceSetupMemory>;
    if (parsed.version !== 1) return emptyForceSetupMemory();
    const metadataByContext: Record<string, ForceSetupMetadata> = {};
    if (parsed.metadataByContext && typeof parsed.metadataByContext === "object") {
      for (const [key, value] of Object.entries(parsed.metadataByContext)) {
        if (!value || typeof value !== "object") continue;
        const item = value as Partial<ForceSetupMetadata>;
        metadataByContext[key] = {
          equipment: typeof item.equipment === "string" ? item.equipment : "",
          preload: typeof item.preload === "string" ? item.preload : "",
          attachment: typeof item.attachment === "string" ? item.attachment : "",
          position: typeof item.position === "string" ? item.position : "",
        };
      }
    }
    const sideByContext: Record<string, TindeqSide> = {};
    if (parsed.sideByContext && typeof parsed.sideByContext === "object") {
      for (const [key, value] of Object.entries(parsed.sideByContext)) {
        if (value === "" || value === "left" || value === "right" || value === "both") {
          sideByContext[key] = value;
        }
      }
    }
    return {
      version: 1,
      autoShow: parsed.autoShow !== false,
      selectedMode: parsed.selectedMode === "movement" ? "movement" : "static",
      seenModes: Array.isArray(parsed.seenModes)
        ? parsed.seenModes.filter(
            (mode): mode is ForceMeasurementMode =>
              mode === "static" || mode === "movement",
          )
        : [],
      metadataByContext,
      sideByContext,
      confirmations:
        parsed.confirmations && typeof parsed.confirmations === "object"
          ? parsed.confirmations
          : {},
    };
  } catch {
    return emptyForceSetupMemory();
  }
}

export interface ReadinessSample {
  atMs: number;
  kg: number;
}

export interface ForceReadinessState {
  connected: boolean;
  unloadedStable: boolean;
  signalStableNow: boolean;
  tareComplete: boolean;
  noTareAcknowledged: boolean;
  testLoadSeen: boolean;
  peakKg: number;
  targetReached: boolean;
  samples: ReadinessSample[];
}

export const READINESS_WINDOW_MS = 900;
export const UNLOADED_LIMIT_KG = 0.75;
export const STABILITY_RANGE_KG = 0.3;
export const TEST_LOAD_KG = 2;

export function emptyForceReadiness(connected = false): ForceReadinessState {
  return {
    connected,
    unloadedStable: false,
    signalStableNow: false,
    tareComplete: false,
    noTareAcknowledged: false,
    testLoadSeen: false,
    peakKg: 0,
    targetReached: false,
    samples: [],
  };
}

export function appendReadinessSample(
  state: ForceReadinessState,
  sample: ReadinessSample,
  targetKg: number | null,
): ForceReadinessState {
  const start = sample.atMs - READINESS_WINDOW_MS;
  const samples = [...state.samples, sample].filter((item) => item.atMs >= start);
  const spanMs = samples.length > 1 ? sample.atMs - samples[0]!.atMs : 0;
  const forces = samples.map((item) => Math.abs(item.kg));
  const range = forces.length ? Math.max(...forces) - Math.min(...forces) : Infinity;
  const unloadedStableNow =
    spanMs >= READINESS_WINDOW_MS * 0.8 &&
    forces.every((kg) => kg <= UNLOADED_LIMIT_KG) &&
    range <= STABILITY_RANGE_KG;
  const peakKg = Math.max(state.peakKg, Math.abs(sample.kg));
  return {
    ...state,
    unloadedStable: state.unloadedStable || unloadedStableNow,
    signalStableNow: unloadedStableNow,
    testLoadSeen: state.testLoadSeen || peakKg >= TEST_LOAD_KG,
    targetReached:
      state.targetReached || (targetKg !== null && targetKg > 0 && peakKg >= targetKg),
    peakKg,
    samples,
  };
}

export function markReadinessZeroed(
  state: ForceReadinessState,
  method: "tare" | "device-instructions",
): ForceReadinessState {
  return {
    ...state,
    tareComplete: method === "tare",
    noTareAcknowledged: method === "device-instructions",
    // The gradual test pull must happen after the zero step; an earlier load
    // cannot satisfy the ordered readiness sequence.
    testLoadSeen: false,
    targetReached: false,
    peakKg: 0,
  };
}

export interface TareDecision {
  visible: boolean;
  allowed: boolean;
  reason: string | null;
}

export function tareDecision(input: {
  capabilities: DynamometerCapabilities;
  connected: boolean;
  unloadedStable: boolean;
  currentKg: number;
  inFlight: boolean;
}): TareDecision {
  if (!input.capabilities.tare) return { visible: false, allowed: false, reason: null };
  if (!input.connected) return { visible: true, allowed: false, reason: "Connect the device first." };
  if (input.inFlight) return { visible: true, allowed: false, reason: "Taring…" };
  if (Math.abs(input.currentKg) > UNLOADED_LIMIT_KG) {
    return {
      visible: true,
      allowed: false,
      reason: "Unload the system before taring.",
    };
  }
  if (!input.unloadedStable) {
    return {
      visible: true,
      allowed: false,
      reason: "Wait for a stable unloaded signal.",
    };
  }
  return { visible: true, allowed: true, reason: null };
}

export function canConfirmForceSetup(input: {
  capabilities: DynamometerCapabilities;
  readiness: ForceReadinessState;
  equipmentConfirmed: boolean;
  positionConfirmed: boolean;
  sensor?: boolean;
}): boolean {
  if (input.sensor === false) {
    return input.equipmentConfirmed && input.positionConfirmed;
  }
  const zeroReady = input.capabilities.tare
    ? input.readiness.tareComplete
    : input.readiness.noTareAcknowledged;
  return (
    input.readiness.connected &&
    input.readiness.unloadedStable &&
    zeroReady &&
    input.readiness.testLoadSeen &&
    input.equipmentConfirmed &&
    input.positionConfirmed
  );
}

/** Mutable claim set by design: callers keep it in a ref, and this function
 * claims synchronously before their first await. */
export function claimForceSetupAction(claimed: Set<string>, action: string): boolean {
  if (claimed.has(action)) return false;
  claimed.add(action);
  return true;
}
