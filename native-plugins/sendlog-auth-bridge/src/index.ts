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
  LiveMirrorEvent,
  LiveMirrorMetadata,
  LiveWorkoutMessage,
  SendLogAuthBridgePlugin,
  WatchBuildInfo,
  WatchBuildStatus,
  WatchQuarantineStatus,
  WatchSyncStatus,
} from "./definitions";
