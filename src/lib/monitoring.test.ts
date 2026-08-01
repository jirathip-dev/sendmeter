import { afterEach, describe, expect, it, vi } from "vitest";
import * as Sentry from "@sentry/react";
import type { Breadcrumb, ErrorEvent } from "@sentry/react";
import {
  classifyHandledFailure,
  scrubBreadcrumb,
  scrubEvent,
  stripQuery,
} from "./monitoring";
import type { HealthMetric } from "../types";
import { ZeroRowMutationError } from "./mutationInvariant";

// The health metric a real user's app state holds. Values are deliberately
// distinctive decimals so a substring search for them can't collide with an
// unrelated number (a line number, a timestamp) elsewhere in the event.
const HEALTH: HealthMetric = {
  date: "2026-07-26",
  readiness: 63,
  zone: "prime",
  computedAt: "2026-07-26T12:00:00+07:00",
  hrvSdnnMs: 48.732,
  restingHr: 51.409,
  sleepHours: 7.263,
  sleepDeepHours: 1.437,
  sleepRemHours: 1.912,
  bodyMassKg: 72.418,
  respRateBpm: 14.83,
};

/** Every value that must never leave the device, as it would serialize. */
const HEALTH_VALUES = [
  HEALTH.readiness,
  HEALTH.hrvSdnnMs,
  HEALTH.restingHr,
  HEALTH.sleepHours,
  HEALTH.sleepDeepHours,
  HEALTH.sleepRemHours,
  HEALTH.bodyMassKg,
  HEALTH.respRateBpm,
].map(String);

/** Every field name that must never leave the device. */
const HEALTH_FIELDS = [
  "hrvSdnnMs",
  "restingHr",
  "sleepHours",
  "sleepDeepHours",
  "sleepRemHours",
  "bodyMassKg",
  "respRateBpm",
  "readiness",
];

const USER_ID = "8f14e45f-ceea-467a-9575-28db6c1a4bd3";

/**
 * An event shaped like one Sentry would actually build from a crash in this
 * app — health data reaching every carrier the SDK has: `extra` (a state dump),
 * `contexts` (a `setContext` block), a breadcrumb, the request query string,
 * the `user` object, tags, and the exception message itself.
 */
function eventCarryingHealthData(): ErrorEvent {
  return {
    type: undefined,
    event_id: "abcdefabcdefabcdefabcdefabcdefab",
    timestamp: 1785000000,
    platform: "javascript",
    environment: "production",
    message: `readiness compute failed (hrvSdnnMs=${HEALTH.hrvSdnnMs})`,
    user: {
      id: USER_ID,
      email: "climber@example.com",
      username: "climber",
      ip_address: "203.0.113.7",
    },
    request: {
      url: `https://sendmeter.app/dashboard?readiness=${HEALTH.readiness}&restingHr=${HEALTH.restingHr}`,
      method: "GET",
      headers: { Cookie: "sb-access-token=secret", Referer: "https://sendmeter.app/?x=1" },
      data: JSON.stringify(HEALTH),
    },
    tags: {
      platform: "ios",
      readiness: String(HEALTH.readiness),
      email: "climber@example.com",
    },
    extra: {
      view: "dashboard",
      // The classic leak: a whole slice of app state attached "for context".
      state: { latestHealth: HEALTH, sessions: [{ id: "s1", load: 270 }] },
      latestHealth: HEALTH,
    },
    contexts: {
      app: { app_version: "1.4.0" },
      device: { model: "iPhone15,2" },
      health: { ...HEALTH },
      state: { state: { type: "app", value: { health: { metrics: [HEALTH] } } } },
    },
    breadcrumbs: [
      {
        category: "console",
        level: "log",
        timestamp: 1784999990,
        message: `sleepHours=${HEALTH.sleepHours} sleepDeepHours=${HEALTH.sleepDeepHours}`,
      },
      {
        category: "fetch",
        level: "info",
        timestamp: 1784999995,
        data: {
          method: "GET",
          url: `https://zznsqmcewtzlnfoiefkk.supabase.co/rest/v1/health_metrics?select=hrv_sdnn_ms&body_mass_kg=eq.${HEALTH.bodyMassKg}`,
          status_code: 200,
          body: JSON.stringify(HEALTH),
        },
      },
      {
        category: "navigation",
        level: "info",
        timestamp: 1784999998,
        data: { from: "/history", to: `/dashboard?respRateBpm=${HEALTH.respRateBpm}` },
      },
    ],
    exception: {
      values: [
        {
          type: "TypeError",
          value: `Cannot read properties of null (reading 'hrvSdnnMs') while rendering readiness ${HEALTH.readiness}`,
          stacktrace: {
            frames: [
              {
                filename: "https://sendmeter.app/assets/index-a1b2.js",
                function: "ReadinessCard",
                lineno: 12,
                colno: 9,
              },
            ],
          },
        },
      ],
    },
  } as ErrorEvent;
}

describe("scrubEvent — no health data leaves the device", () => {
  it("the fixture really carries every health field and value (guards the test itself)", () => {
    const raw = JSON.stringify(eventCarryingHealthData());
    for (const field of HEALTH_FIELDS) expect(raw).toContain(field);
    for (const value of HEALTH_VALUES) expect(raw).toContain(value);
  });

  it("drops every health field name from the serialized event", () => {
    const json = JSON.stringify(scrubEvent(eventCarryingHealthData()));
    for (const field of HEALTH_FIELDS) expect(json).not.toContain(field);
    // ...and the snake_case column names the same data arrives under.
    for (const column of ["hrv_sdnn_ms", "resting_hr", "sleep_hours", "body_mass_kg", "resp_rate_bpm"]) {
      expect(json).not.toContain(column);
    }
  });

  it("drops every health value from the serialized event", () => {
    const json = JSON.stringify(scrubEvent(eventCarryingHealthData()));
    for (const value of HEALTH_VALUES) expect(json).not.toContain(value);
  });

  it("keeps only the Supabase auth uuid as identity — never the email", () => {
    const scrubbed = scrubEvent(eventCarryingHealthData());
    expect(scrubbed.user).toEqual({ id: USER_ID });
    const json = JSON.stringify(scrubbed);
    expect(json).toContain(USER_ID);
    expect(json).not.toContain("climber@example.com");
    expect(json).not.toContain("climber");
    expect(json).not.toContain("203.0.113.7");
  });

  it("keeps the request path but no query string, headers, cookies or body", () => {
    const scrubbed = scrubEvent(eventCarryingHealthData());
    expect(scrubbed.request).toEqual({
      url: "https://sendmeter.app/dashboard",
      method: "GET",
    });
    expect(JSON.stringify(scrubbed)).not.toContain("sb-access-token");
  });

  it("keeps only allow-listed extra / contexts / tags", () => {
    const scrubbed = scrubEvent(eventCarryingHealthData());
    expect(scrubbed.extra).toEqual({ view: "dashboard" });
    expect(Object.keys(scrubbed.contexts ?? {})).toEqual(["app", "device"]);
    expect(scrubbed.tags).toEqual({ platform: "ios" });
  });

  it("redacts a message or exception value that names a health field", () => {
    const scrubbed = scrubEvent(eventCarryingHealthData());
    expect(scrubbed.message).toBe("[redacted]");
    expect(scrubbed.exception?.values?.[0]?.value).toBe("[redacted]");
    // The frame that identifies WHERE it broke survives — that's the point.
    expect(scrubbed.exception?.values?.[0]?.stacktrace?.frames?.[0]?.function).toBe(
      "ReadinessCard",
    );
  });

  it("keeps only allow-listed breadcrumbs, with their URLs stripped", () => {
    const scrubbed = scrubEvent(eventCarryingHealthData());
    const kept = scrubbed.breadcrumbs ?? [];
    // The console breadcrumb (arbitrary logged content) is gone; fetch and
    // navigation survive with query strings and non-allow-listed data removed.
    expect(kept.map((b) => b.category)).toEqual(["fetch", "navigation"]);
    // The fetch body is gone (not an allow-listed data key) and the URL — whose
    // path still names the health table after the query string is stripped —
    // is redacted whole.
    expect(kept[0]?.data).toEqual({
      method: "GET",
      url: "[redacted]",
      status_code: 200,
    });
    expect(kept[1]?.data).toEqual({ from: "/history", to: "/dashboard" });
  });

  it("survives an event with nothing on it", () => {
    const empty = scrubEvent({} as ErrorEvent);
    expect(empty).toBeTruthy();
    expect(empty.user).toBeUndefined();
  });
});

describe("scrubBreadcrumb", () => {
  it("drops anything outside the category allow-list", () => {
    for (const category of ["console", "sentry.event", "custom", undefined]) {
      expect(scrubBreadcrumb({ category } as Breadcrumb)).toBeNull();
    }
  });

  it("keeps a navigation crumb and strips its query strings", () => {
    const crumb = scrubBreadcrumb({
      category: "navigation",
      data: { from: "/a?token=abc", to: "/b#frag", secret: "nope" },
    });
    expect(crumb?.data).toEqual({ from: "/a", to: "/b" });
  });
});

describe("handled operational failure classification", () => {
  it.each([
    [{ code: "42501", message: "permission denied" }, "permission"],
    [{ status: 401, message: "expired bearer" }, "auth"],
    [new TypeError("Failed to fetch"), "network"],
    [{ code: "23514", message: "check violation" }, "constraint"],
    [{ code: "PGRST204", message: "schema cache" }, "schema"],
    [new ZeroRowMutationError(), "invariant"],
    [{ code: "XX000", message: "unrecognized failure" }, "unknown"],
  ] as const)("classifies %o as %s", (error, expected) => {
    expect(classifyHandledFailure(error)).toBe(expected);
  });
});

describe("initMonitoring — the DSN gate", () => {
  afterEach(async () => {
    await Sentry.getClient()?.close();
    Sentry.setCurrentClient(undefined as never);
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  async function loadWithDsn(dsn: string | undefined) {
    vi.resetModules();
    if (dsn === undefined) vi.stubEnv("VITE_SENTRY_DSN", undefined);
    else vi.stubEnv("VITE_SENTRY_DSN", dsn);
    return await import("./monitoring");
  }

  it("is a no-op with no DSN — nothing can be sent", async () => {
    const m = await loadWithDsn(undefined);
    m.initMonitoring();
    expect(Sentry.getClient()).toBeUndefined();
    // The user/report entry points stay inert too.
    m.setMonitoringUser("8f14e45f-ceea-467a-9575-28db6c1a4bd3");
    m.captureAppError(new Error("boom"));
    const captureMessage = vi.fn<typeof Sentry.captureMessage>(() => "event-id");
    expect(
      m.captureHandledOperationalFailure(
        "session.insert",
        { code: "42501", message: "private database response" },
        { automatic: true },
        captureMessage,
      ),
    ).toBeNull();
    expect(captureMessage).not.toHaveBeenCalled();
    expect(Sentry.getClient()).toBeUndefined();
  });

  it("initializes with the privacy options when a DSN is present", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    m.initMonitoring();
    const options = Sentry.getClient()?.getOptions();
    expect(options).toBeTruthy();
    expect(options?.beforeSend).toBeTypeOf("function");
    expect(options?.beforeBreadcrumb).toBeTypeOf("function");
    expect(options?.tracesSampleRate).toBe(0);
    // Replay sample rates only exist on BrowserOptions, not the resolved
    // ClientOptions the client hands back.
    const replay = options as unknown as {
      replaysSessionSampleRate?: number;
      replaysOnErrorSampleRate?: number;
    };
    expect(replay.replaysSessionSampleRate).toBe(0);
    expect(replay.replaysOnErrorSampleRate).toBe(0);
    // No inferred user, no cookies/headers/bodies/query params/locals.
    expect(options?.dataCollection).toEqual({
      userInfo: false,
      cookies: false,
      httpHeaders: { request: false, response: false },
      httpBodies: [],
      urlQueryParams: false,
      stackFrameVariables: false,
      databaseQueryData: false,
    });
    // The deprecated blanket flag is not used at all — `dataCollection` above
    // replaces it and would win anyway.
    expect((options as unknown as Record<string, unknown>).sendDefaultPii).toBeUndefined();
    // Session envelopes bypass beforeSend, so that integration must be gone.
    expect(options?.integrations.map((i) => i.name)).not.toContain("BrowserSession");
    // …and the wired-up beforeSend is the scrub itself.
    const scrubbed = options?.beforeSend?.(eventCarryingHealthData(), {}) as ErrorEvent;
    const json = JSON.stringify(scrubbed);
    for (const field of HEALTH_FIELDS) expect(json).not.toContain(field);
    for (const value of HEALTH_VALUES) expect(json).not.toContain(value);
  });

  it("captures only the controlled handled-failure shape, never the raw failure", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    m.initMonitoring();
    const capture = vi.fn<typeof Sentry.captureMessage>(() => "handled-event-id");
    const rawFailure = {
      status: 403,
      code: "42501",
      message:
        "RLS rejected note 'secret redpoint beta' with readiness 63 and hrvSdnnMs 48.732 for climber@example.com",
      details: {
        row: {
          note: "secret redpoint beta",
          duration_min: 97,
          rpe: 9,
          hrv_sdnn_ms: 48.732,
        },
      },
      hint: "raw server hint",
      body: "raw response body",
    };

    expect(
      m.captureHandledOperationalFailure(
        "session.insert",
        rawFailure,
        { automatic: true },
        capture,
      ),
    ).toBe("handled-event-id");
    expect(capture).toHaveBeenCalledOnce();
    expect(capture).toHaveBeenCalledWith("handled operational failure", {
      level: "error",
      tags: {
        operation: "session.insert",
        failure_class: "permission",
        outcome: "recovery-exhausted",
      },
      fingerprint: [
        "handled-operational-failure",
        "session.insert",
        "permission",
      ],
      extra: { automatic: true, status: 403 },
    });
    const serialized = JSON.stringify(capture.mock.calls[0]);
    for (const forbidden of [
      "secret redpoint beta",
      "duration_min",
      "rpe",
      "hrvSdnnMs",
      "48.732",
      "climber@example.com",
      "raw server hint",
      "raw response body",
      "42501",
    ]) {
      expect(serialized).not.toContain(forbidden);
    }
  });

  it("reports a zero-row mutation as an invariant with no raw database error", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    m.initMonitoring();
    const capture = vi.fn<typeof Sentry.captureMessage>(() => "zero-row-event");

    m.captureHandledOperationalFailure(
      "session.update",
      new ZeroRowMutationError(),
      { automatic: false },
      capture,
    );

    expect(capture).toHaveBeenCalledWith("handled operational failure", {
      level: "error",
      tags: {
        operation: "session.update",
        failure_class: "invariant",
        outcome: "zero-row-invariant",
      },
      fingerprint: [
        "handled-operational-failure",
        "session.update",
        "invariant",
      ],
      extra: { automatic: false, affected_rows: 0 },
    });
  });

  it("deduplicates exhausted training-data loads for the app launch", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    m.initMonitoring();
    const capture = vi.fn<typeof Sentry.captureMessage>(() => "load-event");

    const first = m.captureHandledOperationalFailure(
      "training-data.load",
      new TypeError("Failed to fetch"),
      { retryAttempts: 3 },
      capture,
    );
    const duplicate = m.captureHandledOperationalFailure(
      "training-data.load",
      { code: "42501", message: "permission denied" },
      { retryAttempts: 3 },
      capture,
    );

    expect(first).toBe("load-event");
    expect(duplicate).toBeNull();
    expect(capture).toHaveBeenCalledOnce();
  });

  it("excludes expected cancellation, invalid credentials, BLE disconnect, offline, and queued recording cases", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    m.initMonitoring();
    const capture = vi.fn<typeof Sentry.captureMessage>(() => "unexpected-event");

    m.captureHandledOperationalFailure(
      "session.insert",
      { name: "AbortError", message: "The operation was aborted" },
      {},
      capture,
    );
    m.captureHandledOperationalFailure(
      "session.insert",
      { code: "invalid_credentials", message: "Invalid login credentials" },
      {},
      capture,
    );
    m.captureHandledOperationalFailure(
      "workout.insert",
      { code: "BLE_DISCONNECTED", message: "Device disconnected" },
      {},
      capture,
    );
    vi.stubGlobal("navigator", { onLine: false });
    m.captureHandledOperationalFailure(
      "training-data.load",
      new TypeError("Failed to fetch"),
      { retryAttempts: 3 },
      capture,
    );
    vi.unstubAllGlobals();
    m.captureHandledOperationalFailure(
      "session.insert",
      new Error("recording insert failed"),
      { retainedOffline: true },
      capture,
    );

    expect(capture).not.toHaveBeenCalled();
  });

  it("rejects an operation outside the closed code-owned set at runtime", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    m.initMonitoring();
    const capture = vi.fn<typeof Sentry.captureMessage>(() => "unexpected-event");

    const eventId = m.captureHandledOperationalFailure(
      "user-entered operation" as never,
      new Error("private user-entered message"),
      {},
      capture,
    );

    expect(eventId).toBeNull();
    expect(capture).not.toHaveBeenCalled();
  });

  it("keeps handled-failure allow-listed fields through the existing scrub", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    const event = m.scrubEvent({
      message: "handled operational failure",
      tags: {
        operation: "workout.insert",
        failure_class: "network",
        outcome: "recovery-exhausted",
        raw_error: "secret",
      },
      extra: {
        retry_attempts: 3,
        automatic: true,
        affected_rows: 0,
        status: 503,
        row: { note: "secret training note" },
      },
    } as unknown as ErrorEvent);

    expect(event.tags).toEqual({
      operation: "workout.insert",
      failure_class: "network",
      outcome: "recovery-exhausted",
    });
    expect(event.extra).toEqual({
      retry_attempts: 3,
      automatic: true,
      affected_rows: 0,
      status: 503,
    });
    expect(JSON.stringify(event)).not.toContain("secret");
  });

  it("drops arbitrary values smuggled through handled-failure tag/detail keys", async () => {
    const m = await loadWithDsn("https://examplePublicKey@o0.ingest.sentry.io/0");
    const event = m.scrubEvent({
      tags: {
        operation: "secret user operation",
        failure_class: "secret server class",
        outcome: "secret response outcome",
      },
      extra: {
        retry_attempts: "secret attempts",
        automatic: "secret automatic",
        affected_rows: 97,
        status: "secret status",
      },
    } as unknown as ErrorEvent);

    expect(event.tags).toBeUndefined();
    expect(event.extra).toBeUndefined();
    expect(JSON.stringify(event)).not.toContain("secret");
  });
});

describe("stripQuery", () => {
  it("removes the query string and the fragment", () => {
    expect(stripQuery("https://x.test/a/b?c=1&d=2#frag")).toBe("https://x.test/a/b");
    expect(stripQuery("/dashboard")).toBe("/dashboard");
  });
});
