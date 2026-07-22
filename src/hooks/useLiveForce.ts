import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import type { PluginListenerHandle } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";

/// How long the beat may go quiet before the mirror hides. The watch beats
/// ~2 Hz while measuring and on every status change; 8s of silence means the
/// gauge screen closed, the watch app died, or the phone went unreachable.
const STALE_MS = 8_000;

/// How far back the phone's own sparkline buffer reaches (SL-95). Each beat
/// only carries a ~3s trailing window (see TindeqManager.sparkWindow) — the
/// phone accumulates those slices into this longer rolling history itself.
const SPARK_WINDOW_MS = 45_000;

export interface LiveForceSample {
  atMs: number; // wall-clock epoch ms, re-anchored from the beat's relative t
  kg: number;
}

export interface LiveForce {
  status: "connected" | "measuring";
  kg: number;
  peakKg: number;
  elapsedMs: number;
  sessionCount: number;
  tag: string;
  side: string;
  updatedAt: number; // ms epoch
  /// Rolling ~45s buffer of recent force samples for the mirror sparkline,
  /// oldest first. Gaps (e.g. the rest between reps) simply aren't present —
  /// render as separate line runs rather than interpolating across them.
  spark: LiveForceSample[];
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
      const status = msg.status; // narrowed off "idle"; keep for the closure below
      const updatedAtMs = msg.updated_at * 1000;
      const elapsedMs = msg.elapsed_ms ?? 0;
      // Wall-clock time of this beat's t=0 — lets each [t, kg] point be
      // re-anchored to absolute time even though `t` resets to 0 on every
      // new hold (TindeqManager.start() clears its sample buffer).
      const originMs = updatedAtMs - elapsedMs;
      const incoming: LiveForceSample[] = (msg.spark ?? []).map(([t, kg]) => ({
        atMs: originMs + t,
        kg,
      }));
      // Functional update so the merge reads the previous beat's spark
      // buffer without a side-effecting ref (react-compiler: no sync
      // setState/mutation in effect bodies — this all runs inside the async
      // plugin-event callback instead, and `prev` covers the accumulation).
      setBeat((prev) => {
        const byTime = new Map<number, number>();
        for (const p of prev?.spark ?? []) byTime.set(Math.round(p.atMs), p.kg);
        for (const p of incoming) byTime.set(Math.round(p.atMs), p.kg);
        // Dedup (beats resend an overlapping trailing window) + trim to the
        // rolling buffer window.
        const cutoff = updatedAtMs - SPARK_WINDOW_MS;
        const spark = Array.from(byTime.entries())
          .filter(([atMs]) => atMs >= cutoff)
          .sort((a, b) => a[0] - b[0])
          .map(([atMs, kg]) => ({ atMs, kg }));
        return {
          status,
          kg: msg.kg ?? 0,
          peakKg: msg.peak_kg ?? 0,
          elapsedMs,
          sessionCount: msg.session_count ?? 0,
          tag: msg.tag ?? "",
          side: msg.side ?? "",
          updatedAt: updatedAtMs,
          spark,
        };
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
