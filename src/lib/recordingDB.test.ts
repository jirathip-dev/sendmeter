import { describe, it, expect } from "vitest";
import { defaultMainQueueStore } from "./recordingDB";

// #269: this project's vitest config runs in node (see vite.config.ts), which
// has no `indexedDB` global at all — deliberately not polyfilled with
// `fake-indexeddb` (see recordingQueue.test.ts for why). That means the ONE
// thing testable here without a browser is the guarded-unavailable path
// itself: every actual `MainQueueStore` policy test lives in
// recordingQueue.test.ts against an injected in-memory fake, since real
// IndexedDB behavior can't be exercised from node.
describe("defaultMainQueueStore", () => {
  it("resolves null when indexedDB is unavailable (node/tests) instead of throwing", async () => {
    await expect(defaultMainQueueStore()).resolves.toBeNull();
  });

  it("is memoized — repeated calls return the same (still-null) resolution", async () => {
    const a = await defaultMainQueueStore();
    const b = await defaultMainQueueStore();
    expect(a).toBeNull();
    expect(b).toBeNull();
  });
});
