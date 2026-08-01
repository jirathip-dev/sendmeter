import { describe, expect, it, vi } from "vitest";
import { AuthRetryableFetchError, type AuthError, type Session } from "@supabase/supabase-js";
import {
  appendAuthEvent,
  classifyAuthStateChange,
  classifyNullSession,
  clearAuthDiagnostics,
  detectWebviewWipe,
  getAuthDiagnosticEvents,
  getAuthDiagnosticsStatus,
  heartbeatFromSession,
  initAuthDiagnostics,
  loadAuthEvents,
  loadSessionHeartbeat,
  markUserSignOut,
  MAX_AUTH_EVENTS,
  mergeAuthEvents,
  probeStoredSession,
  deriveAuthStorageKey,
  getLastNullSessionEvent,
  getSessionWithDiagnostics,
  recordAuthNullSession,
  recordAuthStateChange,
  recordSessionHeartbeat,
  resetAuthDiagnosticsForTest,
  setDiagnosticsClock,
  type AuthDiagnosticEvent,
} from "./authDiagnostics";
import { createMemoryStore } from "./authEventStore";
import { setBuildTagForTest } from "./appVersion";

const HOSTED_URL = "https://zznsqmcewtzlnfoiefkk.supabase.co";
const LOCAL_URL = "http://127.0.0.1:54321";

function fakeStorage(entries: Record<string, string> = {}) {
  const map = new Map(Object.entries(entries));
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => {
      map.set(k, v);
    },
    delete: (k: string) => map.delete(k),
  };
}

function fakeSession(): Session {
  return { access_token: "at", refresh_token: "rt" } as Session;
}

describe("deriveAuthStorageKey (issue #194)", () => {
  it("derives the hosted project's key from its URL", () => {
    expect(deriveAuthStorageKey(HOSTED_URL)).toBe("sb-zznsqmcewtzlnfoiefkk-auth-token");
  });

  it("derives the local stack's key from its URL", () => {
    expect(deriveAuthStorageKey(LOCAL_URL)).toBe("sb-127-auth-token");
  });
});

describe("classifyNullSession", () => {
  it("classifies as storage-missing when nothing was ever stored", () => {
    expect(classifyNullSession("absent", null)).toBe("storage-missing");
  });

  it("classifies as revoked when storage had a session but getSession returned null with no error", () => {
    expect(classifyNullSession("present", null)).toBe("revoked");
  });

  it("classifies as revoked when storage had a session and refresh failed non-retryably", () => {
    const error = { name: "AuthApiError", code: "refresh_token_not_found" } as AuthError;
    expect(classifyNullSession("present", error)).toBe("revoked");
  });

  it("classifies as network-error when the refresh failed on a retryable fetch error", () => {
    const error = new AuthRetryableFetchError("fetch failed", 0);
    expect(classifyNullSession("present", error)).toBe("network-error");
  });
});

describe("recordAuthNullSession + getLastNullSessionEvent", () => {
  it("increments count for consecutive occurrences, resets on a new reason, and exposes the latest via the retrieval global", () => {
    const first = recordAuthNullSession("storage-missing");
    const second = recordAuthNullSession("storage-missing");
    expect(second.count).toBe(first.count + 1);
    expect(second.reason).toBe("storage-missing");
    expect(getLastNullSessionEvent()).toEqual(second);

    const third = recordAuthNullSession("revoked");
    expect(third).toEqual({ reason: "revoked", count: 1 });
    expect(getLastNullSessionEvent()).toEqual(third);
  });
});

describe("getSessionWithDiagnostics", () => {
  it("returns the session with no reason when getSession succeeds", async () => {
    const session = fakeSession();
    const client = { auth: { getSession: async () => ({ data: { session }, error: null as null }) } };
    const result = await getSessionWithDiagnostics(client, HOSTED_URL, fakeStorage());
    expect(result).toEqual({ session, reason: null });
  });

  it("classifies storage-missing when nothing was stored", async () => {
    const client = { auth: { getSession: async () => ({ data: { session: null }, error: null }) } };
    const result = await getSessionWithDiagnostics(client, HOSTED_URL, fakeStorage());
    expect(result).toEqual({ session: null, reason: "storage-missing" });
  });

  it("reads the storage key BEFORE calling getSession, so a revoke-and-clear during the call still classifies as revoked, not storage-missing", async () => {
    const key = deriveAuthStorageKey(HOSTED_URL);
    const storage = fakeStorage({ [key]: "stored-session" });
    const client = {
      auth: {
        getSession: async () => {
          // Mimics auth-js removing an invalid/revoked stored session as a
          // side effect of the call itself (see useAuth.ts's comment on
          // this). If the implementation read storage AFTER this resolves,
          // the stored-session probe would wrongly come back absent.
          storage.delete(key);
          return { data: { session: null }, error: null };
        },
      },
    };
    const result = await getSessionWithDiagnostics(client, HOSTED_URL, storage);
    expect(result).toEqual({ session: null, reason: "revoked" });
  });

  it("only matches this client's project key, not another project's sb-*-auth-token entry", async () => {
    const storage = fakeStorage({ "sb-someotherproject-auth-token": "stored-session" });
    const client = { auth: { getSession: async () => ({ data: { session: null }, error: null }) } };
    const result = await getSessionWithDiagnostics(client, HOSTED_URL, storage);
    expect(result).toEqual({ session: null, reason: "storage-missing" });
  });
});

describe("storage-unavailable is not storage-missing", () => {
  it("classifies unreadable storage separately from an empty one", () => {
    // Opposite diagnoses: "absent" means no session ever existed here;
    // "unavailable" means we cannot tell. Collapsing them would make a
    // private-browsing user look like they never logged in.
    expect(classifyNullSession("unavailable", null)).toBe("storage-unavailable");
    expect(classifyNullSession("absent", null)).toBe("storage-missing");
  });

  it("probes a missing storage handle as unavailable", () => {
    expect(probeStoredSession(null, "https://ref.supabase.co")).toBe("unavailable");
  });

  it("probes a throwing getItem as unavailable, not absent", () => {
    const throwing = {
      getItem() {
        throw new DOMException("The quota has been exceeded.", "QuotaExceededError");
      },
    };
    expect(probeStoredSession(throwing, "https://ref.supabase.co")).toBe("unavailable");
  });

  it("distinguishes a present key from an absent one", () => {
    const key = "sb-ref-auth-token";
    const full = { getItem: (k: string) => (k === key ? "{}" : null) };
    const empty = { getItem: () => null };
    expect(probeStoredSession(full, "https://ref.supabase.co")).toBe("present");
    expect(probeStoredSession(empty, "https://ref.supabase.co")).toBe("absent");
  });
});

describe("appendAuthEvent (issue #202)", () => {
  it("collapses consecutive occurrences of the same reason into one entry", () => {
    const first = appendAuthEvent([], "revoked", "2026-07-25T00:00:00.000Z");
    const second = appendAuthEvent(first, "revoked", "2026-07-25T01:00:00.000Z");
    expect(second).toEqual([
      {
        reason: "revoked",
        count: 2,
        firstAt: "2026-07-25T00:00:00.000Z",
        lastAt: "2026-07-25T01:00:00.000Z",
      },
    ]);
  });

  it("starts a new entry when the reason changes", () => {
    const first = appendAuthEvent([], "revoked", "2026-07-25T00:00:00.000Z");
    const second = appendAuthEvent(first, "network-error", "2026-07-25T01:00:00.000Z");
    expect(second).toHaveLength(2);
    expect(second[1]).toEqual({
      reason: "network-error",
      count: 1,
      firstAt: "2026-07-25T01:00:00.000Z",
      lastAt: "2026-07-25T01:00:00.000Z",
    });
  });

  it("does not mutate the array it was given", () => {
    const prev = appendAuthEvent([], "revoked", "2026-07-25T00:00:00.000Z");
    const snapshot = [...prev];
    appendAuthEvent(prev, "network-error", "2026-07-25T01:00:00.000Z");
    expect(prev).toEqual(snapshot);
  });

  it("evicts the oldest entries once the ring exceeds MAX_AUTH_EVENTS, keeping the newest", () => {
    let events: AuthDiagnosticEvent[] = [];
    const reasons: AuthDiagnosticEvent["reason"][] = ["revoked", "network-error"];
    for (let i = 0; i < 25; i++) {
      events = appendAuthEvent(events, reasons[i % 2]!, `2026-07-25T00:00:${String(i).padStart(2, "0")}.000Z`);
    }
    expect(events).toHaveLength(MAX_AUTH_EVENTS);
    // 25 pushes, cap 20 -> the first 5 (indices 0-4, i.e. entries #1-#5) were
    // evicted; the surviving oldest is #6 (index 5), newest is #25 (index 24).
    expect(events[0]!.firstAt).toBe("2026-07-25T00:00:05.000Z");
    expect(events[events.length - 1]!.firstAt).toBe("2026-07-25T00:00:24.000Z");
  });
});

describe("loadAuthEvents (issue #202)", () => {
  it("tolerates a corrupt blob without throwing", () => {
    const storage = { getItem: () => "{not json" };
    expect(loadAuthEvents(storage)).toEqual([]);
  });

  it("tolerates a non-array blob", () => {
    const storage = { getItem: () => JSON.stringify({ reason: "revoked" }) };
    expect(loadAuthEvents(storage)).toEqual([]);
  });

  it("filters out wrong-shape entries while keeping valid siblings", () => {
    const valid: AuthDiagnosticEvent = {
      reason: "revoked",
      count: 1,
      firstAt: "2026-07-25T00:00:00.000Z",
      lastAt: "2026-07-25T00:00:00.000Z",
    };
    const storage = {
      getItem: () =>
        JSON.stringify([valid, { reason: "bogus", count: 1, firstAt: "x", lastAt: "y" }, "not-an-object"]),
    };
    expect(loadAuthEvents(storage)).toEqual([valid]);
  });

  it("returns an empty ring for missing storage", () => {
    expect(loadAuthEvents(null)).toEqual([]);
  });
});

describe("recordAuthNullSession persistence (issue #202)", () => {
  it("survives a simulated relaunch: a fresh read of the same storage still has the event", () => {
    // Reset the module-level ring first — earlier tests in this file record
    // events against the default (null-in-node) storage, and that in-memory
    // state would otherwise leak into the fresh storage this test writes to.
    clearAuthDiagnostics(null);
    const storage = fakeStorage();
    recordAuthNullSession("revoked", storage, () => "2026-07-25T00:00:00.000Z");
    // Simulate a cold start reading storage fresh, independent of any
    // in-memory state left over from the call above.
    const reloaded = loadAuthEvents(storage);
    expect(reloaded).toEqual([
      { reason: "revoked", count: 1, firstAt: "2026-07-25T00:00:00.000Z", lastAt: "2026-07-25T00:00:00.000Z" },
    ]);
  });

  it("never throws into the auth path when storage is unavailable, and getSessionWithDiagnostics still resolves", async () => {
    const throwingEventStorage = {
      getItem() {
        throw new DOMException("quota", "QuotaExceededError");
      },
      setItem() {
        throw new DOMException("quota", "QuotaExceededError");
      },
    };
    expect(() => recordAuthNullSession("storage-unavailable", throwingEventStorage)).not.toThrow();

    const throwingSessionStorage = {
      getItem() {
        throw new DOMException("quota", "QuotaExceededError");
      },
    };
    const client = { auth: { getSession: async () => ({ data: { session: null }, error: null }) } };
    const result = await getSessionWithDiagnostics(client, HOSTED_URL, throwingSessionStorage);
    expect(result).toEqual({ session: null, reason: "storage-unavailable" });
  });

  it("with a null storage handle, still dedupes in memory and getLastNullSessionEvent reflects it", () => {
    clearAuthDiagnostics(null);
    const first = recordAuthNullSession("network-error", null);
    const second = recordAuthNullSession("network-error", null);
    expect(second).toEqual({ reason: "network-error", count: first.count + 1 });
    expect(getLastNullSessionEvent()).toEqual(second);
  });

  it("getAuthDiagnosticEvents returns the ring newest-first", () => {
    clearAuthDiagnostics(null);
    recordAuthNullSession("storage-missing", null, () => "2026-07-25T00:00:00.000Z");
    recordAuthNullSession("revoked", null, () => "2026-07-25T01:00:00.000Z");
    const list = getAuthDiagnosticEvents();
    expect(list[0]!.reason).toBe("revoked");
    expect(list[1]!.reason).toBe("storage-missing");
  });
});

describe("persisted ring hydrates on a fresh module lifetime", () => {
  it("collapses into a stored entry rather than starting a new one", async () => {
    // The headline claim of #202 is that dedupe survives a relaunch. Every
    // other test calls clearAuthDiagnostics(), which sets the in-memory ring
    // to [] and so skips the `events === null` hydration branch entirely —
    // meaning the branch that actually delivers relaunch-survival was never
    // exercised against a non-empty store. Reset the module to force it.
    const prior = [
      { reason: "revoked", count: 2, firstAt: "2026-07-01T00:00:00.000Z", lastAt: "2026-07-01T01:00:00.000Z" },
    ];
    const store = new Map<string, string>([
      ["sendmeter:auth-events", JSON.stringify(prior)],
    ]);
    const storage = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
      removeItem: (k: string) => void store.delete(k),
    };

    vi.resetModules();
    const fresh = await import("./authDiagnostics");

    const latest = fresh.recordAuthNullSession("revoked", storage, () => "2026-07-02T00:00:00.000Z");

    // Same reason as the persisted entry -> collapse, not a new row.
    expect(latest.count).toBe(3);

    // Assert on the persisted entry, which is what the account sheet renders;
    // recordAuthNullSession's return value is a narrowed summary without the
    // timestamps.
    const stored = fresh.loadAuthEvents(storage);
    expect(stored).toHaveLength(1);
    expect(stored[0]!.firstAt).toBe("2026-07-01T00:00:00.000Z");
    expect(stored[0]!.lastAt).toBe("2026-07-02T00:00:00.000Z");
  });
});

// ---------------------------------------------------------------------------
// Issue #202 round 2: the paths that were blind on the c07c071 build
// ---------------------------------------------------------------------------

describe("classifyAuthStateChange (issue #202)", () => {
  it("skips INITIAL_SESSION — getSessionWithDiagnostics already covers that moment, better", () => {
    // It probes storage BEFORE auth-js can clear it, so it can tell
    // storage-missing from revoked. Recording both would double every cold
    // start with the worse classification.
    expect(classifyAuthStateChange("INITIAL_SESSION", false)).toBeNull();
  });

  it("classifies an unasked-for SIGNED_OUT as revoked, not storage-missing", () => {
    // auth-js only calls _removeSession() from _callRefreshToken on a
    // NON-retryable failure whose access token has already expired — the
    // refresh token itself was rejected. Probing storage here would find the
    // key already deleted and misreport "never had a session".
    expect(classifyAuthStateChange("SIGNED_OUT", false)).toBe("revoked");
  });

  it("classifies a SIGNED_OUT the user asked for as user-signed-out", () => {
    expect(classifyAuthStateChange("SIGNED_OUT", true)).toBe("user-signed-out");
  });

  it("still records an unexpected null-session event rather than dropping the only trace", () => {
    expect(classifyAuthStateChange("TOKEN_REFRESHED", false)).toBe("revoked");
  });
});

describe("recordAuthStateChange (issue #202)", () => {
  it("records the overnight logout path that previously left NOTHING behind", () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const reason = recordAuthStateChange("SIGNED_OUT", {
      storage: store,
      now: () => "2026-07-26T06:50:00.000Z",
      build: "1.4.0 (57)",
      userInitiated: false,
    });
    expect(reason).toBe("revoked");

    const [stored] = loadAuthEvents(store);
    expect(stored).toMatchObject({
      reason: "revoked",
      source: "auth-state-change",
      authEvent: "SIGNED_OUT",
      build: "1.4.0 (57)",
      store: "preferences",
    });
  });

  it("attaches the last-known-good heartbeat, so the record bounds the logout window", () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    recordSessionHeartbeat(
      { expires_at: Math.floor(Date.parse("2026-07-26T00:40:00.000Z") / 1000) },
      store,
      () => "2026-07-25T23:40:00.000Z",
    );
    recordAuthStateChange("SIGNED_OUT", {
      storage: store,
      now: () => "2026-07-26T06:50:00.000Z",
    });
    expect(loadAuthEvents(store)[0]).toMatchObject({
      lastGoodAt: "2026-07-25T23:40:00.000Z",
      lastGoodExpiresAt: "2026-07-26T00:40:00.000Z",
      lastAt: "2026-07-26T06:50:00.000Z",
    });
  });

  it("records nothing for INITIAL_SESSION", () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    expect(recordAuthStateChange("INITIAL_SESSION", { storage: store })).toBeNull();
    expect(loadAuthEvents(store)).toEqual([]);
  });

  it("treats a sign-out the user asked for as deliberate, once", () => {
    resetAuthDiagnosticsForTest();
    setDiagnosticsClock(() => 1_000);
    const store = createMemoryStore("preferences");
    markUserSignOut();
    expect(recordAuthStateChange("SIGNED_OUT", { storage: store })).toBe(
      "user-signed-out",
    );
    // The flag is consumed: a second SIGNED_OUT is a real incident again.
    expect(recordAuthStateChange("SIGNED_OUT", { storage: store })).toBe("revoked");
    setDiagnosticsClock(() => Date.now());
  });

  it("expires the user-signed-out flag, so a stale mark can't absolve a genuine revocation", () => {
    resetAuthDiagnosticsForTest();
    let t = 1_000;
    setDiagnosticsClock(() => t);
    const store = createMemoryStore("preferences");
    markUserSignOut();
    t += 60_000; // an hour-later revocation must not read as "you signed out"
    expect(recordAuthStateChange("SIGNED_OUT", { storage: store })).toBe("revoked");
    setDiagnosticsClock(() => Date.now());
  });

  it("starts a new entry when the build changes, so a fix can be attributed", () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    recordAuthStateChange("SIGNED_OUT", { storage: store, build: "1.4.0 (57)" });
    recordAuthStateChange("SIGNED_OUT", { storage: store, build: "1.4.1 (58)" });
    const stored = loadAuthEvents(store);
    expect(stored).toHaveLength(2);
    expect(stored.map((e) => e.build)).toEqual(["1.4.0 (57)", "1.4.1 (58)"]);
  });
});

describe("session heartbeat (issue #202)", () => {
  it("converts supabase's unix-seconds expiry to an ISO instant", () => {
    expect(
      heartbeatFromSession(
        { expires_at: Math.floor(Date.parse("2026-07-26T00:40:00.000Z") / 1000) },
        "2026-07-25T23:40:00.000Z",
      ),
    ).toEqual({
      at: "2026-07-25T23:40:00.000Z",
      expiresAt: "2026-07-26T00:40:00.000Z",
    });
  });

  it("round-trips through storage", () => {
    const store = createMemoryStore("preferences");
    recordSessionHeartbeat({ expires_at: 1_800_000_000 }, store, () => "2026-07-25T23:40:00.000Z");
    expect(loadSessionHeartbeat(store)?.at).toBe("2026-07-25T23:40:00.000Z");
  });

  it("ignores a null session and unreadable/corrupt storage instead of throwing", () => {
    expect(recordSessionHeartbeat(null, createMemoryStore())).toBeNull();
    expect(loadSessionHeartbeat({ getItem: () => "{not json" })).toBeNull();
    expect(loadSessionHeartbeat({ getItem: () => JSON.stringify({ nope: 1 }) })).toBeNull();
    expect(loadSessionHeartbeat(null)).toBeNull();
    const throwing = {
      getItem() {
        throw new DOMException("quota", "QuotaExceededError");
      },
      setItem() {
        throw new DOMException("quota", "QuotaExceededError");
      },
    };
    expect(() => recordSessionHeartbeat({ expires_at: 1 }, throwing)).not.toThrow();
    expect(loadSessionHeartbeat(throwing)).toBeNull();
  });
});

describe("mergeAuthEvents (issue #202)", () => {
  const incident: AuthDiagnosticEvent = {
    reason: "revoked",
    count: 2,
    firstAt: "2026-07-02T00:00:00.000Z",
    lastAt: "2026-07-02T01:00:00.000Z",
  };

  it("is idempotent — the same ring reconciled twice does not inflate counts", () => {
    // The legacy localStorage ring is re-read on EVERY launch (erasing it
    // would destroy the wipe canary's evidence), so an additive merge would
    // turn one incident into a nightly epidemic.
    const once = mergeAuthEvents([incident], [incident]);
    expect(once).toEqual([incident]);
    expect(mergeAuthEvents(once, [incident])).toEqual([incident]);
  });

  it("keeps the further-along version of an incident", () => {
    const grown = { ...incident, count: 5, lastAt: "2026-07-03T00:00:00.000Z" };
    expect(mergeAuthEvents([incident], [grown])).toEqual([grown]);
    expect(mergeAuthEvents([grown], [incident])).toEqual([grown]);
  });

  it("keeps genuinely different incidents apart, oldest first", () => {
    const other = { ...incident, firstAt: "2026-07-01T00:00:00.000Z", authEvent: "SIGNED_OUT" };
    expect(mergeAuthEvents([incident], [other]).map((e) => e.firstAt)).toEqual([
      "2026-07-01T00:00:00.000Z",
      "2026-07-02T00:00:00.000Z",
    ]);
  });

  it("caps the union at MAX_AUTH_EVENTS, keeping the newest", () => {
    const many = Array.from({ length: MAX_AUTH_EVENTS + 5 }, (_, i) => ({
      ...incident,
      firstAt: `2026-07-02T00:00:${String(i).padStart(2, "0")}.000Z`,
    }));
    const merged = mergeAuthEvents(many, []);
    expect(merged).toHaveLength(MAX_AUTH_EVENTS);
    expect(merged[merged.length - 1]!.firstAt).toBe("2026-07-02T00:00:24.000Z");
  });
});

describe("detectWebviewWipe (issue #202)", () => {
  it("reports a wipe when the durable canary survived but the WebView's copy is gone", () => {
    expect(detectWebviewWipe("preferences", "2026-07-01T00:00:00.000Z", null)).toBe(true);
  });

  it("says nothing on web, where both copies ARE the same store", () => {
    expect(detectWebviewWipe("local-storage", "2026-07-01T00:00:00.000Z", null)).toBe(false);
  });

  it("says nothing on a first launch (no durable canary yet)", () => {
    expect(detectWebviewWipe("preferences", null, null)).toBe(false);
  });

  it("does not claim a wipe when the WebView store merely threw — that's 'we cannot tell'", () => {
    expect(detectWebviewWipe("preferences", "stamp", null, false)).toBe(false);
  });
});

describe("initAuthDiagnostics (issue #202)", () => {
  const legacyEntry = {
    reason: "revoked" as const,
    count: 1,
    firstAt: "2026-07-24T00:00:00.000Z",
    lastAt: "2026-07-24T00:00:00.000Z",
  };

  it("migrates the ring the shipped build wrote to localStorage into Preferences", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const web = fakeStorage({ "sendmeter:auth-events": JSON.stringify([legacyEntry]) });
    const status = await initAuthDiagnostics({ store, web, build: "1.4.1 (58)" });
    expect(status).toEqual({ store: "preferences", webviewWiped: false, build: "1.4.1 (58)" });
    // Evidence recorded before the move is not thrown away by the move.
    expect(loadAuthEvents(store)).toEqual([legacyEntry]);
  });

  it("keeps events recorded before it resolved — the auth path never waits on init", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    recordAuthNullSession("network-error", null, () => "2026-07-26T05:00:00.000Z");
    await initAuthDiagnostics({ store, web: fakeStorage(), build: null });
    expect(loadAuthEvents(store).map((e) => e.reason)).toEqual(["network-error"]);
  });

  it("records the storage-wipe finding when Preferences outlives the WebView's data", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    store.setItem("sendmeter:webview-canary", "2026-07-01T00:00:00.000Z");
    // The WebView's localStorage came back empty: no canary, and (because it
    // lived in the same place) no supabase session either.
    const web = fakeStorage();
    const status = await initAuthDiagnostics({
      store,
      web,
      now: () => "2026-07-26T06:50:00.000Z",
    });
    expect(status.webviewWiped).toBe(true);
    expect(loadAuthEvents(store)[0]).toMatchObject({
      reason: "storage-wiped",
      source: "init",
      lastAt: "2026-07-26T06:50:00.000Z",
    });
  });

  it("plants the canary in both stores on a first launch, and claims no wipe", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const web = fakeStorage();
    const status = await initAuthDiagnostics({ store, web, now: () => "2026-07-26T06:50:00.000Z" });
    expect(status.webviewWiped).toBe(false);
    expect(store.getItem("sendmeter:webview-canary")).toBe("2026-07-26T06:50:00.000Z");
    expect(web.getItem("sendmeter:webview-canary")).toBe("2026-07-26T06:50:00.000Z");
  });

  it("routes subsequent records to the installed store, and exposes it for the UI", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    await initAuthDiagnostics({ store, web: fakeStorage(), build: "1.4.1 (58)" });
    recordAuthStateChange("SIGNED_OUT", { now: () => "2026-07-26T06:50:00.000Z" });
    expect(loadAuthEvents(store).at(-1)).toMatchObject({
      reason: "revoked",
      authEvent: "SIGNED_OUT",
      build: "1.4.1 (58)",
    });
    expect(getAuthDiagnosticsStatus().store).toBe("preferences");
  });
});

describe("attribution across the init race (issue #202 review)", () => {
  const HEARTBEAT_AT = "2026-07-25T23:40:00.000Z";
  const EXPIRES_AT = Math.floor(Date.parse("2026-07-26T00:40:00.000Z") / 1000);

  it("attributes a record made BEFORE init resolves to the durable store and build", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    // useAuth fires init without awaiting it and then reads the session, so a
    // cold-start event routinely beats init. Filed against the pre-init store
    // it would say `store: "local-storage"` with no build — on a native
    // build — which is precisely the attribution this instrumentation adds.
    const init = initAuthDiagnostics({
      store,
      web: fakeStorage(),
      build: "1.4.1 (58)",
    });
    const reason = recordAuthStateChange("SIGNED_OUT", {
      now: () => "2026-07-26T06:50:00.000Z",
    });
    expect(reason).toBe("revoked");
    await init;

    expect(loadAuthEvents(store)).toHaveLength(1);
    expect(loadAuthEvents(store)[0]).toMatchObject({
      reason: "revoked",
      build: "1.4.1 (58)",
      store: "preferences",
      // Stamped when it happened, not when the store finished hydrating.
      lastAt: "2026-07-26T06:50:00.000Z",
      firstAt: "2026-07-26T06:50:00.000Z",
    });
  });

  it("keeps one incident as ONE entry across the init boundary", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const init = initAuthDiagnostics({ store, web: fakeStorage(), build: "1.4.1 (58)" });
    recordAuthStateChange("SIGNED_OUT", { now: () => "2026-07-26T06:50:00.000Z" });
    await init;
    recordAuthStateChange("SIGNED_OUT", { now: () => "2026-07-26T06:51:00.000Z" });

    // `build` is part of the incident identity, so a pre-init record stamped
    // with no build would split this into two ring entries for one incident.
    const stored = loadAuthEvents(store);
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ count: 2, build: "1.4.1 (58)" });
  });

  it("routes a cold-start getSession null through the same deferral", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const init = initAuthDiagnostics({ store, web: fakeStorage(), build: "1.4.1 (58)" });
    const client = { auth: { getSession: async () => ({ data: { session: null }, error: null }) } };
    // storage-missing resolves with no network at all, so it usually wins the
    // race against init.
    expect(await getSessionWithDiagnostics(client, HOSTED_URL, fakeStorage())).toEqual({
      session: null,
      reason: "storage-missing",
    });
    await init;
    expect(loadAuthEvents(store)[0]).toMatchObject({
      reason: "storage-missing",
      source: "get-session",
      build: "1.4.1 (58)",
      store: "preferences",
    });
  });

  it("writes the first heartbeat of a launch to the durable store, not the WebView's", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const web = fakeStorage();
    const init = initAuthDiagnostics({ store, web });

    const beat = recordSessionHeartbeat({ expires_at: EXPIRES_AT }, undefined, () => HEARTBEAT_AT);
    // Stamped and returned synchronously…
    expect(beat?.at).toBe(HEARTBEAT_AT);
    // …but not written into the store the canary exists to prove unreliable.
    expect(web.getItem("sendmeter:auth-heartbeat")).toBeNull();

    await init;
    expect(loadSessionHeartbeat(store)).toEqual({
      at: HEARTBEAT_AT,
      expiresAt: "2026-07-26T00:40:00.000Z",
    });
    expect(web.getItem("sendmeter:auth-heartbeat")).toBeNull();
  });

  it("writes straight through once init has resolved", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    await initAuthDiagnostics({ store, web: fakeStorage() });
    recordSessionHeartbeat({ expires_at: EXPIRES_AT }, undefined, () => HEARTBEAT_AT);
    // No await: the steady state stays synchronous.
    expect(loadSessionHeartbeat(store)?.at).toBe(HEARTBEAT_AT);
  });

  it("still records when init fails, rather than swallowing the evidence", async () => {
    resetAuthDiagnosticsForTest();
    const init = initAuthDiagnostics({
      store: Promise.reject(new Error("no store")),
      web: fakeStorage(),
    });
    recordAuthStateChange("SIGNED_OUT", { now: () => "2026-07-26T06:50:00.000Z" });
    await expect(init).rejects.toThrow();
    // Falls back to the default store, but the event is not lost.
    expect(getAuthDiagnosticEvents()[0]).toMatchObject({ reason: "revoked" });
  });
});

describe("the storage-wiped event carries the heartbeat (issue #202 review)", () => {
  it("dates the wipe against the last session known to be good", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    store.setItem("sendmeter:webview-canary", "2026-07-01T00:00:00.000Z");
    recordSessionHeartbeat(
      { expires_at: Math.floor(Date.parse("2026-07-26T00:40:00.000Z") / 1000) },
      store,
      () => "2026-07-25T23:40:00.000Z",
    );

    await initAuthDiagnostics({
      store,
      web: fakeStorage(),
      build: "1.4.1 (58)",
      now: () => "2026-07-26T06:50:00.000Z",
    });

    // The one event whose entire purpose is bounding when the session died
    // must not be the only one without the bounds.
    expect(loadAuthEvents(store).at(-1)).toMatchObject({
      reason: "storage-wiped",
      source: "init",
      build: "1.4.1 (58)",
      store: "preferences",
      lastGoodAt: "2026-07-25T23:40:00.000Z",
      lastGoodExpiresAt: "2026-07-26T00:40:00.000Z",
      lastAt: "2026-07-26T06:50:00.000Z",
    });
  });
});

describe("useAuth's launch sequence (issue #202 review, round 2)", () => {
  /// A promise the test releases by hand — stands in for the native
  /// `App.getInfo()` bridge round-trip that `loadBuildTag()` really is.
  function deferred<T>() {
    let resolve!: (v: T) => void;
    const promise = new Promise<T>((r) => {
      resolve = r;
    });
    return { promise, resolve };
  }

  it("attributes the launch-time event even though getSession resolves before the build tag", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const build = deferred<string | null>();
    const web = fakeStorage();
    const client = {
      auth: { getSession: async () => ({ data: { session: null }, error: null }) },
    };

    // --- useAuth's effect body, same tick, same order ---
    const init = initAuthDiagnostics({ store, web, build: build.promise });
    const pending = getSessionWithDiagnostics(client, HOSTED_URL, web);
    // ----------------------------------------------------

    // A logged-out getSession() is a storage read behind auth-js's lock with
    // no network, so it beats the bridge call every time. Previously that
    // meant the record landed with no build and store "local-storage" on a
    // native build — the exact attribution this instrumentation adds.
    expect(await pending).toEqual({ session: null, reason: "storage-missing" });
    expect(loadAuthEvents(store)).toEqual([]); // deferred, not written blind

    build.resolve("1.4.1 (58)");
    await init;

    expect(loadAuthEvents(store)[0]).toMatchObject({
      reason: "storage-missing",
      source: "get-session",
      build: "1.4.1 (58)",
      store: "preferences",
    });
  });

  it("keeps that event and a later one as ONE incident", async () => {
    resetAuthDiagnosticsForTest();
    const store = createMemoryStore("preferences");
    const build = deferred<string | null>();
    const web = fakeStorage();
    const client = {
      auth: { getSession: async () => ({ data: { session: null }, error: null }) },
    };

    const init = initAuthDiagnostics({ store, web, build: build.promise });
    await getSessionWithDiagnostics(client, HOSTED_URL, web);
    build.resolve("1.4.1 (58)");
    await init;
    // Same cause and origin, after init: an unattributed first record would
    // have had a different incident identity (`build` is part of the key) and
    // split this into two ring entries.
    await getSessionWithDiagnostics(client, HOSTED_URL, web);

    const stored = loadAuthEvents(store);
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ count: 2, build: "1.4.1 (58)" });
  });

  it("resolves the build tag itself, so no caller can reopen the window by awaiting it first", async () => {
    resetAuthDiagnosticsForTest();
    setBuildTagForTest("9.9.9 (99)");
    try {
      const store = createMemoryStore("preferences");
      // No build argument: this is exactly how useAuth calls it, and there is
      // nothing left for the caller to await before starting init.
      const init = initAuthDiagnostics({ store, web: fakeStorage() });
      recordAuthStateChange("SIGNED_OUT", { now: () => "2026-07-26T06:50:00.000Z" });
      await init;

      expect(getAuthDiagnosticsStatus().build).toBe("9.9.9 (99)");
      expect(loadAuthEvents(store)[0]).toMatchObject({
        reason: "revoked",
        build: "9.9.9 (99)",
        store: "preferences",
      });
    } finally {
      setBuildTagForTest(null);
    }
  });
});
