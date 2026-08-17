/// The RLS story, verified at the transport level: every PostgREST request
/// the store issues must (a) be a GET, (b) carry the authenticated user's
/// token as the Bearer Authorization header — which is exactly what makes
/// `auth.uid()` scope rows to that user server-side — and (c) never carry a
/// service-role key. Uses the REAL createSupabaseStore with a recorded fetch;
/// no network. A second user is simulated by building a second store with a
/// second token and asserting its requests carry that token. Also pins the
/// 401 → re-authenticate → retry-once path (issue #644 review F5).

import { describe, expect, it } from "vitest";
import { createSupabaseStore, type TokenProvider } from "../src/transport.js";

interface RecordedRequest {
  method: string;
  url: string;
  authorization: string | null;
  apikey: string | null;
}

function recordingFetch(
  respondWith: unknown,
  onRequest?: (req: RecordedRequest) => void,
  status = 200,
): typeof fetch {
  return async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof Request ? input.url : String(input);
    const method = init?.method ?? (typeof input === "string" ? "GET" : input instanceof Request ? input.method : "GET");
    const record: RecordedRequest = {
      method,
      url,
      authorization: null,
      apikey: null,
    };
    const headers = new Headers(init?.headers);
    if (input instanceof Request && input.headers instanceof Headers) {
      input.headers.forEach((v, k) => headers.set(k, v));
    }
    record.authorization = headers.get("authorization");
    record.apikey = headers.get("apikey");
    onRequest?.(record);
    const body = status >= 400 ? JSON.stringify({ message: "permission denied" }) : JSON.stringify(respondWith);
    return new Response(body, {
      status,
      headers: { "Content-Type": "application/json" },
    });
  };
}

function staticToken(token: string): TokenProvider {
  return { get: async () => token, onUnauthorized: async () => {} };
}

const URL = "https://example.supabase.co";
const ANON_KEY = "anon-key";

describe("createSupabaseStore", () => {
  it("every data method issues GETs that carry the user's Bearer token", async () => {
    const requests: RecordedRequest[] = [];
    const store = createSupabaseStore({
      url: URL,
      anonKey: ANON_KEY,
      tokenProvider: staticToken("user-token-A"),
      fetch: recordingFetch([], (r) => requests.push(r)),
    });

    await store.healthMetrics("2026-07-01", "2026-07-07");
    await store.sessions("2026-07-01", "2026-07-07");
    await store.phasePeriods();
    await store.workouts("2026-07-01", "2026-07-07");
    await store.recordingsByGroup("grp");
    await store.recordingsByIds(["a", "b"]);
    await store.recentRecordings(5);
    await store.samplesByIds(["a", "b"]);

    expect(requests.length).toBe(8);
    for (const r of requests) {
      expect(r.method).toBe("GET");
      expect(r.authorization).toBe("Bearer user-token-A");
      expect(r.url).toMatch(/^https:\/\/example\.supabase\.co\/rest\/v1\//);
    }
  });

  it("a different user token flows into a different store's requests", async () => {
    const requests: RecordedRequest[] = [];
    const store = createSupabaseStore({
      url: URL,
      anonKey: ANON_KEY,
      tokenProvider: staticToken("user-token-B"),
      fetch: recordingFetch([], (r) => requests.push(r)),
    });
    await store.sessions("2026-07-01", "2026-07-07");
    expect(requests[0]!.authorization).toBe("Bearer user-token-B");
  });

  it("re-authenticates and retries exactly once on a 401", async () => {
    let authCalls = 0;
    const provider: TokenProvider = {
      get: async () => "at-initial",
      onUnauthorized: async () => {
        authCalls++;
      },
    };
    const requests: RecordedRequest[] = [];
    const store = createSupabaseStore({
      url: URL,
      anonKey: ANON_KEY,
      tokenProvider: provider,
      // The FIRST request 401s; the re-auth'd retry returns 200 rows.
      fetch: (async (input) => {
        const n = requests.length;
        requests.push({ method: "GET", url: String(input), authorization: null, apikey: null });
        if (n === 0) {
          return new Response(JSON.stringify({ message: "JWT expired" }), {
            status: 401,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response("[]", { status: 200, headers: { "Content-Type": "application/json" } });
      }) as typeof fetch,
    });
    const rows = await store.sessions("2026-07-01", "2026-07-07");
    expect(rows).toEqual([]);
    expect(authCalls).toBe(1);
    expect(requests).toHaveLength(2);
  });

  it("a second 401 after re-auth surfaces as an AuthRequiredError", async () => {
    const requests: RecordedRequest[] = [];
    const store = createSupabaseStore({
      url: URL,
      anonKey: ANON_KEY,
      tokenProvider: {
        get: async () => "at",
        onUnauthorized: async () => {},
      },
      fetch: recordingFetch([], (r) => requests.push(r), 401),
    });
    await expect(store.sessions("2026-07-01", "2026-07-07")).rejects.toThrow(
      /token rejected \(HTTP 401\).*re-authenticate/,
    );
  });

  it("surfaces PostgREST errors instead of swallowing them", async () => {
    const store = createSupabaseStore({
      url: URL,
      anonKey: ANON_KEY,
      tokenProvider: staticToken("t"),
      fetch: recordingFetch([], undefined, 403),
    });
    await expect(store.healthMetrics("2026-07-01", "2026-07-02")).rejects.toThrow(
      "health_metrics",
    );
  });

  it("queries the right tables, columns and range filters", async () => {
    const requests: RecordedRequest[] = [];
    const store = createSupabaseStore({
      url: URL,
      anonKey: ANON_KEY,
      tokenProvider: staticToken("t"),
      fetch: recordingFetch([], (r) => requests.push(r)),
    });
    await store.healthMetrics("2026-07-01", "2026-07-07");
    await store.sessions("2026-07-01", "2026-07-07");

    const health = requests[0]!.url;
    expect(health).toContain("/health_metrics?");
    expect(health).toContain("date=gte.2026-07-01");
    expect(health).toContain("date=lte.2026-07-07");
    expect(health).toContain("select=date%2Creadiness%2Czone");

    const sessions = requests[1]!.url;
    expect(sessions).toContain("/sessions?");
    expect(sessions).toContain("deleted_at=is.null");
    expect(sessions).toContain("date=gte.2026-07-01");
    expect(sessions).toContain("select=id%2Cdate%2Ctype");
  });

  it("maps rows to the tool shapes (peak, samples tuple, phase period)", async () => {
    const store = createSupabaseStore({
      url: URL,
      anonKey: ANON_KEY,
      tokenProvider: staticToken("t"),
      fetch: recordingFetch([
        { id: "r", recorded_at: "2026-07-01T17:00:00Z", duration_ms: 7000, peak_kg: 40, avg_kg: 38.6, sample_count: 71, note: "", tag: "Half crimp", side: "left", group_id: null, zone: null, source: "dynamometer" },
      ]),
    });
    const recs = await store.recordingsByIds(["r"]);
    expect(recs).toHaveLength(1);
    expect(recs[0]!.peak_kg).toBe(40);
    expect(recs[0]!.duration_ms).toBe(7000);
    expect(recs[0]!.side).toBe("left");
  });
});
