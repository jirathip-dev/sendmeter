import { WebPlugin } from "@capacitor/core";
import type { SendLogAuthBridgePlugin } from "./definitions";

/// No paired watch to relay to from a browser — both methods are no-ops.
export class SendLogAuthBridgeWeb extends WebPlugin implements SendLogAuthBridgePlugin {
  async setSession(): Promise<void> {}
  async clearSession(): Promise<void> {}
}
