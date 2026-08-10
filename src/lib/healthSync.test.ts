/** @vitest-environment jsdom */

import { afterEach, describe, expect, it, vi } from "vitest";
import type { Session } from "@supabase/supabase-js";

// healthSync.ts imports repo/health.ts, which instantiates a real Supabase
// client at module scope (see healthSignature.ts's comment) — stub it out so
// this stays a hermetic unit test of the native-bridge orchestration, not an
// accidental integration test of supabase-js client construction.
vi.mock("./supabase", () => ({ supabase: {} as never }));

// Node's own experimental global `localStorage` shadows jsdom's here and is
// non-functional without `--localstorage-file` (setItem throws, silently —
// see RoutineCard.test.tsx for the same fix). Replace it with a working
// in-memory store so the #535 tests below can actually read back what
// healthSync.ts persists.
const localStorageBacking = new Map<string, string>();
vi.stubGlobal("localStorage", {
  getItem: (k: string) => localStorageBacking.get(k) ?? null,
  setItem: (k: string, v: string) => void localStorageBacking.set(k, String(v)),
  removeItem: (k: string) => void localStorageBacking.delete(k),
  clear: () => localStorageBacking.clear(),
});

/// #487 (F4): "Clear health data & resync" hard-deletes health_metrics rows
/// (irreversible, see repo/health.ts's deleteHealthMetrics) and THEN calls
/// resyncHealthHistory to rebuild them from HealthKit. resyncHealthHistory
/// used to swallow a failed native plugin call and the caller always toasted
/// "cleared · resyncing" regardless — reporting success on the one
/// irreversible action in the app even when the resync silently failed.
/// resyncHealthHistory must now report whether the resync actually
/// succeeded so the caller (AccountSheet) can say so honestly.
describe("resyncHealthHistory", () => {
  afterEach(() => {
    vi.resetModules();
    vi.doUnmock("@capacitor/core");
    vi.doUnmock("sendlog-health");
  });

  it("is a deliberate no-op on web — ok:true without touching the native plugin", async () => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => false },
    }));
    const clearAndResync = vi.fn();
    vi.doMock("sendlog-health", () => ({ SendLogHealth: { clearAndResync } }));

    const { resyncHealthHistory } = await import("./healthSync");
    await expect(resyncHealthHistory()).resolves.toEqual({ ok: true });
    expect(clearAndResync).not.toHaveBeenCalled();
  });

  it("reports ok:true when the native rebuild actually succeeds", async () => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => true },
    }));
    const clearAndResync = vi.fn().mockResolvedValue(undefined);
    vi.doMock("sendlog-health", () => ({ SendLogHealth: { clearAndResync } }));

    const { resyncHealthHistory } = await import("./healthSync");
    await expect(resyncHealthHistory()).resolves.toEqual({ ok: true });
    expect(clearAndResync).toHaveBeenCalledTimes(1);
  });

  it("reports ok:false — not ok:true — when the native rebuild throws", async () => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => true },
    }));
    const clearAndResync = vi.fn().mockRejectedValue(new Error("HealthKit denied"));
    vi.doMock("sendlog-health", () => ({ SendLogHealth: { clearAndResync } }));

    const { resyncHealthHistory } = await import("./healthSync");
    await expect(resyncHealthHistory()).resolves.toMatchObject({ ok: false });
  });

  // #494 (N4): the thrown error's message used to be discarded entirely —
  // this pins that it's carried back on the failure result instead, so a
  // caller CAN surface the real native reason (HealthKit denied vs. found no
  // data) rather than only ever knowing "it failed".
  it("carries the thrown error's message back instead of discarding it", async () => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => true },
    }));
    const clearAndResync = vi
      .fn()
      .mockRejectedValue(
        new Error(
          "Resync found no Health data to rebuild from — Health access may be denied, or your history is genuinely empty for this window.",
        ),
      );
    vi.doMock("sendlog-health", () => ({ SendLogHealth: { clearAndResync } }));

    const { resyncHealthHistory } = await import("./healthSync");
    const result = await resyncHealthHistory();
    expect(result.ok).toBe(false);
    expect(result.message).toMatch(/genuinely empty/);
  });
});

/// #534: the dedupe guard for the process-lifetime readiness listener used to
/// be an optimistic boolean flipped to `true` before `addListener` resolved —
/// a rejected first attempt left it stuck, permanently disabling readiness
/// notifications. These pin the fix: the guard is the registration promise
/// itself, cleared on failure so a later call retries, and never cleared on
/// success so a repeat call can't install a second listener; a failure is
/// only reported to monitoring on the SECOND CONSECUTIVE attempt (review
/// round 2 F4 — the first might just be a self-healing blip); and the
/// one-shot catch-up read fires only from a successful install, never from a
/// failed attempt (review round 2 F3).
///
/// The failure shapes modeled below are the two real ones traced from the
/// installed `@capacitor/core`/`@capacitor/ios` sources (review round 1
/// F1/F5), not a generic `Error("bridge failure")` fiction: a plugin missing
/// from the native build genuinely rejects `addListener()`
/// (`CapacitorException`, code `UNIMPLEMENTED`), while a plugin that IS
/// present but whose registration message silently fails to land is modeled
/// as a phantom resolve with no usable handle — the shape our own defensive
/// check reacts to, even though the currently-installed Capacitor version
/// was not observed to produce it (see the "Honest limits" comment on
/// `ensureReadinessListener`, and #552 for the real fix that would need).
describe("ensureReadinessListener", () => {
  afterEach(() => {
    vi.resetModules();
    vi.doUnmock("@capacitor/core");
    vi.doUnmock("sendlog-health");
    vi.doUnmock("./monitoring");
    vi.restoreAllMocks();
  });

  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

  /// Asserts nothing inside `fn` leaves an unhandled promise rejection
  /// behind — review round 2 F6 explicitly asked for this on the
  /// phantom-handle and mid-flight-deferred cases, not just the plain
  /// rejection one.
  const withNoUnhandledRejection = async (fn: () => Promise<void>) => {
    let unhandled: unknown;
    const onUnhandledRejection = (reason: unknown) => {
      unhandled = reason;
    };
    process.on("unhandledRejection", onUnhandledRejection);
    try {
      await fn();
    } finally {
      process.off("unhandledRejection", onUnhandledRejection);
    }
    expect(unhandled).toBeUndefined();
  };

  const mockNative = (
    addListener: ReturnType<typeof vi.fn>,
    isPluginAvailable: ReturnType<typeof vi.fn> = vi.fn().mockReturnValue(true),
  ) => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => true, isPluginAvailable },
    }));
    const getLatestReadiness = vi.fn().mockResolvedValue(null);
    vi.doMock("sendlog-health", () => ({
      SendLogHealth: { addListener, getLatestReadiness },
    }));
    const captureHandledOperationalFailure = vi.fn();
    vi.doMock("./monitoring", () => ({ captureHandledOperationalFailure }));
    return { getLatestReadiness, captureHandledOperationalFailure };
  };

  it("is a no-op on web — never touches the native plugin", async () => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => false, isPluginAvailable: vi.fn() },
    }));
    const addListener = vi.fn();
    vi.doMock("sendlog-health", () => ({
      SendLogHealth: { addListener, getLatestReadiness: vi.fn() },
    }));

    const { ensureReadinessListener } = await import("./healthSync");
    ensureReadinessListener();
    await flush();
    expect(addListener).not.toHaveBeenCalled();
  });

  it("a plugin missing from the native build is a no-op, reported only on the SECOND consecutive attempt", async () => {
    const addListener = vi.fn();
    const isPluginAvailable = vi.fn().mockReturnValue(false);
    const { captureHandledOperationalFailure } = mockNative(addListener, isPluginAvailable);

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    await flush();
    expect(isPluginAvailable).toHaveBeenCalledWith("SendLogHealth");
    expect(addListener).not.toHaveBeenCalled();
    // A single failed attempt might self-heal — captureHandledOperationalFailure's
    // own contract is "recovery exhausted," not "first try didn't work."
    expect(captureHandledOperationalFailure).not.toHaveBeenCalled();

    ensureReadinessListener();
    await flush();
    expect(captureHandledOperationalFailure).toHaveBeenCalledTimes(1);
    expect(captureHandledOperationalFailure).toHaveBeenCalledWith(
      "health.readiness-listener",
      expect.any(Error),
    );
  });

  it("a rejected attempt (plugin missing from the native build) does not permanently disable notifications — a later call retries, installs exactly one listener, and fires the catch-up read exactly once", async () => {
    const missing = Object.assign(
      new Error('"SendLogHealth.addListener()" is not implemented on ios'),
      { code: "UNIMPLEMENTED" },
    );
    const addListener = vi
      .fn()
      .mockRejectedValueOnce(missing)
      .mockRejectedValueOnce(missing)
      .mockResolvedValue({ remove: vi.fn() });
    const { captureHandledOperationalFailure, getLatestReadiness } = mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    await withNoUnhandledRejection(async () => {
      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(1);
      // First failure: not yet reported, and no catch-up read fired.
      expect(captureHandledOperationalFailure).not.toHaveBeenCalled();
      expect(getLatestReadiness).not.toHaveBeenCalled();

      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(2);
      // Second CONSECUTIVE failure: now reported, still no catch-up read.
      expect(captureHandledOperationalFailure).toHaveBeenCalledWith(
        "health.readiness-listener",
        missing,
      );
      expect(getLatestReadiness).not.toHaveBeenCalled();

      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(3);
      // Success installs the listener AND fires the one-shot catch-up read —
      // never on a failed attempt (review round 2 F3).
      expect(getLatestReadiness).toHaveBeenCalledTimes(1);

      // Success must stick: a further call installs no fourth listener, and
      // does not replay the catch-up read.
      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(3);
      expect(getLatestReadiness).toHaveBeenCalledTimes(1);
    });
  });

  it("a phantom-resolved attempt (no usable handle) does not permanently disable notifications — a later call retries and installs exactly one listener", async () => {
    const addListener = vi
      .fn()
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce(undefined)
      .mockResolvedValue({ remove: vi.fn() });
    const { captureHandledOperationalFailure } = mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    await withNoUnhandledRejection(async () => {
      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(1);
      expect(captureHandledOperationalFailure).not.toHaveBeenCalled();

      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(2);
      expect(captureHandledOperationalFailure).toHaveBeenCalledWith(
        "health.readiness-listener",
        expect.any(Error),
      );

      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(3);

      // Success must stick: a further call installs no fourth listener.
      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(3);
    });
  });

  it("a second caller arriving while a failing registration is still in flight does not install a second listener", async () => {
    let rejectFirst: (error: unknown) => void = () => {};
    const first = new Promise((_resolve, reject) => {
      rejectFirst = reject;
    });
    const addListener = vi
      .fn()
      .mockReturnValueOnce(first)
      .mockResolvedValue({ remove: vi.fn() });
    mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    await withNoUnhandledRejection(async () => {
      ensureReadinessListener();
      expect(addListener).toHaveBeenCalledTimes(1);

      // A second caller arrives before the first attempt has settled — and
      // returns immediately, well before `first` is rejected below.
      ensureReadinessListener();
      expect(addListener).toHaveBeenCalledTimes(1);

      rejectFirst(new Error("bridge failure"));
      await flush();
      expect(addListener).toHaveBeenCalledTimes(1);

      // Only once the in-flight attempt has actually failed does a later call retry.
      ensureReadinessListener();
      await flush();
      expect(addListener).toHaveBeenCalledTimes(2);
    });
  });

  it("repeated successful calls do not duplicate listeners or replay the catch-up read", async () => {
    const addListener = vi.fn().mockResolvedValue({ remove: vi.fn() });
    const { getLatestReadiness } = mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    await flush();
    ensureReadinessListener();
    await flush();
    ensureReadinessListener();
    await flush();

    expect(addListener).toHaveBeenCalledTimes(1);
    expect(getLatestReadiness).toHaveBeenCalledTimes(1);
  });
});

/// #535: a replayed `getLatestReadiness()` result used to be reported with
/// `Date.now()` as its sync time — a result that actually completed hours
/// earlier (e.g. a watch refresh that landed while the WebView was closed)
/// then showed "Synced just now" merely because the app reopened. It also
/// used one global `sendmeter:health-synced-at` key, so one account's
/// timestamp could survive into another's session. These pin the fix: the
/// native `completedAt` (epoch seconds) drives the recorded time, the same
/// completed request is never double-reported, and the marker is scoped per
/// authenticated user.
describe("readiness replay sync timestamp (#535)", () => {
  afterEach(() => {
    vi.resetModules();
    vi.doUnmock("@capacitor/core");
    vi.doUnmock("sendlog-health");
    localStorage.clear();
  });

  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

  const session = (userId: string): Session =>
    ({ user: { id: userId }, access_token: `token-${userId}` }) as unknown as Session;

  /// `getLatestReadinessResolvedValues` are consumed in order, one per
  /// `getLatestReadiness()` call (a launch's own catch-up read, then each
  /// later account's re-fired catch-up read — #535 F4); any call beyond the
  /// given values resolves `null`. `push(result)` invokes the exact callback
  /// the production `addListener("readinessRefresh", …)` call registered, so
  /// a test can simulate the live native push independently of the catch-up
  /// read racing it.
  function mockNativeReadiness(...getLatestReadinessResolvedValues: unknown[]) {
    let pushCallback: ((result: unknown) => void) | undefined;
    const addListener = vi.fn((_event: string, cb: (result: unknown) => void) => {
      pushCallback = cb;
      return Promise.resolve({ remove: vi.fn() });
    });
    const getLatestReadiness = vi.fn();
    for (const value of getLatestReadinessResolvedValues) {
      getLatestReadiness.mockResolvedValueOnce(value);
    }
    getLatestReadiness.mockResolvedValue(null);
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => true, isPluginAvailable: vi.fn().mockReturnValue(true) },
    }));
    vi.doMock("sendlog-health", () => ({
      SendLogHealth: {
        addListener,
        getLatestReadiness,
        setSession: vi.fn().mockResolvedValue(undefined),
        clearSession: vi.fn().mockResolvedValue(undefined),
      },
    }));
    return { getLatestReadiness, push: (result: unknown) => pushCallback?.(result) };
  }

  it("a 3-hour-old cached result reports its real completion time, not Date.now()", async () => {
    const completedAtSeconds = Math.floor(Date.now() / 1000) - 3 * 3600;
    mockNativeReadiness({
      status: "success",
      requestId: "req-stale",
      completedAt: completedAtSeconds,
    });

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    relayHealthSession(session("user-a"));
    await flush();

    expect(healthLastSyncedAt()).toBe(completedAtSeconds * 1000);
  });

  it("the same completed request observed twice (catch-up read, then a duplicate live push) is reported only once", async () => {
    const completedAtSeconds = Math.floor(Date.now() / 1000) - 60;
    const sharedResult = {
      status: "success",
      requestId: "req-dup",
      completedAt: completedAtSeconds,
    };
    const { push } = mockNativeReadiness(sharedResult);

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    const syncedHandler = vi.fn();
    window.addEventListener("sendmeter:health-synced", syncedHandler);
    try {
      relayHealthSession(session("user-a"));
      await flush(); // listener install resolves; the catch-up read fires and records sharedResult once

      expect(syncedHandler).toHaveBeenCalledTimes(1);

      // The live listener then delivers the identical already-recorded request.
      push(sharedResult);
      await flush();

      expect(syncedHandler).toHaveBeenCalledTimes(1);
      expect(healthLastSyncedAt()).toBe(completedAtSeconds * 1000);
    } finally {
      window.removeEventListener("sendmeter:health-synced", syncedHandler);
    }
  });

  it("a genuinely new result (a different request id) updates the timestamp and emits the event normally", async () => {
    const { push } = mockNativeReadiness(null);

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    const syncedHandler = vi.fn();
    window.addEventListener("sendmeter:health-synced", syncedHandler);
    try {
      relayHealthSession(session("user-a"));
      await flush(); // catch-up read resolves with null — nothing recorded yet
      expect(healthLastSyncedAt()).toBeNull();

      const freshCompletedAtSeconds = Math.floor(Date.now() / 1000);
      push({
        status: "success",
        requestId: "req-fresh",
        completedAt: freshCompletedAtSeconds,
      });
      await flush();

      expect(syncedHandler).toHaveBeenCalledTimes(1);
      expect(healthLastSyncedAt()).toBe(freshCompletedAtSeconds * 1000);
    } finally {
      window.removeEventListener("sendmeter:health-synced", syncedHandler);
    }
  });

  it("switching from account A to account B never exposes A's persisted sync timestamp to B", async () => {
    const { push } = mockNativeReadiness(null);

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    relayHealthSession(session("user-a"));
    await flush();
    push({
      status: "success",
      requestId: "req-a",
      completedAt: Math.floor(Date.now() / 1000),
    });
    await flush();
    expect(healthLastSyncedAt()).not.toBeNull();

    // Account B signs in on the same device/process — B must never read A's marker.
    relayHealthSession(session("user-b"));
    expect(healthLastSyncedAt()).toBeNull();

    // Switching back to A restores A's own (unmodified) marker.
    relayHealthSession(session("user-a"));
    expect(healthLastSyncedAt()).not.toBeNull();
  });

  // Review round 1 F1/F2: the in-memory `lastProcessedReadinessRequestId`
  // guard dies with the WebView, so on its own it cannot stop a cold-launch
  // catch-up read from re-reporting a result this account already recorded
  // last session. The fence has to be checked against the PERSISTED marker.
  it("a cross-launch replay of an already-recorded cached result is not reported as a new change (durable fence)", async () => {
    const userId = "user-a";
    const completedAtSeconds = Math.floor(Date.now() / 1000) - 3 * 3600;
    const priorMs = completedAtSeconds * 1000;
    // Simulate state left behind by a PREVIOUS process: this account's
    // marker already reflects this exact cached result.
    localStorage.setItem(`sendmeter:health-synced-at:${userId}`, String(priorMs));

    mockNativeReadiness({
      status: "success",
      requestId: "req-stale",
      completedAt: completedAtSeconds,
      accountUserId: userId,
    });

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    const syncedHandler = vi.fn();
    window.addEventListener("sendmeter:health-synced", syncedHandler);
    try {
      relayHealthSession(session(userId));
      await flush();

      expect(syncedHandler).not.toHaveBeenCalled();
      expect(healthLastSyncedAt()).toBe(priorMs);
    } finally {
      window.removeEventListener("sendmeter:health-synced", syncedHandler);
    }
  });

  // Review round 1 F2: understating freshness is as dishonest as
  // overstating it. A late-arriving replay of an OLDER cached result must
  // never regress the marker past a genuinely fresher one already recorded.
  it("a result with an older completedAt than the persisted marker does not regress the displayed sync time", async () => {
    const { push } = mockNativeReadiness(null);

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    const syncedHandler = vi.fn();
    window.addEventListener("sendmeter:health-synced", syncedHandler);
    try {
      relayHealthSession(session("user-a"));
      await flush(); // catch-up read resolves null — nothing recorded yet

      const freshCompletedAtSeconds = Math.floor(Date.now() / 1000);
      push({
        status: "success",
        requestId: "req-fresh",
        completedAt: freshCompletedAtSeconds,
        accountUserId: "user-a",
      });
      await flush();
      expect(healthLastSyncedAt()).toBe(freshCompletedAtSeconds * 1000);

      // An older cached result (e.g. a slow catch-up read) arrives after.
      const staleCompletedAtSeconds = freshCompletedAtSeconds - 3 * 3600;
      push({
        status: "success",
        requestId: "req-stale-late",
        completedAt: staleCompletedAtSeconds,
        accountUserId: "user-a",
      });
      await flush();

      expect(syncedHandler).toHaveBeenCalledTimes(1); // only the fresh one
      expect(healthLastSyncedAt()).toBe(freshCompletedAtSeconds * 1000); // unchanged
    } finally {
      window.removeEventListener("sendmeter:health-synced", syncedHandler);
    }
  });

  it("a result with no completedAt falls back to Date.now()", async () => {
    const { push } = mockNativeReadiness(null);

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    relayHealthSession(session("user-a"));
    await flush();

    const before = Date.now();
    push({ status: "success", requestId: "req-no-completed-at", accountUserId: "user-a" });
    await flush();
    const after = Date.now();

    const recorded = healthLastSyncedAt();
    expect(recorded).not.toBeNull();
    expect(recorded as number).toBeGreaterThanOrEqual(before);
    expect(recorded as number).toBeLessThanOrEqual(after);
  });

  // Review round 1 F3: comparing the dispatch-time snapshot against
  // `activeHealthUserId` is a tautology on the synchronous listener-push
  // path (no await separates them). The real contamination window is a
  // relay to B flipping `activeHealthUserId` synchronously while native is
  // still bound to A — a result native completes (and stamps) for A must
  // not be written into B's marker just because it happens to arrive while
  // B is current.
  it("a result stamped for account A that arrives after relaying to account B is dropped, not written under B's marker", async () => {
    const { push } = mockNativeReadiness(null);

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    relayHealthSession(session("user-a"));
    await flush();

    // The relay to B updates `activeHealthUserId` synchronously; native was
    // still bound to A when it completed and delivered this result.
    relayHealthSession(session("user-b"));
    push({
      status: "success",
      requestId: "req-late-a",
      completedAt: Math.floor(Date.now() / 1000),
      accountUserId: "user-a",
    });
    await flush();

    expect(healthLastSyncedAt()).toBeNull(); // B's marker must stay untouched

    relayHealthSession(session("user-a"));
    expect(healthLastSyncedAt()).toBeNull(); // A was never credited for it either
  });

  // Review round 1 F4: listener installation is process-lifetime (#534), so
  // only the FIRST account signed in this launch would otherwise ever get a
  // catch-up read — a later account switch needs its own.
  it("switching to a new account after the listener is already installed fires that account's own catch-up read", async () => {
    const bCompletedAtSeconds = Math.floor(Date.now() / 1000) - 3600;
    const { getLatestReadiness } = mockNativeReadiness(
      null, // account A's catch-up read: nothing cached
      {
        status: "success",
        requestId: "req-b",
        completedAt: bCompletedAtSeconds,
        accountUserId: "user-b",
      }, // account B's own catch-up read
    );

    const { relayHealthSession, healthLastSyncedAt } = await import("./healthSync");
    relayHealthSession(session("user-a"));
    await flush();
    expect(getLatestReadiness).toHaveBeenCalledTimes(1);
    expect(healthLastSyncedAt()).toBeNull();

    relayHealthSession(session("user-b"));
    await flush();

    expect(getLatestReadiness).toHaveBeenCalledTimes(2);
    expect(healthLastSyncedAt()).toBe(bCompletedAtSeconds * 1000);
  });
});
