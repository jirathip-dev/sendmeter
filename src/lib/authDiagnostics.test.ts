import { describe, expect, it, vi } from "vitest";
import { AuthRetryableFetchError, type AuthError, type Session } from "@supabase/supabase-js";
import {
  appendAuthEvent,
  classifyNullSession,
  clearAuthDiagnostics,
  getAuthDiagnosticEvents,
  loadAuthEvents,
  MAX_AUTH_EVENTS,
  probeStoredSession,
  deriveAuthStorageKey,
  getLastNullSessionEvent,
  getSessionWithDiagnostics,
  recordAuthNullSession,
  type AuthDiagnosticEvent,
} from "./authDiagnostics";

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
