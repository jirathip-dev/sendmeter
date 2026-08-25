// @vitest-environment jsdom
import { act, createElement, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Session } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FOREGROUND_RELAY_DEDUPE_MS, setForegroundRelayClockForTest } from "../lib/foregroundRelay";

/// #612 review N2: the dedupe window tests must not depend on the real wall
/// clock staying inside the window across `act` flushes (a load-related flake
/// class this repo documents). Drive the relay's monotonic clock through its
/// test seam instead; `advance` moves it by a fixed amount.
async function withRelayClock(
  initialMs: number,
  run: (advance: (ms: number) => void) => Promise<void>,
): Promise<void> {
  let now = initialMs;
  setForegroundRelayClockForTest(() => now);
  try {
    await run((ms: number) => {
      now += ms;
    });
  } finally {
    setForegroundRelayClockForTest(() => performance.now());
  }
}

const mocks = vi.hoisted(() => ({
  getSessionWithDiagnostics: vi.fn(),
  initAuthDiagnostics: vi.fn(),
  recordAuthStateChange: vi.fn(),
  recordSessionHeartbeat: vi.fn(),
  signInWithPassword: vi.fn(),
  onAuthStateChange: vi.fn(),
  unsubscribe: vi.fn(),
  signOutUser: vi.fn(),
  onWatchSessionRequest: vi.fn(),
  relaySessionToWatch: vi.fn(),
  relayHealthSession: vi.fn(),
  startHealthBackgroundSync: vi.fn(),
  syncHealthNow: vi.fn(),
  setMonitoringUser: vi.fn(),
  subscribeForeground: vi.fn<(cb: () => void) => () => void>(() => () => {}),
}));

vi.mock("../lib/supabase", () => ({
  SUPABASE_URL: "http://127.0.0.1:54321",
  supabase: {
    auth: {
      getSession: vi.fn(),
      onAuthStateChange: mocks.onAuthStateChange,
      signInWithPassword: mocks.signInWithPassword,
    },
  },
}));

vi.mock("../lib/authDiagnostics", () => ({
  getSessionWithDiagnostics: mocks.getSessionWithDiagnostics,
  initAuthDiagnostics: mocks.initAuthDiagnostics,
  recordAuthStateChange: mocks.recordAuthStateChange,
  recordSessionHeartbeat: mocks.recordSessionHeartbeat,
}));

vi.mock("../lib/signOut", () => ({ signOutUser: mocks.signOutUser }));

vi.mock("../lib/watchAuthRelay", () => ({
  onWatchSessionRequest: mocks.onWatchSessionRequest,
  relaySessionToWatch: mocks.relaySessionToWatch,
}));

vi.mock("../lib/healthSync", () => ({
  relayHealthSession: mocks.relayHealthSession,
  startHealthBackgroundSync: mocks.startHealthBackgroundSync,
  syncHealthNow: mocks.syncHealthNow,
}));

vi.mock("../lib/monitoring", () => ({
  setMonitoringUser: mocks.setMonitoringUser,
}));

vi.mock("../lib/foregroundSignals", () => ({
  browserForegroundSignals: () => ({
    subscribe: mocks.subscribeForeground,
  }),
}));

import { useAuth } from "./useAuth";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

const cachedSession = {
  access_token: "cached-access-token",
  expires_in: 3600,
  expires_at: 1_800_000_000,
  refresh_token: "cached-refresh-token",
  token_type: "bearer",
  user: { id: "11111111-1111-1111-1111-111111111111" },
} as Session;

describe("useAuth local auto-login", () => {
  let container: HTMLDivElement;
  let root: Root;
  let latest: ReturnType<typeof useAuth> | undefined;

  function Probe() {
    latest = useAuth();
    return null;
  }

  async function renderHook() {
    await act(async () => {
      root.render(createElement(Probe));
      await Promise.resolve();
      await Promise.resolve();
    });
  }

  beforeEach(() => {
    vi.stubEnv("VITE_DEV_AUTO_LOGIN", "true");
    window.history.replaceState({}, "", "/?auth");
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    latest = undefined;

    mocks.initAuthDiagnostics.mockResolvedValue(undefined);
    mocks.onAuthStateChange.mockImplementation(() => ({
      data: { subscription: { unsubscribe: mocks.unsubscribe } },
    }));
    mocks.onWatchSessionRequest.mockResolvedValue(null);
  });

  afterEach(async () => {
    await act(async () => {
      root.unmount();
      await Promise.resolve();
    });
    container.remove();
    window.history.replaceState({}, "", "/");
    vi.unstubAllEnvs();
    vi.clearAllMocks();
  });

  it("does not auto-login an empty local session when ?auth is present", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: null });

    await renderHook();

    expect(mocks.signInWithPassword).not.toHaveBeenCalled();
    expect(latest?.loading).toBe(false);
    expect(latest?.session).toBeNull();
  });

  it("continues to honor a cached session when ?auth is present", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({
      session: cachedSession,
    });

    await renderHook();

    expect(mocks.signInWithPassword).not.toHaveBeenCalled();
    expect(latest?.loading).toBe(false);
    expect(latest?.session).toBe(cachedSession);
    expect(mocks.relaySessionToWatch).toHaveBeenCalledWith(cachedSession);
    expect(mocks.setMonitoringUser).toHaveBeenCalledWith(cachedSession.user.id);
  });

  it("uses the DEV-only helper for an empty local session without delaying auth UI opt-out", async () => {
    window.history.replaceState({}, "", "/");
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: null });
    mocks.signInWithPassword.mockResolvedValue({
      data: { session: cachedSession },
      error: null,
    });

    await import("../lib/devAuth");
    await renderHook();

    expect(mocks.signInWithPassword).toHaveBeenCalledOnce();
    expect(latest?.loading).toBe(false);
    expect(latest?.session).toBe(cachedSession);
  });

  it("removes deferred watch listeners exactly once across StrictMode unmount", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: null });

    let resolveFirst!: (handle: { remove: () => Promise<void> }) => void;
    let resolveSecond!: (handle: { remove: () => Promise<void> }) => void;
    const firstRequest = new Promise<{ remove: () => Promise<void> }>((resolve) => {
      resolveFirst = resolve;
    });
    const secondRequest = new Promise<{ remove: () => Promise<void> }>((resolve) => {
      resolveSecond = resolve;
    });
    let requestIndex = 0;
    mocks.onWatchSessionRequest.mockImplementation(() => {
      requestIndex += 1;
      return requestIndex === 1 ? firstRequest : secondRequest;
    });
    const firstHandle = { remove: vi.fn().mockResolvedValue(undefined) };
    const secondHandle = { remove: vi.fn().mockResolvedValue(undefined) };

    await act(async () => {
      root.render(createElement(StrictMode, null, createElement(Probe)));
      await Promise.resolve();
    });
    expect(mocks.onWatchSessionRequest).toHaveBeenCalledTimes(2);

    // Both StrictMode effect instances unmount before native addListener
    // resolves. The original request continuations must own those eventual
    // handles; cleanup must not attach a second continuation.
    await act(async () => {
      root.unmount();
      await Promise.resolve();
    });
    resolveFirst(firstHandle);
    resolveSecond(secondHandle);
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(firstHandle.remove).toHaveBeenCalledOnce();
    expect(secondHandle.remove).toHaveBeenCalledOnce();
    expect(mocks.unsubscribe).toHaveBeenCalledTimes(2);
  });

  it("#612 — re-relays the current session and syncs health on a foreground signal", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    mocks.getSessionWithDiagnostics.mockClear();
    mocks.relaySessionToWatch.mockClear();
    mocks.syncHealthNow.mockClear();

    const foregroundCb = mocks.subscribeForeground.mock.calls[0]![0];
    expect(foregroundCb).toBeTypeOf("function");

    await withRelayClock(1_000_000, async () => {
      await act(async () => {
        foregroundCb();
        await Promise.resolve();
        await Promise.resolve();
      });
    });

    expect(mocks.getSessionWithDiagnostics).toHaveBeenCalledOnce();
    expect(mocks.relaySessionToWatch).toHaveBeenCalledWith(cachedSession);
    expect(mocks.relayHealthSession).toHaveBeenCalledWith(cachedSession);
    expect(mocks.syncHealthNow).toHaveBeenCalledOnce();
  });

  it("#612 — a second signal within the dedupe window is suppressed even while the first read is still pending", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    mocks.getSessionWithDiagnostics.mockClear();
    // The first read never settles — a second signal in the same tick must
    // still be suppressed by the time window alone.
    mocks.getSessionWithDiagnostics.mockImplementation(() => new Promise(() => {}));

    const foregroundCb = mocks.subscribeForeground.mock.calls[0]![0];
    await withRelayClock(1_000_000, async () => {
      foregroundCb();
      foregroundCb();
    });

    expect(mocks.getSessionWithDiagnostics).toHaveBeenCalledTimes(1);
  });

  it("#612 (review F1) — a second signal that lands AFTER the first read already resolved is still within the window and suppressed", async () => {
    // The in-flight guard this replaces merged only signals that arrived
    // while the read was pending; a fast storage read resolves before the
    // second of the two signals arrives (separate run-loop turns), so the
    // guard missed exactly the doubled pass it existed for. The time window
    // is measured from when a pass STARTS, so a fast resolve does not reopen
    // it.
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    mocks.getSessionWithDiagnostics.mockClear();
    mocks.relaySessionToWatch.mockClear();

    const foregroundCb = mocks.subscribeForeground.mock.calls[0]![0];
    await withRelayClock(1_000_000, async () => {
      foregroundCb(); // pass #1 starts at t=1_000_000
      await act(async () => {
        await Promise.resolve();
        await Promise.resolve(); // pass #1 resolves before the second signal
      });
      expect(mocks.relaySessionToWatch).toHaveBeenCalledTimes(1);

      foregroundCb(); // second signal, same tick — still within the window
      await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(mocks.getSessionWithDiagnostics).toHaveBeenCalledTimes(1);
      expect(mocks.relaySessionToWatch).toHaveBeenCalledTimes(1);
    });
  });

  it("#612 (review F2) — a signal after the window starts a new pass even while the prior read never settles", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    mocks.getSessionWithDiagnostics.mockClear();
    mocks.getSessionWithDiagnostics.mockImplementation(() => new Promise(() => {}));

    const foregroundCb = mocks.subscribeForeground.mock.calls[0]![0];
    await withRelayClock(5_000_000, async (advance) => {
      foregroundCb(); // pass #1 starts; its read hangs forever
      expect(mocks.getSessionWithDiagnostics).toHaveBeenCalledTimes(1);

      advance(FOREGROUND_RELAY_DEDUPE_MS); // window elapses, read still pending
      foregroundCb();
      expect(mocks.getSessionWithDiagnostics).toHaveBeenCalledTimes(2);
    });
  });

  it("#612 — a rejected foreground read is swallowed and does not block a later pass after the window", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    mocks.getSessionWithDiagnostics.mockClear();

    const unhandled = vi.fn();
    const onRejection = (e: PromiseRejectionEvent) => unhandled(e.reason);
    process.once("unhandledRejection", onRejection);
    try {
      const foregroundCb = mocks.subscribeForeground.mock.calls[0]![0];
      await withRelayClock(6_000_000, async (advance) => {
        mocks.getSessionWithDiagnostics.mockRejectedValueOnce(new Error("boom"));
        foregroundCb();
        await act(async () => {
          // A full tick, so a missed rejection would have fired by now.
          await new Promise((r) => setTimeout(r, 0));
        });
        expect(unhandled).not.toHaveBeenCalled();

        advance(FOREGROUND_RELAY_DEDUPE_MS);
        mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
        mocks.relaySessionToWatch.mockClear();
        foregroundCb();
        await act(async () => {
          await Promise.resolve();
          await Promise.resolve();
        });
        expect(mocks.getSessionWithDiagnostics).toHaveBeenCalledTimes(2);
        expect(mocks.relaySessionToWatch).toHaveBeenCalledWith(cachedSession);
      });
    } finally {
      process.off("unhandledRejection", onRejection);
    }
  });

  it("#612 — a foreground signal after unmount does not relay", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    const foregroundCb = mocks.subscribeForeground.mock.calls[0]![0];
    mocks.relaySessionToWatch.mockClear();

    await act(async () => {
      root.unmount();
      await Promise.resolve();
    });
    await withRelayClock(1_000_000, async () => {
      foregroundCb();
      await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
      });
    });

    expect(mocks.relaySessionToWatch).not.toHaveBeenCalled();
  });

  it("#612 — answering a watch sessionRequest goes through the classified getSession and relays with guaranteed delivery", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    const handler = mocks.onWatchSessionRequest.mock.calls[0]?.[0] as () => void;
    mocks.getSessionWithDiagnostics.mockClear();

    await act(async () => {
      handler();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(mocks.getSessionWithDiagnostics).toHaveBeenCalledOnce();
    // review F5: the pull records its nulls under a DISTINCT ring source.
    expect(mocks.getSessionWithDiagnostics.mock.calls[0]?.[3]).toBe("watch-pull");
    expect(mocks.relaySessionToWatch).toHaveBeenCalledWith(cachedSession, {
      guaranteed: true,
    });
    expect(mocks.relayHealthSession).toHaveBeenCalledWith(cachedSession);
  });

  it("#612 (review F5) — a rejected watch-pull read is swallowed, not an unhandled rejection", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: cachedSession });
    await renderHook();
    const handler = mocks.onWatchSessionRequest.mock.calls[0]?.[0] as () => void;
    mocks.getSessionWithDiagnostics.mockRejectedValueOnce(new Error("boom"));
    const unhandled = vi.fn();
    const onRejection = (e: PromiseRejectionEvent) => unhandled(e.reason);
    process.once("unhandledRejection", onRejection);
    try {
      handler();
      await act(async () => {
        await new Promise((r) => setTimeout(r, 0));
      });
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off("unhandledRejection", onRejection);
    }
  });

  it("#612 — a watch sessionRequest answered with a null session relays the clear to both native consumers", async () => {
    mocks.getSessionWithDiagnostics.mockResolvedValue({ session: null });
    await renderHook();
    const handler = mocks.onWatchSessionRequest.mock.calls[0]?.[0] as () => void;

    await act(async () => {
      handler();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(mocks.relaySessionToWatch).toHaveBeenCalledWith(null, {
      guaranteed: true,
    });
    expect(mocks.relayHealthSession).toHaveBeenCalledWith(null);
  });
});
