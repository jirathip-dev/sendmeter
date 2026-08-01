import { describe, expect, it, vi } from "vitest";
import { KeepAwakeCoordinator } from "./keepAwakeCoordinator";

function deferred() {
  let resolve!: () => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<void>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe("KeepAwakeCoordinator", () => {
  it("processes an intent queued as the prior transition promise settles", async () => {
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
    });

    const pending = coordinator.setDesired(true);
    let deactivation!: Promise<void>;
    queueMicrotask(() => {
      deactivation = coordinator.setDesired(false);
    });

    await pending;
    await new Promise<void>((resolve) => queueMicrotask(resolve));
    await deactivation;
    expect(calls).toEqual([true, false]);
  });

  it("serializes rapid true-false-true changes and ends at the current intent", async () => {
    const first = deferred();
    const calls: boolean[] = [];
    const transition = vi.fn(async (active: boolean) => {
      calls.push(active);
      if (calls.length === 1) await first.promise;
    });
    const coordinator = new KeepAwakeCoordinator(transition);

    const pending = coordinator.setDesired(true);
    await Promise.resolve();
    void coordinator.setDesired(false);
    const finalActivation = coordinator.setDesired(true);
    expect(calls).toEqual([true]);

    first.resolve();
    await pending;
    await finalActivation;
    expect(calls).toEqual([true, true]);
    expect(calls.at(-1)).toBe(true);
  });

  it("allows sleep after an in-flight activation finishes on unmount", async () => {
    const first = deferred();
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
      if (calls.length === 1) await first.promise;
    });

    const activation = coordinator.setDesired(true);
    await Promise.resolve();
    const deactivation = coordinator.setDesired(false);
    first.resolve();
    await activation;
    await deactivation;

    expect(calls).toEqual([true, false]);
  });

  it("still allows sleep when native activation rejects after taking effect", async () => {
    const first = deferred();
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
      if (calls.length === 1) await first.promise;
    });

    const activation = coordinator.setDesired(true);
    await Promise.resolve();
    const deactivation = coordinator.setDesired(false);
    first.reject(new Error("bridge reply lost"));
    await activation;
    await deactivation;

    expect(calls).toEqual([true, false]);
  });

  it("continues after a rejected deactivation", async () => {
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
      if (!active) throw new Error("temporary bridge failure");
    });

    await coordinator.setDesired(false);
    await coordinator.setDesired(true);

    expect(calls).toEqual([false, true]);
  });
});
