import type { TindeqProtocolMode } from "../types";

export type ForceMeasurementMode = "static" | "movement";

/** Presentation mapping only. The explicit protocol-list context selects the
 * informational equipment guidance; the guide never arms or gates a protocol. */
export function forceProtocolMode(mode: ForceMeasurementMode): TindeqProtocolMode {
  return mode === "movement" ? "reverse_action" : "hold";
}

export function forceMeasurementMode(mode: TindeqProtocolMode): ForceMeasurementMode {
  return mode === "reverse_action" ? "movement" : "static";
}
