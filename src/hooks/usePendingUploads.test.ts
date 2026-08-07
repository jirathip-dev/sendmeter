import { describe, expect, it, vi } from "vitest";
import { makeSequencedRefresher } from "./usePendingUploads";

// #485 F6: `usePendingUploads` fires a fresh `refresh()` per signal (mount,
// the module-level pending-uploads notification, foreground) with no
// sequencing between them. Pre-fix, each call independently did
// `pendingRecordingsBreakdown(userId).then((b) => { if (alive) setBreakdown(b) })`
// — `alive` only covers unmount, not ordering, so a SLOW earlier read that
// resolves AFTER a FASTER later one overwrites the fresh count with a stale
// one, and nothing ever corrects it until the next signal. Same shape as
// `useWatchInfo.ts`'s `subscribeToWatchInfo`/`latestRequest`, which already
// has this exact test (`useWatchInfo.test.ts`, "ignores an older read that
// resolves after a newer live refresh") — extracted the same way so it's
// directly testable without a React renderer, which this repo has none of
// for hooks.

describe("makeSequencedRefresher", () => {
  it("#485 F6 — PROVED. ignores a slow earlier read that resolves after a faster later one", async () => {
    let resolveFirst!: (v: number) => void;
    const first = new Promise<number>((resolve) => {
      resolveFirst = resolve;
    });
    const load = vi.fn<() => Promise<number>>().mockReturnValueOnce(first).mockResolvedValue(2);
    const onValue = vi.fn();
    const { refresh } = makeSequencedRefresher(load, onValue);

    refresh(); // slow: call #1, won't resolve until we say so
    refresh(); // fast: call #2, resolves immediately
    await Promise.resolve();
    await Promise.resolve();

    expect(onValue).toHaveBeenLastCalledWith(2);
    onValue.mockClear();

    // The slow call now lands — pre-fix this overwrote the display with the
    // stale value 1.
    resolveFirst(1);
    await Promise.resolve();
    await Promise.resolve();

    expect(onValue).not.toHaveBeenCalled();
  });

  it("applies a single read normally", async () => {
    const load = vi.fn(async () => 5);
    const onValue = vi.fn();
    const { refresh } = makeSequencedRefresher(load, onValue);

    refresh();
    await Promise.resolve();
    await Promise.resolve();

    expect(onValue).toHaveBeenCalledExactlyOnceWith(5);
  });

  it("applies nothing after stop(), even for an already in-flight read", async () => {
    let resolve!: (v: number) => void;
    const pending = new Promise<number>((r) => {
      resolve = r;
    });
    const load = vi.fn(() => pending);
    const onValue = vi.fn();
    const { refresh, stop } = makeSequencedRefresher(load, onValue);

    refresh();
    stop();
    resolve(1);
    await Promise.resolve();
    await Promise.resolve();

    expect(onValue).not.toHaveBeenCalled();
  });

  it("does nothing when refresh() is called after stop()", async () => {
    const load = vi.fn(async () => 1);
    const onValue = vi.fn();
    const { refresh, stop } = makeSequencedRefresher(load, onValue);

    stop();
    refresh();
    await Promise.resolve();
    await Promise.resolve();

    expect(load).not.toHaveBeenCalled();
    expect(onValue).not.toHaveBeenCalled();
  });
});
