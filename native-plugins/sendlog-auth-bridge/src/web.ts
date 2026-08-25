import { WebPlugin } from "@capacitor/core";
import type {
  SendLogAuthBridgePlugin,
  WatchBuildInfo,
  WorkoutCompletedMessage,
} from "./definitions";

/// No paired watch to relay to from a browser — all methods are no-ops.
export class SendLogAuthBridgeWeb extends WebPlugin implements SendLogAuthBridgePlugin {
  async setSession(): Promise<void> {}
  async clearSession(): Promise<void> {}
  /// A browser has no WatchConnectivity at all, which is neither "not paired"
  /// nor "not reported" — callers skip the row entirely on web (see
  /// `loadWatchBuildInfo`); `supported: false` is what says so.
  async getWatchInfo(): Promise<WatchBuildInfo> {
    return {
      status: "not-paired",
      syncStatus: "not-paired",
      quarantineStatus: "not-paired",
      supported: false,
      activated: false,
      paired: false,
      appInstalled: false,
    };
  }
  /// No watch on web — nothing ever queued.
  async getPendingWorkoutCompletions(): Promise<{
    completions: WorkoutCompletedMessage[];
  }> {
    return { completions: [] };
  }
}
