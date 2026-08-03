import type { TindeqProtocolMode } from "../types";

export type ForceMeasurementMode = "static" | "movement";

/** Presentation mapping only. The armed protocol selects the informational
 * equipment guidance; the guide never arms, clears, or approves a protocol. */
export function forceProtocolMode(mode: ForceMeasurementMode): TindeqProtocolMode {
  return mode === "movement" ? "reverse_action" : "hold";
}

export function forceMeasurementMode(mode: TindeqProtocolMode): ForceMeasurementMode {
  return mode === "reverse_action" ? "movement" : "static";
}
