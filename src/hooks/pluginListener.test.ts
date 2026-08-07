import { describe, expect, it, vi } from "vitest";
import { subscribePluginListener } from "./pluginListener";

// #485 F7 — `useLiveWorkout`'s and `useLiveForce`'s WatchConnectivity
// listeners used to do this instead:
//
//   let handle: PluginListenerHandle | null = null;
//   void addListener(...).then((h) => { handle = h; });
//   return () => { ...; void handle?.remove(); };
//
// which is provably wrong whenever cleanup runs BEFORE `addListener`
// resolves: `handle` is still `null` at cleanup time (a decision from state
// captured before the resolution it depends on — CLAUDE.md's #295/#296
// defect class), so `handle?.remove()` is a no-op, and the handle that
// arrives a moment later is stored into a `handle` variable nobody will
// ever read again. `subscribePluginListener` fixes this by chaining `.then`
// directly off the promise (never reading a derived variable), so cleanup
// removes the handle whenever it resolves — before or after cleanup ran.
//
// This file proves BOTH shapes side by side against the same interleaving,
// so the naive shape's failure is the concrete comparison for the fix
// (rather than asserted from the fixed shape alone).

interface FakeHandle {
  remove: () => Promise<void>;
}

function naiveSubscribe(addListener: () => Promise<FakeHandle>): () => void {
  let handle: FakeHandle | null = null;
  void addListener().then((h) => {
    handle = h;
  });
  return () => {
    void handle?.remove();
  };
}

describe("the pre-fix shape (naive `let handle` + `.then`)", () => {
  it("FAILS. drops a handle that resolves after cleanup already ran", async () => {
    let resolveListener!: (h: FakeHandle) => void;
    const pending = new Promise<FakeHandle>((resolve) => {
      resolveListener = resolve;
    });
    const remove = vi.fn(async () => {});

    const unsubscribe = naiveSubscribe(() => pending);
    unsubscribe(); // cleanup runs before addListener resolves — a fast unmount
    resolveListener({ remove });
    await Promise.resolve();
    await Promise.resolve();

    // The real, observed pre-fix failure: the handle was never removed.
    expect(remove).not.toHaveBeenCalled();
  });
});

describe("subscribePluginListener (#485 F7 fix)", () => {
  it("PROVED. removes a handle that resolves after cleanup already ran", async () => {
    let resolveListener!: (h: FakeHandle) => void;
    const pending = new Promise<FakeHandle>((resolve) => {
      resolveListener = resolve;
    });
    const remove = vi.fn(async () => {});

    const unsubscribe = subscribePluginListener(() => pending);
    unsubscribe(); // same interleaving the naive shape above just failed on
    resolveListener({ remove });
    await Promise.resolve();
    await Promise.resolve();

    expect(remove).toHaveBeenCalledOnce();
  });

  it("still removes the handle on the ordinary path (resolved before cleanup)", async () => {
    const remove = vi.fn(async () => {});
    const unsubscribe = subscribePluginListener(() => Promise.resolve({ remove }));
    await Promise.resolve();

    unsubscribe();
    await Promise.resolve();

    expect(remove).toHaveBeenCalledOnce();
  });
});
