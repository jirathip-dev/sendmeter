import type { TindeqStatus } from "../hooks/useTindeq";

export type ActiveTindeqStatus = Extract<TindeqStatus, "connected" | "armed" | "measuring">;

export function isActiveTindeqStatus(status: TindeqStatus): status is ActiveTindeqStatus {
  return status === "connected" || status === "armed" || status === "measuring";
}

/** Sensorless execution is an alternative to establishing a device session,
 * not a second action inside an active Progressor card. */
export function sensorlessLaunchAvailable(status: TindeqStatus): boolean {
  return status === "idle" || status === "unsupported";
}
