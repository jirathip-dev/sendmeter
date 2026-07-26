import { Capacitor } from "@capacitor/core";
import { Preferences } from "@capacitor/preferences";

/// Issue #202: the auth diagnostics ring used to live in the WebView's
/// `localStorage` — the *same* store that holds the Supabase session. If iOS
/// evicts the WebView's website data, the session and the evidence for why it
/// vanished go together, and a storage wipe becomes indistinguishable from
/// "nothing ever happened". On native the ring therefore belongs in
/// Preferences (NSUserDefaults), which lives outside WKWebView's data store;
/// on web `localStorage` is all there is.
///
/// The seam is deliberately SYNCHRONOUS (`getItem`/`setItem`, same shape the
/// module already used) even though Preferences is async: recording an auth
/// event happens on the auth path, which must never await a disk write or
/// have one throw into it. `createWriteBehindStore` gives that guarantee — the
/// cache is updated synchronously and the durable write is queued behind it.
export type AuthEventStoreKind = "preferences" | "local-storage" | "unavailable";

export interface AuthEventStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface DurableAuthStore extends AuthEventStorage {
  /// Which backend actually took the write. Recorded on every event, because
  /// a record that came back from `preferences` while the WebView's own keys
  /// are gone IS the storage-wipe finding.
  kind: AuthEventStoreKind;
  /// Resolves once every queued durable write has been attempted. Tests only
  /// — production code must never await this on the auth path.
  settled(): Promise<void>;
  /// Count of durable writes that failed. A ring that reads back fine in
  /// memory but never landed is worth knowing about.
  failures(): number;
}

/// The slice of `@capacitor/preferences` this module needs — narrowed so
/// tests can fake it (including a backend that rejects or throws) without a
/// native shell.
export interface AsyncKeyValue {
  get(options: { key: string }): Promise<{ value: string | null }>;
  set(options: { key: string; value: string }): Promise<void>;
}

/// Wraps an async key/value backend in a synchronous, write-behind cache.
/// Reads come from the cache seeded at hydration; writes update the cache
/// immediately and queue the durable write on a serial chain (so two rapid
/// records can't interleave into a lost update). Every rejection is
/// swallowed and counted — a failed NSUserDefaults write must not break
/// sign-in.
export function createWriteBehindStore(
  backend: AsyncKeyValue,
  kind: AuthEventStoreKind,
  seed: Record<string, string | null> = {},
): DurableAuthStore {
  const cache = new Map<string, string>();
  for (const [k, v] of Object.entries(seed)) if (v !== null) cache.set(k, v);
  let chain: Promise<void> = Promise.resolve();
  let failures = 0;
  return {
    kind,
    getItem: (key) => cache.get(key) ?? null,
    setItem: (key, value) => {
      cache.set(key, value);
      // `.then(...)` (not `await`) so a backend that throws *synchronously*
      // is captured by the promise chain rather than escaping into the
      // caller's stack.
      chain = chain
        .then(() => backend.set({ key, value }))
        .catch(() => {
          failures += 1;
        });
    },
    settled: () => chain,
    failures: () => failures,
  };
}

/// Reads the given keys out of an async backend into a plain seed object.
/// A key that throws/rejects reads as absent rather than aborting hydration
/// — a partially readable store is still better evidence than none.
export async function hydrateKeys(
  backend: AsyncKeyValue,
  keys: readonly string[],
): Promise<Record<string, string | null>> {
  const seed: Record<string, string | null> = {};
  for (const key of keys) {
    try {
      seed[key] = (await backend.get({ key })).value ?? null;
    } catch {
      seed[key] = null;
    }
  }
  return seed;
}

function browserLocalStorage(): Storage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
}

/// `localStorage` as a store, with the same never-throw contract. Used
/// directly on web, and as the fallback when Preferences is unreachable.
export function createLocalStorageStore(
  ls: AuthEventStorage | null = browserLocalStorage(),
): DurableAuthStore {
  if (!ls) return createMemoryStore("unavailable");
  let failures = 0;
  return {
    kind: "local-storage",
    getItem: (key) => {
      try {
        return ls.getItem(key);
      } catch {
        return null;
      }
    },
    setItem: (key, value) => {
      try {
        ls.setItem(key, value);
      } catch {
        failures += 1;
      }
    },
    settled: () => Promise.resolve(),
    failures: () => failures,
  };
}

/// Last resort: nothing survives a relaunch, but the in-memory ring and the
/// console path keep working. Exported for tests.
export function createMemoryStore(
  kind: AuthEventStoreKind = "unavailable",
): DurableAuthStore {
  const map = new Map<string, string>();
  return {
    kind,
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    settled: () => Promise.resolve(),
    failures: () => 0,
  };
}

/// Picks and hydrates the durable store for this platform: Preferences on
/// native, `localStorage` on web. A native shell whose Preferences plugin
/// refuses to answer falls back to `localStorage` — worse evidence, but the
/// alternative is none.
export async function createDurableAuthStore(
  keys: readonly string[],
  opts: {
    native?: boolean;
    backend?: AsyncKeyValue;
    web?: AuthEventStorage | null;
  } = {},
): Promise<DurableAuthStore> {
  const native = opts.native ?? Capacitor.isNativePlatform();
  if (!native) return createLocalStorageStore(opts.web);
  const backend = opts.backend ?? Preferences;
  try {
    // Probe first: `hydrateKeys` deliberately swallows per-key failures, so a
    // plugin that isn't there would otherwise look like an empty store and we
    // would happily write evidence into a void.
    await backend.get({ key: keys[0] ?? "sendmeter:probe" });
  } catch {
    return createLocalStorageStore(opts.web);
  }
  return createWriteBehindStore(
    backend,
    "preferences",
    await hydrateKeys(backend, keys),
  );
}
