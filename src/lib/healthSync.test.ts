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
