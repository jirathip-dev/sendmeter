import { useEffect, useState } from "react";
import type { PluginListenerHandle } from "@capacitor/core";
import {
  loadWatchBuildInfo,
  onWatchInfoChanged,
  type WatchBuildInfo,
} from "../lib/watchBuild";

interface WatchInfoSource {
  load: () => Promise<WatchBuildInfo | null>;
  listen: (handler: () => void) => Promise<PluginListenerHandle | null>;
}

const nativeWatchInfoSource: WatchInfoSource = {
  load: loadWatchBuildInfo,
  listen: onWatchInfoChanged,
};

/// Owns the native listener lifecycle outside React so delayed registration,
/// unmount cleanup, and out-of-order reads can be tested directly.
export function subscribeToWatchInfo(
  onInfo: (info: WatchBuildInfo | null) => void,
  source: WatchInfoSource = nativeWatchInfoSource,
): () => void {
  let active = true;
  let latestRequest = 0;

  const refresh = () => {
    if (!active) return;
    const request = ++latestRequest;
    void source
      .load()
      .then((info) => {
        if (active && request === latestRequest) onInfo(info);
      })
      .catch(() => {});
  };

  refresh();
  // Re-read after registration to close the gap between the first read and
  // the listener becoming active (#368). If unmounted while addListener is
  // pending, remove the eventual handle without publishing another value.
  const listener = source
    .listen(refresh)
    .then((handle) => {
      if (!active) {
        void handle?.remove();
        return null;
      }
      refresh();
      return handle;
    })
    .catch(() => null);

  return () => {
    if (!active) return;
    active = false;
    latestRequest += 1;
    void listener.then((handle) => handle?.remove());
  };
}

/// Shared live Apple Watch metadata for Account and History. Null means web,
/// an older native shell, or a native read that has not completed yet.
export function useWatchInfo(): WatchBuildInfo | null {
  const [info, setInfo] = useState<WatchBuildInfo | null>(null);

  useEffect(() => subscribeToWatchInfo(setInfo), []);

  return info;
}
