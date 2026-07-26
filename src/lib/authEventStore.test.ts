import { describe, expect, it } from "vitest";
import {
  createDurableAuthStore,
  createLocalStorageStore,
  createWriteBehindStore,
  hydrateKeys,
  type AsyncKeyValue,
} from "./authEventStore";

/// A stand-in for @capacitor/preferences: an async key/value store that can be
/// told to fail, so the "never throw into the auth path" contract is testable
/// without a native shell.
function fakeBackend(
  opts: { failSet?: boolean; failGet?: boolean; throwSync?: boolean } = {},
) {
  const map = new Map<string, string>();
  const backend: AsyncKeyValue = {
    get: async ({ key }) => {
      if (opts.failGet) throw new Error("plugin not available");
      return { value: map.get(key) ?? null };
    },
    set: async ({ key, value }) => {
      if (opts.throwSync) throw new Error("boom");
      if (opts.failSet) return Promise.reject(new Error("disk full"));
      map.set(key, value);
    },
  };
  return { backend, map };
}

describe("createWriteBehindStore (issue #202)", () => {
  it("reads back a write synchronously — the auth path never awaits the disk", () => {
    const { backend } = fakeBackend();
    const store = createWriteBehindStore(backend, "preferences");
    store.setItem("k", "v");
    // No await between the write and the read: this is the whole point of the
    // write-behind cache. `recordAuthNullSession` stays synchronous even
    // though Preferences is not.
    expect(store.getItem("k")).toBe("v");
  });

  it("lands the value in the async backend once the queue drains", async () => {
    const { backend, map } = fakeBackend();
    const store = createWriteBehindStore(backend, "preferences");
    store.setItem("k", "v");
    expect(map.get("k")).toBeUndefined(); // not yet — it's queued
    await store.settled();
    expect(map.get("k")).toBe("v");
  });

  it("serializes writes so a burst can't interleave into a lost update", async () => {
    const order: string[] = [];
    const backend: AsyncKeyValue = {
      get: async () => ({ value: null }),
      set: async ({ value }) => {
        // Longer delay for the first write: without a serial chain it would
        // land after the second and the older ring would win.
        await new Promise((r) => setTimeout(r, value === "1" ? 20 : 0));
        order.push(value);
      },
    };
    const store = createWriteBehindStore(backend, "preferences");
    store.setItem("ring", "1");
    store.setItem("ring", "2");
    await store.settled();
    expect(order).toEqual(["1", "2"]);
  });

  it("swallows a rejecting backend and counts the failure", async () => {
    const { backend } = fakeBackend({ failSet: true });
    const store = createWriteBehindStore(backend, "preferences");
    expect(() => store.setItem("k", "v")).not.toThrow();
    await expect(store.settled()).resolves.toBeUndefined();
    expect(store.failures()).toBe(1);
    // The in-memory view still works, so the console + account sheet keep
    // showing the event even when it never reached disk.
    expect(store.getItem("k")).toBe("v");
  });

  it("swallows a backend that throws synchronously", async () => {
    const { backend } = fakeBackend({ throwSync: true });
    const store = createWriteBehindStore(backend, "preferences");
    expect(() => store.setItem("k", "v")).not.toThrow();
    await store.settled();
    expect(store.failures()).toBe(1);
  });

  it("seeds its cache from hydration so a relaunch sees the persisted ring", () => {
    const { backend } = fakeBackend();
    const store = createWriteBehindStore(backend, "preferences", {
      ring: "[]",
      missing: null,
    });
    expect(store.getItem("ring")).toBe("[]");
    expect(store.getItem("missing")).toBeNull();
  });
});

describe("hydrateKeys", () => {
  it("reads every requested key", async () => {
    const { backend, map } = fakeBackend();
    map.set("a", "1");
    expect(await hydrateKeys(backend, ["a", "b"])).toEqual({ a: "1", b: null });
  });

  it("treats a key that throws as absent rather than aborting the rest", async () => {
    const backend: AsyncKeyValue = {
      get: async ({ key }) => {
        if (key === "a") throw new Error("nope");
        return { value: "ok" };
      },
      set: async () => {},
    };
    expect(await hydrateKeys(backend, ["a", "b"])).toEqual({ a: null, b: "ok" });
  });
});

describe("createLocalStorageStore", () => {
  it("never throws on a store that rejects writes, and counts them", () => {
    const throwing = {
      getItem: () => {
        throw new DOMException("quota", "QuotaExceededError");
      },
      setItem: () => {
        throw new DOMException("quota", "QuotaExceededError");
      },
    };
    const store = createLocalStorageStore(throwing);
    expect(() => store.setItem("k", "v")).not.toThrow();
    expect(store.getItem("k")).toBeNull();
    expect(store.failures()).toBe(1);
  });

  it("degrades to an unavailable in-memory store when there is no localStorage", () => {
    const store = createLocalStorageStore(null);
    expect(store.kind).toBe("unavailable");
    store.setItem("k", "v");
    expect(store.getItem("k")).toBe("v"); // this lifetime only
  });
});

describe("createDurableAuthStore", () => {
  it("uses localStorage on web", async () => {
    const web = new Map<string, string>();
    const store = await createDurableAuthStore(["ring"], {
      native: false,
      web: {
        getItem: (k) => web.get(k) ?? null,
        setItem: (k, v) => void web.set(k, v),
      },
    });
    expect(store.kind).toBe("local-storage");
    store.setItem("ring", "[]");
    expect(web.get("ring")).toBe("[]");
  });

  it("uses Preferences on native, hydrating what a previous launch wrote", async () => {
    const { backend, map } = fakeBackend();
    map.set("ring", '[{"reason":"revoked"}]');
    const store = await createDurableAuthStore(["ring"], {
      native: true,
      backend,
    });
    expect(store.kind).toBe("preferences");
    expect(store.getItem("ring")).toBe('[{"reason":"revoked"}]');
  });

  it("falls back to localStorage when the Preferences plugin is unreachable", async () => {
    const { backend } = fakeBackend({ failGet: true });
    const web = new Map<string, string>();
    const store = await createDurableAuthStore(["ring"], {
      native: true,
      backend,
      web: {
        getItem: (k) => web.get(k) ?? null,
        setItem: (k, v) => void web.set(k, v),
      },
    });
    // Worse evidence than Preferences, but better than writing into a void —
    // and `kind` reports which one it actually got.
    expect(store.kind).toBe("local-storage");
  });
});
