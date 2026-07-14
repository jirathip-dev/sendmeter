import { registerPlugin } from "@capacitor/core";
import type { SendLogHealthPlugin } from "./definitions";

export const SendLogHealth = registerPlugin<SendLogHealthPlugin>(
  "SendLogHealth",
  {
    web: () => import("./web").then((m) => new m.SendLogHealthWeb()),
  },
);

export type { SendLogHealthPlugin } from "./definitions";
