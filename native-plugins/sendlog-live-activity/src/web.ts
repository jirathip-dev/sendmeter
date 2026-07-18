import { WebPlugin } from "@capacitor/core";
import type {
  PendingWorkoutAction,
  SendLogLiveActivityPlugin,
} from "./definitions";

/// Live Activities are an iOS-only concept — everything no-ops on web.
export class SendLogLiveActivityWeb
  extends WebPlugin
  implements SendLogLiveActivityPlugin
{
  async isSupported(): Promise<{ supported: boolean }> {
    return { supported: false };
  }
  async requestNotificationPermission(): Promise<{ granted: boolean }> {
    return { granted: false };
  }
  async startWorkoutActivity(): Promise<void> {}
  async updateWorkoutActivity(): Promise<void> {}
  async endWorkoutActivity(): Promise<void> {}
  async startTindeqActivity(): Promise<void> {}
  async updateTindeqStats(): Promise<void> {}
  async endTindeqActivity(): Promise<void> {}
  async getPendingActions(): Promise<{ actions: PendingWorkoutAction[] }> {
    return { actions: [] };
  }
}
