import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import type { PluginListenerHandle } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";

/// How long the beat may go quiet before the mirror hides. The watch beats
/// ~2 Hz while measuring and on every status change; 8s of silence means the
/// gauge screen closed, the watch app died, or the phone went unreachable.
const STALE_MS = 8_000;

export interface LiveForce {
  status: "connected" | "measuring";
  kg: number;
  peakKg: number;
  elapsedMs: number;
  sessionCount: number;
  tag: string;
  side: string;
  updatedAt: number; // ms epoch
}

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
    let handle: PluginListenerHandle | null = null;
    void SendLogAuthBridge.addListener("liveForce", (msg) => {
      if (msg.status === "idle") {
        setBeat(null);
        return;
      }
      setBeat({
        status: msg.status,
        kg: msg.kg ?? 0,
        peakKg: msg.peak_kg ?? 0,
        elapsedMs: msg.elapsed_ms ?? 0,
        sessionCount: msg.session_count ?? 0,
        tag: msg.tag ?? "",
        side: msg.side ?? "",
        updatedAt: msg.updated_at * 1000,
      });
    }).then((h) => {
      handle = h;
    });
    const interval = setInterval(() => setNow(Date.now()), 2_000);
    return () => {
      clearInterval(interval);
      void handle?.remove();
    };
  }, []);

  if (!beat) return null;
  if (now - beat.updatedAt > STALE_MS) return null;
  return beat;
}
