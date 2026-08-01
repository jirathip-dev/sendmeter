import { describe, expect, it, vi } from "vitest";
import type { PluginListenerHandle } from "@capacitor/core";
import type { WatchBuildInfo } from "../lib/watchBuild";
import { subscribeToWatchInfo } from "./useWatchInfo";

function info(build: string): WatchBuildInfo {
  return {
    status: "match",
    supported: true,
    activated: true,
    paired: true,
    appInstalled: true,
    watchBuild: build,
  };
}

async function flushPromises() {
  await Promise.resolve();
  await Promise.resolve();
}

describe("subscribeToWatchInfo", () => {
  it("refreshes after listener registration and on every live signal", async () => {
    const onInfo = vi.fn();
    const load = vi
      .fn<() => Promise<WatchBuildInfo | null>>()
      .mockResolvedValueOnce(info("1"))
      .mockResolvedValueOnce(info("2"))
      .mockResolvedValueOnce(info("3"));
    let signal = () => {};
    const remove = vi.fn(async () => {});
    const listen = vi.fn(async (handler: () => void): Promise<PluginListenerHandle> => {
      signal = handler;
      return { remove };
    });

    const unsubscribe = subscribeToWatchInfo(onInfo, { load, listen });
    await flushPromises();
    expect(onInfo).toHaveBeenLastCalledWith(info("2"));

    signal();
    await flushPromises();
    expect(onInfo).toHaveBeenLastCalledWith(info("3"));

    unsubscribe();
    await flushPromises();
    expect(remove).toHaveBeenCalledOnce();
    expect(load).toHaveBeenCalledTimes(3);
  });

  it("removes a listener that finishes registering after cleanup", async () => {
    let resolveListener!: (handle: PluginListenerHandle) => void;
    const listener = new Promise<PluginListenerHandle>((resolve) => {
      resolveListener = resolve;
    });
    const remove = vi.fn(async () => {});
    const load = vi.fn(async () => info("1"));
    const onInfo = vi.fn();

    const unsubscribe = subscribeToWatchInfo(onInfo, {
      load,
      listen: async () => listener,
    });
    unsubscribe();
    unsubscribe();
    resolveListener({ remove });
    await flushPromises();

    expect(remove).toHaveBeenCalledOnce();
    expect(onInfo).not.toHaveBeenCalled();
    expect(load).toHaveBeenCalledOnce();
  });

  it("ignores an older read that resolves after a newer live refresh", async () => {
    let resolveFirst!: (value: WatchBuildInfo) => void;
    const first = new Promise<WatchBuildInfo>((resolve) => {
      resolveFirst = resolve;
    });
    let signal = () => {};
    const load = vi
      .fn<() => Promise<WatchBuildInfo | null>>()
      .mockReturnValueOnce(first)
      .mockResolvedValue(info("2"));
    const onInfo = vi.fn();
    const unsubscribe = subscribeToWatchInfo(onInfo, {
      load,
      listen: async (handler) => {
        signal = handler;
        return { remove: async () => {} };
      },
    });
    await flushPromises();
    signal();
    await flushPromises();
    resolveFirst(info("1"));
    await flushPromises();

    expect(onInfo).toHaveBeenLastCalledWith(info("2"));
    expect(onInfo).not.toHaveBeenCalledWith(info("1"));
    unsubscribe();
  });
});
