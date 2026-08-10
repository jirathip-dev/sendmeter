import { afterEach, describe, expect, it, vi } from "vitest";

// healthSync.ts imports repo/health.ts, which instantiates a real Supabase
// client at module scope (see healthSignature.ts's comment) — stub it out so
// this stays a hermetic unit test of the native-bridge orchestration, not an
// accidental integration test of supabase-js client construction.
vi.mock("./supabase", () => ({ supabase: {} as never }));

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
/// itself, cleared on rejection so a later call retries, and never cleared on
/// success so a repeat call can't install a second listener.
describe("ensureReadinessListener", () => {
  afterEach(() => {
    vi.resetModules();
    vi.doUnmock("@capacitor/core");
    vi.doUnmock("sendlog-health");
    vi.restoreAllMocks();
  });

  const mockNative = (addListener: ReturnType<typeof vi.fn>) => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => true },
    }));
    const getLatestReadiness = vi.fn().mockResolvedValue(null);
    vi.doMock("sendlog-health", () => ({
      SendLogHealth: { addListener, getLatestReadiness },
    }));
    return { getLatestReadiness };
  };

  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

  it("is a no-op on web — never touches the native plugin", async () => {
    vi.doMock("@capacitor/core", () => ({
      Capacitor: { isNativePlatform: () => false },
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

  it("a rejected first attempt does not permanently disable notifications — a later call retries and installs exactly one listener", async () => {
    const addListener = vi
      .fn()
      .mockRejectedValueOnce(new Error("bridge failure"))
      .mockResolvedValue({ remove: vi.fn() });
    mockNative(addListener);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(1);
    // The rejection must be handled, not left as an unhandled rejection.
    expect(errorSpy).toHaveBeenCalledTimes(1);

    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(2);

    // Success must stick: a further call installs no third listener.
    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(2);
  });

  it("concurrent ensure calls coalesce onto one in-flight registration", async () => {
    const addListener = vi.fn().mockResolvedValue({ remove: vi.fn() });
    mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    ensureReadinessListener();
    ensureReadinessListener();
    await flush();

    expect(addListener).toHaveBeenCalledTimes(1);
  });

  it("repeated successful calls do not duplicate listeners", async () => {
    const addListener = vi.fn().mockResolvedValue({ remove: vi.fn() });
    mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    await flush();
    ensureReadinessListener();
    await flush();
    ensureReadinessListener();
    await flush();

    expect(addListener).toHaveBeenCalledTimes(1);
  });
});
