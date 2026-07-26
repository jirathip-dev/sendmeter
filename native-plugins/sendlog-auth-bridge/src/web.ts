import { WebPlugin } from "@capacitor/core";
import type { SendLogAuthBridgePlugin, WatchBuildInfo } from "./definitions";

/// No paired watch to relay to from a browser — all three methods are no-ops.
export class SendLogAuthBridgeWeb extends WebPlugin implements SendLogAuthBridgePlugin {
  async setSession(): Promise<void> {}
  async clearSession(): Promise<void> {}
  /// A browser has no WatchConnectivity at all, which is neither "not paired"
  /// nor "not reported" — callers skip the row entirely on web (see
  /// `loadWatchBuildInfo`); `supported: false` is what says so.
  async getWatchInfo(): Promise<WatchBuildInfo> {
    return {
      status: "not-paired",
      supported: false,
      activated: false,
      paired: false,
      appInstalled: false,
    };
  }
}
