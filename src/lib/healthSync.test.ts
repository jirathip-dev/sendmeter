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
/// itself, cleared on failure so a later call retries, and never cleared on
/// success so a repeat call can't install a second listener.
///
/// The failure shapes modeled below are the two real ones traced from the
/// installed `@capacitor/core`/`@capacitor/ios` sources (#534 review F1/F5),
/// not a generic `Error("bridge failure")` fiction: a plugin missing from the
/// native build genuinely rejects `addListener()` (`CapacitorException`, code
/// `UNIMPLEMENTED`), while a plugin that IS present but whose registration
/// message silently fails to land is modeled as a phantom resolve with no
/// usable handle — the shape our own defensive check reacts to, even though
/// the currently-installed Capacitor version was not observed to produce it
/// (see the "Honest limits" comment on `ensureReadinessListener`).
describe("ensureReadinessListener", () => {
  afterEach(() => {
    vi.resetModules();
    vi.doUnmock("@capacitor/core");
    vi.doUnmock("sendlog-health");
    vi.doUnmock("./monitoring");
    vi.restoreAllMocks();
  });

  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

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

  it("is a no-op when the native build has no SendLogHealth plugin at all", async () => {
    const addListener = vi.fn();
    const isPluginAvailable = vi.fn().mockReturnValue(false);
    mockNative(addListener, isPluginAvailable);

    const { ensureReadinessListener } = await import("./healthSync");
    ensureReadinessListener();
    await flush();

    expect(isPluginAvailable).toHaveBeenCalledWith("SendLogHealth");
    expect(addListener).not.toHaveBeenCalled();
  });

  it("a rejected first attempt (plugin missing from the native build) does not permanently disable notifications — a later call retries and installs exactly one listener", async () => {
    const missing = Object.assign(
      new Error('"SendLogHealth.addListener()" is not implemented on ios'),
      { code: "UNIMPLEMENTED" },
    );
    const addListener = vi
      .fn()
      .mockRejectedValueOnce(missing)
      .mockResolvedValue({ remove: vi.fn() });
    const { captureHandledOperationalFailure } = mockNative(addListener);

    let unhandled: unknown;
    const onUnhandledRejection = (reason: unknown) => {
      unhandled = reason;
    };
    process.on("unhandledRejection", onUnhandledRejection);

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(1);
    expect(captureHandledOperationalFailure).toHaveBeenCalledWith(
      "health.readiness-listener",
      missing,
    );

    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(2);

    // Success must stick: a further call installs no third listener.
    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(2);

    process.off("unhandledRejection", onUnhandledRejection);
    expect(unhandled).toBeUndefined();
  });

  it("a phantom-resolved first attempt (no usable handle) does not permanently disable notifications — a later call retries and installs exactly one listener", async () => {
    const addListener = vi
      .fn()
      .mockResolvedValueOnce(undefined)
      .mockResolvedValue({ remove: vi.fn() });
    const { captureHandledOperationalFailure } = mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(1);
    expect(captureHandledOperationalFailure).toHaveBeenCalledWith(
      "health.readiness-listener",
      expect.any(Error),
    );

    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(2);

    ensureReadinessListener();
    await flush();
    expect(addListener).toHaveBeenCalledTimes(2);
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

    ensureReadinessListener();
    expect(addListener).toHaveBeenCalledTimes(1);

    // A second caller arrives before the first attempt has settled.
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

  // #534 review F4: the one-shot catch-up read must not replay on every
  // listener-registration retry — see the comment on
  // `ensureReadinessCatchUpRead` for why (repeated false "synced just now").
  it("does not replay the readiness catch-up read on a listener registration retry", async () => {
    const addListener = vi
      .fn()
      .mockRejectedValueOnce(new Error("bridge failure"))
      .mockResolvedValue({ remove: vi.fn() });
    const { getLatestReadiness } = mockNative(addListener);

    const { ensureReadinessListener } = await import("./healthSync");

    ensureReadinessListener();
    await flush();
    ensureReadinessListener();
    await flush();

    expect(getLatestReadiness).toHaveBeenCalledTimes(1);
  });
});
