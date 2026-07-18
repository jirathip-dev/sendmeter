import { registerPlugin } from "@capacitor/core";
import type { SendLogLiveActivityPlugin } from "./definitions";

export const SendLogLiveActivity = registerPlugin<SendLogLiveActivityPlugin>(
  "SendLogLiveActivity",
  {
    web: () => import("./web").then((m) => new m.SendLogLiveActivityWeb()),
  },
);

export * from "./definitions";
