import { afterEach, describe, expect, it } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import { openRecordingDb, resetRecordingDbCache } from "./recordingDb";

// #485 F9 — `openRecordingDb()`'s module-level memo (`cached`) is a PROMISE,
// not the resolved value. `recordingDb.test.ts` always passes an explicit
// `factory`, which bypasses that memo entirely (see its doc comment) — so
// the memo itself has no coverage there. This file drives the no-argument
// path, which is the one every real caller uses, by stubbing the global
// `indexedDB` the module reads through `defaultFactory()`.
//
// Pre-fix, `cached ??= openOnce(defaultFactory())` keeps the promise from
// the FIRST call forever, including one that resolved to `null` (a blocked
// open — another tab mid version-change, in this test standing in for any
// transient failure). Every later call in the same session then gets that
// same `null` back without ever trying again — #269 sized the localStorage
// lane as a ~1.5 MB emergency backstop, not a store meant to carry a whole
// session.

describe("openRecordingDb — a transient open failure must not stick (#485 F9)", () => {
  afterEach(() => {
    resetRecordingDbCache();
    Reflect.deleteProperty(globalThis, "indexedDB");
  });

  it("PROVED. retries on the next call instead of memoizing the null forever", async () => {
    resetRecordingDbCache();
    const real = new IDBFactory();
    let calls = 0;
    const flaky = {
      open(...args: [string, number?]) {
        calls += 1;
        if (calls === 1) {
          // The blocked-open path: a request that only ever fires
          // `onblocked`, same shape `recordingDb.test.ts` uses to simulate
          // another tab holding a version-change lock.
          const req: Record<string, unknown> = {};
          setTimeout(() => (req.onblocked as (() => void) | undefined)?.(), 0);
          return req as unknown as IDBOpenDBRequest;
        }
        return real.open(...(args as [string, number]));
      },
    } as unknown as IDBFactory;
    Object.defineProperty(globalThis, "indexedDB", {
      value: flaky,
      configurable: true,
    });

    const first = await openRecordingDb();
    expect(first).toBe(null); // the blocked open, exactly as recordingDb.test.ts proves in isolation

    const second = await openRecordingDb();
    // Pre-fix this was `{ calls: 1, second: null }` — `flaky.open` was never
    // called a second time at all, because `cached` already held a settled
    // promise from the first, failed attempt.
    expect(calls).toBe(2);
    expect(second).not.toBe(null);
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
