import { registerPlugin } from "@capacitor/core";
import type { SendLogAuthBridgePlugin } from "./definitions";

export const SendLogAuthBridge = registerPlugin<SendLogAuthBridgePlugin>(
  "SendLogAuthBridge",
  {
    web: () => import("./web").then((m) => new m.SendLogAuthBridgeWeb()),
  },
);

export type {
  LiveForceMessage,
  LiveWorkoutMessage,
  SendLogAuthBridgePlugin,
  WatchBuildInfo,
  WatchBuildStatus,
} from "./definitions";
