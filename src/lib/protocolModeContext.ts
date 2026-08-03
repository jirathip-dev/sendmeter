import type { ForceCapacityModality, TindeqPreset, TindeqProtocolMode } from "../types";

export const FORCE_PROTOCOL_MODE_KEY = "sendmeter:force-protocol-mode";

export function presetModality(preset: Pick<TindeqPreset, "protocolMode">): ForceCapacityModality {
  return preset.protocolMode === "reverse_action" ? "reverse_action" : "static";
}

export function protocolModeFor(modality: ForceCapacityModality): TindeqProtocolMode {
  return modality === "reverse_action" ? "reverse_action" : "hold";
}

export function canSwitchProtocolModality(
  current: ForceCapacityModality,
  next: ForceCapacityModality,
  runActive: boolean,
): boolean {
  return !runActive && current !== next;
}

type ModeStorage = Pick<Storage, "getItem" | "setItem">;

export function loadProtocolModality(storage?: ModeStorage): ForceCapacityModality {
  try {
    return (storage ?? localStorage).getItem(FORCE_PROTOCOL_MODE_KEY) === "reverse_action"
      ? "reverse_action"
      : "static";
  } catch {
    return "static";
  }
}

export function saveProtocolModality(
  modality: ForceCapacityModality,
  storage?: ModeStorage,
): void {
  try {
    (storage ?? localStorage).setItem(FORCE_PROTOCOL_MODE_KEY, modality);
  } catch {
    // Storage may be unavailable (private/locked-down webviews). The in-memory
    // selector remains fully functional for this mount.
  }
}
