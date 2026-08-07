import { afterEach, describe, expect, it } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import { RETRY_COOLDOWN_MS, openRecordingDb, resetRecordingDbCache } from "./recordingDb";

// #485 F9 — `openRecordingDb()`'s module-level memo (`cached`) is a PROMISE,
// not the resolved value. `recordingDb.test.ts` always passes an explicit
// `factory`, which bypasses that memo entirely (see its doc comment) — so
// the memo itself has no coverage there. This file drives the no-argument
// path, which is the one every real caller uses, by stubbing the global
// `indexedDB` the module reads through `defaultFactory()`.
//
// Pre-F9, `cached ??= openOnce(defaultFactory())` kept the promise from the
// FIRST call forever, including one that resolved to `null` (a blocked open
// — another tab mid version-change, in this test standing in for any
// transient failure). Every later call in the same session then got that
// same `null` back without ever trying again — #269 sized the localStorage
// lane as a ~1.5 MB emergency backstop, not a store meant to carry a whole
// session.
//
// #485 F2 (review of the F9 fix) — the FIRST version of this fix cleared
// `cached` unconditionally on every `null` resolution, which meant every
// SINGLE caller (not just the next one) retried: a realistic sign-out-drain-
// plus-save-path sequence went from 1 open attempt to 12, each burning the
// full `OPEN_TIMEOUT_MS` on a hung open. `RETRY_COOLDOWN_MS` bounds retries
// to at most one per cooldown window — this file proves BOTH halves: a
// failure eventually gets retried (F9's property), and it is not retried on
// every single call in between (F2's property, using the injectable `now`
// parameter to control the cooldown clock without real timers).

/// A factory whose every `open()` call is blocked (never succeeds) —
/// standing in for a persistently-unavailable IndexedDB (storage disabled by
/// policy, not just one transient hiccup).
function alwaysBlockedFactory() {
  let calls = 0;
  const factory = {
    open() {
      calls += 1;
      const req: Record<string, unknown> = {};
      setTimeout(() => (req.onblocked as (() => void) | undefined)?.(), 0);
      return req as unknown as IDBOpenDBRequest;
    },
  } as unknown as IDBFactory;
  return { factory, calls: () => calls };
}

describe("openRecordingDb — a transient open failure retries, but not on every call (#485 F9 / F2)", () => {
  afterEach(() => {
    resetRecordingDbCache();
    Reflect.deleteProperty(globalThis, "indexedDB");
  });

  it("F9 — PROVED. retries once the cooldown elapses, instead of memoizing the null forever", async () => {
    resetRecordingDbCache();
    const real = new IDBFactory();
    let calls = 0;
    const flaky = {
      open(...args: [string, number?]) {
        calls += 1;
        if (calls === 1) {
          const req: Record<string, unknown> = {};
          setTimeout(() => (req.onblocked as (() => void) | undefined)?.(), 0);
          return req as unknown as IDBOpenDBRequest;
        }
        return real.open(...(args as [string, number]));
      },
    } as unknown as IDBFactory;
    Object.defineProperty(globalThis, "indexedDB", { value: flaky, configurable: true });

    let now = 1_000_000;
    const clock = () => now;

    const first = await openRecordingDb(undefined, clock);
    expect(first).toBe(null); // the blocked open, exactly as recordingDb.test.ts proves in isolation

    // Still inside the cooldown window: must NOT retry yet (that's F2, the
    // next test makes it the headline assertion — this is just the boundary).
    now += RETRY_COOLDOWN_MS - 1;
    expect(await openRecordingDb(undefined, clock)).toBe(null);
    expect(calls).toBe(1);

    // Cooldown elapsed: the next call retries.
    now += 1;
    const retried = await openRecordingDb(undefined, clock);
    // Pre-F2-fix (the unconditional-clear version) this was already `calls:
    // 2` after the FIRST extra call above, i.e. before the cooldown check
    // existed at all. Pre-F9 (`cached ??= ...`) `calls` would never pass 1,
    // ever, at any `now`.
    expect(calls).toBe(2);
    expect(retried).not.toBe(null);
  });

  it("F2 — PROVED. does not retry on every call inside the cooldown window", async () => {
    resetRecordingDbCache();
    const { factory, calls } = alwaysBlockedFactory();
    Object.defineProperty(globalThis, "indexedDB", { value: factory, configurable: true });

    let now = 5_000_000;
    const clock = () => now;

    // A realistic burst: several callers in quick succession (a sign-out
    // drain's two internal opens, a few queue writes, a couple of count
    // reads) — all well inside the cooldown window.
    for (let i = 0; i < 8; i++) {
      now += 50; // a few ms apart, nowhere close to RETRY_COOLDOWN_MS
      expect(await openRecordingDb(undefined, clock)).toBe(null);
    }

    // Pre-F2-fix this was 9 (the blocking first attempt PLUS one retry per
    // subsequent call, matching review's measured "1 → 12" shape at scale).
    expect(calls()).toBe(1);
  });

  it("keeps the SAME cached promise across calls once an open succeeds", async () => {
    resetRecordingDbCache();
    const real = new IDBFactory();
    Object.defineProperty(globalThis, "indexedDB", {
      value: real,
      configurable: true,
    });

    const first = await openRecordingDb();
    const second = await openRecordingDb();
    expect(first).not.toBe(null);
    // Not just "both non-null" — the memo must still short-circuit a repeat
    // successful open to the SAME promise (no regression to "always reopen").
    expect(openRecordingDb()).toBe(openRecordingDb());
    expect(second).not.toBe(null);
  });
});
