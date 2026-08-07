import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import { isFresh, mergeForceBeat, type LiveForce, type LiveForceSample } from "../lib/liveForceMirror";
import { subscribePluginListener } from "./pluginListener";

export type { LiveForce, LiveForceSample };

/// The watch's live Progressor session, mirrored on the phone Force tab
/// (SL-87). WatchConnectivity-only via the auth-bridge plugin — sub-second
/// and network-free, but native-only (always null in a browser) and only
/// while the phone is reachable from the watch. Device-only to verify.
export function useLiveForce(): LiveForce | null {
  const [beat, setBeat] = useState<LiveForce | null>(null);
  // Staleness re-check between beats.
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return;
    // #485 F7: `subscribePluginListener` (see its doc comment) so a handle
    // that resolves after this effect has already cleaned up still gets
    // removed instead of leaking.
    const unsubscribe = subscribePluginListener(() =>
      SendLogAuthBridge.addListener("liveForce", (msg) => {
        // Functional update so the merge reads the previous beat's spark
        // buffer without a side-effecting ref (react-compiler: no sync
        // setState/mutation in effect bodies — this all runs inside the async
        // plugin-event callback instead, and `prev` covers the accumulation).
        setBeat((prev) => mergeForceBeat(prev, msg));
      }),
    );
    const interval = setInterval(() => setNow(Date.now()), 2_000);
    return () => {
      clearInterval(interval);
      unsubscribe();
    };
  }, []);

  if (!beat) return null;
  if (!isFresh(beat, now)) return null;
  return beat;
}
