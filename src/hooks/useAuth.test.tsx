// @vitest-environment jsdom
import { act, createElement, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Session } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

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

    await act(async () => {
      root.render(createElement(Probe));
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
      await Promise.resolve();
    });

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
});
