import { describe, expect, it } from "vitest";
import { AuthRetryableFetchError, type AuthError, type Session } from "@supabase/supabase-js";
import {
  classifyNullSession,
  probeStoredSession,
  deriveAuthStorageKey,
  getLastNullSessionEvent,
  getSessionWithDiagnostics,
  recordAuthNullSession,
} from "./authDiagnostics";

const HOSTED_URL = "https://zznsqmcewtzlnfoiefkk.supabase.co";
const LOCAL_URL = "http://127.0.0.1:54321";

function fakeStorage(entries: Record<string, string> = {}) {
  const map = new Map(Object.entries(entries));
  return {
    getItem: (k: string) => map.get(k) ?? null,
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
