import { describe, expect, it } from "vitest";
import { nextLockedCapabilityFit } from "./capabilityFitLock";
import type { CapabilityFit } from "./capabilityModel";

const fit = (tau: number): CapabilityFit => ({
  family: "hill", cf: 20, maxF: 40, tau, p: 1, sse: 1,
});

describe("active capability-fit lock", () => {
  it("does not let a concurrent new-recording refit move an active run", async () => {
    const started = fit(10);
    let locked: CapabilityFit | null = started;
    let release!: (value: CapabilityFit) => void;
    const refit = new Promise<CapabilityFit>((resolve) => { release = resolve; });

    release(fit(30));
    const newlyComputed = await refit;
    locked = nextLockedCapabilityFit(true, newlyComputed, locked);
    expect(locked).toBe(started);
    expect(locked!.tau).toBe(10);

    locked = nextLockedCapabilityFit(false, newlyComputed, locked);
    expect(locked).toBe(newlyComputed);
    expect(locked!.tau).toBe(30);
  });
});
