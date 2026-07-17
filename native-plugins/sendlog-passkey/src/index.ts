import { registerPlugin } from "@capacitor/core";
import type { SendLogPasskeyPlugin } from "./definitions";

export const SendLogPasskey = registerPlugin<SendLogPasskeyPlugin>(
  "SendLogPasskey",
  {
    web: () => import("./web").then((m) => new m.SendLogPasskeyWeb()),
  },
);

export * from "./definitions";
