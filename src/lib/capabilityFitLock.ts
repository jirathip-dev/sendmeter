import type { CapabilityFit } from "./capabilityModel";

/** Render-time lock: active runs keep their exact Hill parameters. */
export function nextLockedCapabilityFit(
  runActive: boolean,
  live: CapabilityFit | null,
  locked: CapabilityFit | null,
): CapabilityFit | null {
  return runActive ? locked : live;
}
